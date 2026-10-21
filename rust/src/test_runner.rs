use crate::{
    log::{LogBuffer, LogPage},
    process::{flutter_program, OwnedProcess},
};
use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    sync::{watch, Mutex},
};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TestSelection {
    pub path: String,
    pub name: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TestRunConfig {
    pub project_path: String,
    pub sdk_path: Option<String>,
    pub selections: Vec<TestSelection>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TestResult {
    pub id: String,
    pub path: String,
    pub name: String,
    pub status: String,
    pub error: Option<String>,
    pub stack_trace: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TestRunSnapshot {
    pub id: String,
    pub project_path: String,
    pub state: String,
    pub tests: Vec<TestResult>,
    pub passed: u32,
    pub failed: u32,
    pub skipped: u32,
    pub exit_code: Option<i32>,
    pub error: Option<String>,
}

#[derive(Default)]
pub struct TestManager {
    runs: Mutex<HashMap<String, Arc<TestRun>>>,
    ids: AtomicU64,
    closing: AtomicBool,
}
struct TestRun {
    snapshot: Mutex<TestRunSnapshot>,
    logs: Mutex<LogBuffer>,
    cancel: watch::Sender<bool>,
    done: watch::Sender<bool>,
}
fn finished(state: &str) -> bool {
    matches!(state, "succeeded" | "failed" | "cancelled")
}
fn bounded(value: &str, max: usize) -> String {
    let mut end = max.min(value.len());
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

pub async fn discover_test_files(project_path: String) -> Result<Vec<String>> {
    tokio::task::spawn_blocking(move || discover(Path::new(&project_path))).await?
}
fn discover(project: &Path) -> Result<Vec<String>> {
    let root = project
        .canonicalize()
        .context("Test project folder does not exist")?;
    anyhow::ensure!(
        root.join("pubspec.yaml").is_file(),
        "Test project has no pubspec.yaml"
    );
    let test = root.join("test");
    if !test.exists() {
        return Ok(vec![]);
    }
    anyhow::ensure!(
        !test.symlink_metadata()?.file_type().is_symlink(),
        "Test directory must not be a symlink"
    );
    let mut folders = vec![(test, 0)];
    let mut files = Vec::new();
    let mut visited = 0;
    while let Some((folder, depth)) = folders.pop() {
        anyhow::ensure!(depth <= 32, "Test directory exceeds 32 levels");
        for entry in std::fs::read_dir(folder)? {
            let entry = entry?;
            visited += 1;
            anyhow::ensure!(visited <= 20000, "Test directory exceeds 20000 entries");
            let kind = entry.file_type()?;
            if kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                folders.push((entry.path(), depth + 1));
            } else if kind.is_file() && entry.file_name().to_string_lossy().ends_with("_test.dart")
            {
                anyhow::ensure!(files.len() < 5000, "Test file count exceeds 5000");
                files.push(
                    entry
                        .path()
                        .strip_prefix(&root)?
                        .to_string_lossy()
                        .replace('\\', "/"),
                );
            }
        }
    }
    files.sort();
    Ok(files)
}
fn validate_selection(project: &Path, selection: &TestSelection) -> Result<()> {
    let path = Path::new(&selection.path);
    anyhow::ensure!(
        !selection.path.contains('\0')
            && selection.path.len() <= 16384
            && !path.is_absolute()
            && path
                .components()
                .all(|component| matches!(component, std::path::Component::Normal(_))),
        "Test path must be relative without traversal"
    );
    anyhow::ensure!(
        selection.path.ends_with("_test.dart"),
        "Select a Dart test file"
    );
    let file = project
        .join(path)
        .canonicalize()
        .context("Test file does not exist")?;
    anyhow::ensure!(
        file.starts_with(project) && file.is_file(),
        "Test file must belong to this project"
    );
    anyhow::ensure!(
        selection
            .name
            .as_ref()
            .is_none_or(|name| !name.is_empty() && name.len() <= 16384 && !name.contains('\0')),
        "Invalid test name"
    );
    Ok(())
}
fn exact_name(name: &str) -> String {
    let mut pattern = String::from("^");
    for character in name.chars() {
        if "\\.^$|?*+()[]{}".contains(character) {
            pattern.push('\\');
        }
        pattern.push(character);
    }
    pattern.push('$');
    pattern
}

fn test_command(
    sdk: &crate::sdk::SdkInfo,
    args: Vec<String>,
    windows: bool,
) -> (PathBuf, Vec<String>) {
    if !windows {
        return (flutter_program(sdk), args);
    }
    // flutter.bat passes through cmd.exe, where an exact-name regexp's '^'
    // would require shell escaping. Invoke the same initialized SDK snapshot
    // directly, preserving the regexp and paths as literal arguments.
    let root = Path::new(&sdk.path);
    let dart = root.join("bin/cache/dart-sdk/bin/dart.exe");
    let snapshot = root.join("bin/cache/flutter_tools.snapshot");
    let packages = root.join("packages/flutter_tools/.dart_tool/package_config.json");
    let mut invocation = vec![
        format!("--packages={}", packages.to_string_lossy()),
        snapshot.to_string_lossy().into_owned(),
    ];
    invocation.extend(args);
    (dart, invocation)
}

fn validate_config_limits(config: &TestRunConfig) -> Result<()> {
    anyhow::ensure!(
        config.selections.len() <= 5000,
        "At most 5000 test selections can run together"
    );
    anyhow::ensure!(
        config.project_path.len() <= 16384
            && !config.project_path.contains('\0')
            && config
                .sdk_path
                .as_ref()
                .is_none_or(|path| path.len() <= 16384 && !path.contains('\0')),
        "Test project or SDK path exceeds limits"
    );
    let bytes = config.selections.iter().fold(
        config
            .project_path
            .len()
            .saturating_add(config.sdk_path.as_ref().map_or(0, String::len)),
        |total, selection| {
            total
                .saturating_add(selection.path.len())
                .saturating_add(selection.name.as_ref().map_or(0, String::len))
        },
    );
    anyhow::ensure!(
        bytes <= 2 * 1024 * 1024 && serde_json::to_vec(config)?.len() <= 2 * 1024 * 1024,
        "Test selection data exceeds 2 MiB"
    );
    Ok(())
}

impl TestManager {
    pub async fn start(&self, mut config: TestRunConfig) -> Result<TestRunSnapshot> {
        anyhow::ensure!(
            !self.closing.load(Ordering::Acquire),
            "Test manager is shutting down"
        );
        validate_config_limits(&config)?;
        let project = tokio::fs::canonicalize(&config.project_path)
            .await
            .context("Test project folder does not exist")?;
        anyhow::ensure!(
            project.join("pubspec.yaml").is_file(),
            "Test project has no pubspec.yaml"
        );
        for selection in &config.selections {
            validate_selection(&project, selection)?;
        }
        config.project_path = project.to_string_lossy().into_owned();
        let mut runs = self.runs.lock().await;
        anyhow::ensure!(
            !self.closing.load(Ordering::Acquire),
            "Test manager is shutting down"
        );
        for run in runs.values() {
            let snapshot = run.snapshot.lock().await;
            if snapshot.project_path == config.project_path && !finished(&snapshot.state) {
                bail!("A test run is already active for this project");
            }
        }
        if runs.len() >= 16 {
            let mut completed = Vec::new();
            for (id, run) in runs.iter() {
                if finished(&run.snapshot.lock().await.state) {
                    completed.push(id.clone());
                }
            }
            completed.sort_by_key(|id| {
                id.strip_prefix("test-")
                    .and_then(|id| id.parse::<u64>().ok())
                    .unwrap_or(0)
            });
            for id in completed.into_iter().take(runs.len().saturating_sub(15)) {
                runs.remove(&id);
            }
            anyhow::ensure!(runs.len() < 16, "Too many active test runs");
        }
        let snapshot = TestRunSnapshot {
            id: format!("test-{}", self.ids.fetch_add(1, Ordering::Relaxed) + 1),
            project_path: config.project_path.clone(),
            state: "starting".into(),
            tests: vec![],
            passed: 0,
            failed: 0,
            skipped: 0,
            exit_code: None,
            error: None,
        };
        let (cancel, _) = watch::channel(false);
        let (done, _) = watch::channel(false);
        let run = Arc::new(TestRun {
            snapshot: Mutex::new(snapshot.clone()),
            logs: Mutex::new(LogBuffer::new(5000, 2 * 1024 * 1024)),
            cancel,
            done,
        });
        runs.insert(snapshot.id.clone(), run.clone());
        tokio::spawn(async move {
            run.run(config).await;
        });
        Ok(snapshot)
    }
    async fn get(&self, id: &str) -> Result<Arc<TestRun>> {
        self.runs
            .lock()
            .await
            .get(id)
            .cloned()
            .ok_or_else(|| anyhow!("Unknown test run: {id}"))
    }
    pub async fn snapshot(&self, id: &str) -> Result<TestRunSnapshot> {
        Ok(self.get(id).await?.snapshot.lock().await.clone())
    }
    pub async fn list(&self) -> Vec<TestRunSnapshot> {
        let runs: Vec<_> = self.runs.lock().await.values().cloned().collect();
        let mut snapshots = vec![];
        for run in runs {
            snapshots.push(run.snapshot.lock().await.clone());
        }
        snapshots.sort_by_key(|snapshot| {
            std::cmp::Reverse(
                snapshot
                    .id
                    .strip_prefix("test-")
                    .and_then(|id| id.parse::<u64>().ok())
                    .unwrap_or(0),
            )
        });
        snapshots
    }
    pub async fn logs(&self, id: &str, after_id: u64, limit: u32) -> Result<LogPage> {
        Ok(self.get(id).await?.logs.lock().await.query(
            Some(after_id),
            (limit as usize).clamp(1, 1000),
            None,
        ))
    }
    pub async fn stop(&self, id: &str) -> Result<()> {
        self.get(id).await?.stop().await;
        Ok(())
    }
    pub async fn shutdown(&self) {
        self.closing.store(true, Ordering::Release);
        let runs: Vec<_> = self.runs.lock().await.values().cloned().collect();
        for run in runs {
            run.stop().await;
        }
        self.runs.lock().await.clear();
    }
}
impl TestRun {
    async fn stop(&self) {
        let mut done = self.done.subscribe();
        {
            let mut snapshot = self.snapshot.lock().await;
            if finished(&snapshot.state) {
                return;
            }
            snapshot.state = "stopping".into();
            self.cancel.send_replace(true);
        }
        while !*done.borrow_and_update() {
            if done.changed().await.is_err() {
                break;
            }
        }
    }
    async fn run(self: Arc<Self>, config: TestRunConfig) {
        let result = self.execute(&config).await;
        let mut snapshot = self.snapshot.lock().await;
        if *self.cancel.borrow() {
            snapshot.state = "cancelled".into();
            for test in &mut snapshot.tests {
                if test.status == "running" {
                    test.status = "cancelled".into();
                }
            }
        } else if let Err(error) = result {
            snapshot.state = "failed".into();
            snapshot.error = Some(bounded(&format!("{error:#}"), 16384));
        } else if snapshot.error.is_some()
            || snapshot.failed > 0
            || snapshot.tests.is_empty()
            || snapshot.tests.iter().any(|test| test.status == "running")
        {
            snapshot.state = "failed".into();
            snapshot
                .error
                .get_or_insert("Test run ended without successful results for every test".into());
        } else {
            snapshot.state = "succeeded".into();
        }
        if snapshot.state == "failed" {
            for test in &mut snapshot.tests {
                if test.status == "running" {
                    test.status = "failed".into();
                    test.error
                        .get_or_insert("Test process ended before reporting a result".into());
                }
            }
            snapshot.failed = snapshot
                .tests
                .iter()
                .filter(|test| test.status == "failed")
                .count() as u32;
        }
        self.done.send_replace(true);
    }
    async fn execute(self: &Arc<Self>, config: &TestRunConfig) -> Result<()> {
        let mut cancelled = self.cancel.subscribe();
        if *cancelled.borrow() {
            return Ok(());
        }
        let sdk = tokio::select! { result = crate::sdk::resolve_sdk(Some(config.project_path.clone()), config.sdk_path.clone()) => result?, _ = cancelled.changed() => return Ok(()) };
        let selections: Vec<Option<&TestSelection>> = if config.selections.is_empty() {
            vec![None]
        } else {
            config.selections.iter().map(Some).collect()
        };
        let mut any_failure = false;
        for (index, selection) in selections.into_iter().enumerate() {
            if *cancelled.borrow() {
                return Ok(());
            }
            let mut args = vec!["test".into(), "--machine".into()];
            if let Some(selection) = selection {
                args.push(selection.path.clone());
                if let Some(name) = &selection.name {
                    args.extend(["--name".into(), exact_name(name)]);
                }
            }
            self.logs
                .lock()
                .await
                .push("system", &format!("flutter {}", args.join(" ")));
            let (program, args) = test_command(&sdk, args, cfg!(windows));
            let mut process = OwnedProcess::spawn(
                &program,
                &args,
                Some(Path::new(&config.project_path)),
                &HashMap::new(),
            )?;
            process.stdin.take();
            let stdout = process.stdout.take().context("Test stdout unavailable")?;
            let stderr = process.stderr.take().context("Test stderr unavailable")?;
            let out_run = self.clone();
            let err_run = self.clone();
            let project = config.project_path.clone();
            let default_path = selection
                .map(|selection| selection.path.clone())
                .unwrap_or_default();
            let out = tokio::spawn(async move {
                out_run
                    .read_output(stdout, true, index, &project, &default_path)
                    .await
            });
            let err =
                tokio::spawn(
                    async move { err_run.read_output(stderr, false, index, "", "").await },
                );
            {
                let mut snapshot = self.snapshot.lock().await;
                if !*cancelled.borrow() {
                    snapshot.state = "running".into();
                }
            }
            let status = tokio::select! { result = process.wait() => Some(result), _ = cancelled.changed() => { process.terminate(Duration::from_secs(2)).await?; None } };
            let (out, err) = tokio::join!(out, err);
            out.context("Test stdout reader failed")??;
            err.context("Test stderr reader failed")??;
            let Some(status) = status else {
                return Ok(());
            };
            let status = status?;
            {
                let mut snapshot = self.snapshot.lock().await;
                if !status.success() || snapshot.exit_code.is_none() {
                    snapshot.exit_code = status.code();
                }
            }
            if !status.success() {
                any_failure = true;
                self.logs
                    .lock()
                    .await
                    .push("error", &format!("Flutter test exited: {status}"));
            }
        }
        anyhow::ensure!(
            !any_failure,
            "Flutter test exited unsuccessfully; inspect test results and output"
        );
        Ok(())
    }
    async fn read_output(
        &self,
        mut stream: impl AsyncRead + Unpin,
        machine: bool,
        invocation: usize,
        project: &str,
        default_path: &str,
    ) -> Result<()> {
        let mut buffer = [0u8; 8192];
        let mut line = Vec::new();
        let mut discard = false;
        let mut suites: HashMap<i64, String> = HashMap::new();
        loop {
            let length = stream.read(&mut buffer).await?;
            if length == 0 {
                break;
            }
            for byte in &buffer[..length] {
                if *byte == b'\n' || *byte == b'\r' {
                    if !line.is_empty() && !discard {
                        self.record_line(
                            &line,
                            machine,
                            invocation,
                            project,
                            default_path,
                            &mut suites,
                        )
                        .await;
                    }
                    line.clear();
                    discard = false;
                } else if line.len() >= 256 * 1024 {
                    if !discard {
                        self.logs.lock().await.push(
                            "error",
                            "Test output line exceeded 256 KiB and was truncated",
                        );
                    }
                    line.clear();
                    discard = true;
                } else if !discard {
                    line.push(*byte);
                }
            }
        }
        if !line.is_empty() && !discard {
            self.record_line(
                &line,
                machine,
                invocation,
                project,
                default_path,
                &mut suites,
            )
            .await;
        }
        Ok(())
    }
    async fn record_line(
        &self,
        bytes: &[u8],
        machine: bool,
        invocation: usize,
        project: &str,
        default_path: &str,
        suites: &mut HashMap<i64, String>,
    ) {
        let text = String::from_utf8_lossy(bytes);
        let Ok(event) = serde_json::from_slice::<Value>(bytes) else {
            self.logs
                .lock()
                .await
                .push(if machine { "stdout" } else { "stderr" }, &text);
            return;
        };
        if !machine {
            self.logs.lock().await.push("stderr", &text);
            return;
        }
        let kind = event["type"].as_str().unwrap_or("");
        if kind == "suite" {
            if suites.len() < 5000 {
                if let (Some(id), Some(path)) = (
                    event["suite"]["id"].as_i64(),
                    event["suite"]["path"].as_str(),
                ) {
                    let path = Path::new(path)
                        .strip_prefix(project)
                        .unwrap_or(Path::new(path))
                        .to_string_lossy()
                        .replace('\\', "/");
                    suites.insert(id, bounded(&path, 16384));
                }
            }
            return;
        }
        if kind == "print" {
            self.logs
                .lock()
                .await
                .push("stdout", event["message"].as_str().unwrap_or(&text));
            return;
        }
        if kind == "error" {
            self.logs
                .lock()
                .await
                .push("error", event["error"].as_str().unwrap_or(&text));
        }
        let mut snapshot = self.snapshot.lock().await;
        if kind == "done" && event["success"].as_bool() == Some(false) {
            snapshot.error = Some("Flutter test machine runner reported failure".into());
            snapshot.failed = snapshot.failed.max(1);
        }
        let stored_bytes: usize = snapshot
            .tests
            .iter()
            .map(|test| {
                test.path.len()
                    + test.name.len()
                    + test.error.as_ref().map_or(0, String::len)
                    + test.stack_trace.as_ref().map_or(0, String::len)
            })
            .sum();
        if stored_bytes >= 4 * 1024 * 1024 - 32768 && matches!(kind, "testStart" | "error") {
            snapshot.error = Some("Test result storage exceeds 4 MiB; remaining output is available in the bounded log".into());
            return;
        }
        if kind == "error" && event["testID"].as_i64().is_none() {
            snapshot.error = Some(bounded(
                event["error"].as_str().unwrap_or("Test runner error"),
                8192,
            ));
        }
        if kind == "testStart" {
            if let Some(id) = event["test"]["id"].as_i64() {
                if snapshot.tests.len() >= 5000 {
                    snapshot.error = Some("Test result count exceeds 5000".into());
                    snapshot.failed = snapshot.failed.max(1);
                    return;
                }
                let test = &event["test"];
                let path = test["suiteID"]
                    .as_i64()
                    .and_then(|id| suites.get(&id))
                    .map(String::as_str)
                    .unwrap_or(default_path);
                snapshot.tests.push(TestResult {
                    id: format!("{invocation}:{id}"),
                    path: bounded(path, 16384),
                    name: bounded(test["name"].as_str().unwrap_or("Unnamed test"), 16384),
                    status: "running".into(),
                    error: None,
                    stack_trace: None,
                });
            }
        } else if let Some(id) = event["testID"].as_i64() {
            let id = format!("{invocation}:{id}");
            if kind == "testDone" && event["hidden"].as_bool() == Some(true) {
                snapshot.tests.retain(|test| test.id != id);
            } else if let Some(test) = snapshot.tests.iter_mut().find(|test| test.id == id) {
                if kind == "error" {
                    test.error = Some(bounded(
                        event["error"].as_str().unwrap_or("Test error"),
                        8192,
                    ));
                    test.stack_trace = event["stackTrace"]
                        .as_str()
                        .map(|stack| bounded(stack, 8192));
                }
                if kind == "testDone" {
                    test.status = if event["skipped"].as_bool() == Some(true) {
                        "skipped"
                    } else if event["result"].as_str() == Some("success") && test.error.is_none() {
                        "passed"
                    } else {
                        "failed"
                    }
                    .into();
                }
            } else if kind == "error" {
                snapshot.error = Some(bounded(
                    event["error"].as_str().unwrap_or("Test error"),
                    8192,
                ));
            }
        }
        snapshot.passed = snapshot
            .tests
            .iter()
            .filter(|test| test.status == "passed")
            .count() as u32;
        snapshot.failed = snapshot
            .tests
            .iter()
            .filter(|test| test.status == "failed")
            .count() as u32;
        snapshot.skipped = snapshot
            .tests
            .iter()
            .filter(|test| test.status == "skipped")
            .count() as u32;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;
    #[test]
    fn windows_test_command_preserves_regex_in_direct_dart_arguments() {
        let sdk = crate::sdk::SdkInfo {
            path: "/selected/sdk with spaces".into(),
            flutter_version: "test".into(),
            dart_version: "test".into(),
            source: "explicit".into(),
            fallback_reason: None,
        };
        let args = vec![
            "test".into(),
            "--machine".into(),
            "test/a file_test.dart".into(),
            "--name".into(),
            exact_name("group [case].* \"quoted\""),
        ];
        let (program, invocation) = test_command(&sdk, args.clone(), true);
        assert_eq!(
            program,
            Path::new(&sdk.path).join("bin/cache/dart-sdk/bin/dart.exe")
        );
        assert_eq!(
            invocation[0],
            format!(
                "--packages={}",
                Path::new(&sdk.path)
                    .join("packages/flutter_tools/.dart_tool/package_config.json")
                    .display()
            )
        );
        assert_eq!(
            Path::new(&invocation[1]),
            Path::new(&sdk.path).join("bin/cache/flutter_tools.snapshot")
        );
        assert_eq!(invocation[2..], args);
        assert!(invocation.last().unwrap().starts_with('^'));
        let (program, invocation) = test_command(&sdk, args.clone(), false);
        assert_eq!(program, flutter_program(&sdk));
        assert_eq!(invocation, args);
    }

    #[test]
    fn all_failed_results_fit_selection_count_and_total_request_is_bounded() {
        let mut config = TestRunConfig {
            project_path: "/project".into(),
            sdk_path: None,
            selections: (0..5000)
                .map(|index| TestSelection {
                    path: "test/one_test.dart".into(),
                    name: Some(format!("failed case {index}")),
                })
                .collect(),
        };
        validate_config_limits(&config).unwrap();
        config.selections.push(TestSelection {
            path: "test/extra_test.dart".into(),
            name: None,
        });
        assert!(validate_config_limits(&config).is_err());
        config.selections.pop();
        for selection in &mut config.selections {
            selection.name = Some("a".repeat(500));
        }
        assert!(validate_config_limits(&config)
            .unwrap_err()
            .to_string()
            .contains("2 MiB"));
    }
    #[test]
    fn discovers_only_bounded_owned_test_files_and_escapes_exact_names() {
        let root = tempfile::tempdir().unwrap();
        fs::write(root.path().join("pubspec.yaml"), "name: fixture\n").unwrap();
        fs::create_dir_all(root.path().join("test/nested")).unwrap();
        fs::write(root.path().join("test/nested/one_test.dart"), "").unwrap();
        fs::write(root.path().join("test/helper.dart"), "").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(
            root.path().join("test/nested"),
            root.path().join("test/linked"),
        )
        .unwrap();
        assert_eq!(
            discover(root.path()).unwrap(),
            vec!["test/nested/one_test.dart"]
        );
        assert_eq!(exact_name("group case [a].*"), r"^group case \[a\]\.\*$");
        assert!(validate_selection(
            root.path(),
            &TestSelection {
                path: "../escape_test.dart".into(),
                name: None
            }
        )
        .is_err());
    }
    fn run() -> Arc<TestRun> {
        Arc::new(TestRun {
            snapshot: Mutex::new(TestRunSnapshot {
                id: "test".into(),
                project_path: "/project".into(),
                state: "running".into(),
                tests: vec![],
                passed: 0,
                failed: 0,
                skipped: 0,
                exit_code: None,
                error: None,
            }),
            logs: Mutex::new(LogBuffer::new(100, 65536)),
            cancel: watch::channel(false).0,
            done: watch::channel(false).0,
        })
    }
    async fn event(run: &TestRun, event: Value, suites: &mut HashMap<i64, String>) {
        run.record_line(
            &serde_json::to_vec(&event).unwrap(),
            true,
            0,
            "/project",
            "",
            suites,
        )
        .await;
    }
    #[tokio::test]
    async fn machine_events_associate_tests_errors_skips_hidden_loads_and_completion() {
        let run = run();
        let mut suites = HashMap::new();
        event(
            &run,
            json!({"type":"suite","suite":{"id":3,"path":"/project/test/one_test.dart"}}),
            &mut suites,
        )
        .await;
        for (id, name) in [(1, "passes"), (2, "fails"), (3, "skips"), (4, "loading")] {
            event(
                &run,
                json!({"type":"testStart","test":{"id":id,"name":name,"suiteID":3}}),
                &mut suites,
            )
            .await;
        }
        event(
            &run,
            json!({"type":"testDone","testID":1,"result":"success"}),
            &mut suites,
        )
        .await;
        event(&run, json!({"type":"error","testID":2,"error":"expected true","stackTrace":"test/one_test.dart:8:4"}), &mut suites).await;
        event(
            &run,
            json!({"type":"testDone","testID":2,"result":"failure"}),
            &mut suites,
        )
        .await;
        event(
            &run,
            json!({"type":"testDone","testID":3,"result":"success","skipped":true}),
            &mut suites,
        )
        .await;
        event(
            &run,
            json!({"type":"testDone","testID":4,"result":"success","hidden":true}),
            &mut suites,
        )
        .await;
        event(&run, json!({"type":"done","success":false}), &mut suites).await;
        let snapshot = run.snapshot.lock().await;
        assert_eq!(
            (snapshot.passed, snapshot.failed, snapshot.skipped),
            (1, 1, 1)
        );
        assert_eq!(snapshot.tests.len(), 3);
        assert_eq!(snapshot.tests[1].path, "test/one_test.dart");
        assert_eq!(snapshot.tests[1].error.as_deref(), Some("expected true"));
        assert!(snapshot.error.is_some());
    }
    #[tokio::test]
    async fn oversized_machine_line_is_discarded_and_following_events_still_parse() {
        let run = run();
        let mut bytes = vec![b'x'; 300 * 1024];
        bytes.push(b'\n');
        bytes.extend_from_slice(
            b"{\"type\":\"testStart\",\"test\":{\"id\":1,\"name\":\"after\"}}\n",
        );
        run.read_output(&bytes[..], true, 0, "/project", "test/one_test.dart")
            .await
            .unwrap();
        assert_eq!(run.snapshot.lock().await.tests[0].name, "after");
        assert!(
            run.logs
                .lock()
                .await
                .query(None, 100, Some("256 KiB"))
                .entries
                .len()
                == 1
        );
    }
    #[cfg(unix)]
    fn fake_sdk(root: &Path, body: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let sdk = root.join("sdk");
        fs::create_dir_all(sdk.join("bin")).unwrap();
        let program = sdk.join("bin/flutter");
        fs::write(&program, format!("#!/usr/bin/env python3\nimport json,sys,time,os\nif '--version' in sys.argv:\n print(json.dumps({{'frameworkVersion':'3.test','dartSdkVersion':'3.test'}}));sys.exit(0)\n{body}\n")).unwrap();
        fs::set_permissions(&program, fs::Permissions::from_mode(0o755)).unwrap();
        sdk
    }
    #[cfg(unix)]
    async fn wait_run(manager: &TestManager, id: &str) -> TestRunSnapshot {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let snapshot = manager.snapshot(id).await.unwrap();
                if finished(&snapshot.state) {
                    break snapshot;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap()
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn fake_machine_run_keeps_failure_exit_code_and_can_retry_failed_case() {
        let root = tempfile::tempdir().unwrap();
        fs::write(root.path().join("pubspec.yaml"), "name: fixture\n").unwrap();
        fs::create_dir(root.path().join("test")).unwrap();
        fs::write(root.path().join("test/one_test.dart"), "").unwrap();
        let sdk = fake_sdk(
            root.path(),
            r#"
with open('invocations.jsonl','a') as f:f.write(json.dumps(sys.argv[1:])+'\n')
retry='--name' in sys.argv
for e in [{'type':'suite','suite':{'id':0,'path':os.path.join(os.getcwd(),'test/one_test.dart')}},{'type':'testStart','test':{'id':1,'name':'case [one]','suiteID':0}},{'type':'testDone','testID':1,'result':'success' if retry else 'failure'},{'type':'done','success':retry}]:print(json.dumps(e),flush=True)
sys.exit(0 if retry else 1)
"#,
        );
        let manager = TestManager::default();
        let config = TestRunConfig {
            project_path: root.path().to_string_lossy().into_owned(),
            sdk_path: Some(sdk.to_string_lossy().into_owned()),
            selections: vec![],
        };
        let first = manager.start(config.clone()).await.unwrap();
        let first = wait_run(&manager, &first.id).await;
        assert_eq!(first.state, "failed");
        assert_eq!(first.exit_code, Some(1));
        assert_eq!(first.failed, 1);
        let mut retry = config;
        retry.selections = vec![TestSelection {
            path: first.tests[0].path.clone(),
            name: Some(first.tests[0].name.clone()),
        }];
        let second = manager.start(retry).await.unwrap();
        let second = wait_run(&manager, &second.id).await;
        assert_eq!(second.state, "succeeded");
        assert_eq!(second.passed, 1);
        let args = fs::read_to_string(root.path().join("invocations.jsonl")).unwrap();
        assert!(args.contains(r#""^case \\[one\\]$""#));
        manager.shutdown().await;
        assert!(manager.list().await.is_empty());
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn cancellation_owns_process_and_allows_later_run() {
        let root = tempfile::tempdir().unwrap();
        fs::write(root.path().join("pubspec.yaml"), "name: fixture\n").unwrap();
        let sdk = fake_sdk(root.path(), "open('pid','w').write(str(os.getpid()))\nprint(json.dumps({'type':'testStart','test':{'id':1,'name':'waiting'}}),flush=True)\ntime.sleep(60)");
        let manager = TestManager::default();
        let config = TestRunConfig {
            project_path: root.path().to_string_lossy().into_owned(),
            sdk_path: Some(sdk.to_string_lossy().into_owned()),
            selections: vec![],
        };
        let started = manager.start(config.clone()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            while !root.path().join("pid").exists() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert!(manager.start(config.clone()).await.is_err());
        manager.stop(&started.id).await.unwrap();
        let snapshot = manager.snapshot(&started.id).await.unwrap();
        assert_eq!(snapshot.state, "cancelled");
        let pid: i32 = fs::read_to_string(root.path().join("pid"))
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        let next = manager.start(config).await.unwrap();
        manager.stop(&next.id).await.unwrap();
        manager.shutdown().await;
    }
    #[tokio::test]
    async fn shutdown_rejects_start_waiting_for_registration() {
        let root = tempfile::tempdir().unwrap();
        fs::write(root.path().join("pubspec.yaml"), "name: fixture\n").unwrap();
        let manager = Arc::new(TestManager::default());
        let registration = manager.runs.lock().await;
        let pending_manager = manager.clone();
        let config = TestRunConfig {
            project_path: root.path().to_string_lossy().into_owned(),
            sdk_path: None,
            selections: vec![],
        };
        let pending = tokio::spawn(async move { pending_manager.start(config).await });
        tokio::task::yield_now().await;
        let shutdown_manager = manager.clone();
        let shutdown = tokio::spawn(async move {
            shutdown_manager.shutdown().await;
        });
        while !manager.closing.load(Ordering::Acquire) {
            tokio::task::yield_now().await;
        }
        drop(registration);
        assert!(pending
            .await
            .unwrap()
            .unwrap_err()
            .to_string()
            .contains("shutting down"));
        shutdown.await.unwrap();
        assert!(manager.list().await.is_empty());
    }
}
