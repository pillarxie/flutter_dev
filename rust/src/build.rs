use crate::{
    log::{LogBuffer, LogPage},
    process::{flutter_program, OwnedProcess},
};
use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    sync::{watch, Mutex},
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BuildPreset {
    pub id: String,
    pub name: String,
    pub target: String,
    pub args: Vec<String>,
    pub output_directory: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BuildConfiguration {
    pub project_path: String,
    pub sdk_path: Option<String>,
    pub target: String,
    pub args: Vec<String>,
    pub output_directory: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BuildSnapshot {
    pub id: String,
    pub project_path: String,
    pub state: String,
    pub target: String,
    pub output_directory: Option<String>,
    pub error: Option<String>,
    pub exit_code: Option<i32>,
}

pub fn default_build_presets() -> Vec<BuildPreset> {
    [
        ("apk", "Android APK"),
        ("appbundle", "Android App Bundle"),
        ("ios", "iOS App"),
        ("ipa", "iOS IPA"),
        ("web", "Web"),
        ("macos", "macOS"),
        ("windows", "Windows"),
        ("linux", "Linux"),
    ]
    .into_iter()
    .map(|(target, name)| BuildPreset {
        id: format!("builtin-{target}"),
        name: format!("{name} Release"),
        target: target.into(),
        args: vec!["--release".into()],
        output_directory: None,
    })
    .collect()
}

fn validate_target(target: &str) -> Result<()> {
    anyhow::ensure!(
        matches!(
            target,
            "apk"
                | "appbundle"
                | "ios"
                | "ipa"
                | "web"
                | "macos"
                | "windows"
                | "linux"
                | "aar"
                | "bundle"
        ),
        "Unsupported Flutter build target: {target}"
    );
    Ok(())
}

fn validate_args(args: &[String], output_directory: Option<&str>) -> Result<()> {
    anyhow::ensure!(
        args.len() <= 256
            && args
                .iter()
                .all(|arg| !arg.contains('\0') && arg.len() <= 16384),
        "Build arguments exceed limits or contain null characters"
    );
    anyhow::ensure!(
        output_directory.is_none_or(|path| !path.contains('\0') && path.len() <= 16384),
        "Invalid build output directory"
    );
    Ok(())
}

pub(crate) fn validate_presets(presets: &[BuildPreset]) -> Result<()> {
    anyhow::ensure!(
        presets.len() <= 100,
        "At most 100 build presets are supported"
    );
    let mut ids = HashSet::new();
    for preset in presets {
        anyhow::ensure!(
            !preset.id.trim().is_empty()
                && !preset.name.trim().is_empty()
                && preset.id.len() <= 256
                && preset.name.len() <= 256,
            "Build preset requires an ID and name"
        );
        anyhow::ensure!(
            ids.insert(&preset.id),
            "Duplicate build preset ID: {}",
            preset.id
        );
        validate_target(&preset.target)?;
        validate_args(&preset.args, preset.output_directory.as_deref())?;
    }
    Ok(())
}

type OutputOpener = Arc<dyn Fn(&Path) -> Result<()> + Send + Sync>;

pub struct BuildManager {
    builds: Mutex<HashMap<String, Arc<Build>>>,
    ids: AtomicU64,
    opener: OutputOpener,
}

impl Default for BuildManager {
    fn default() -> Self {
        Self {
            builds: Mutex::new(HashMap::new()),
            ids: AtomicU64::new(1),
            opener: Arc::new(open_directory),
        }
    }
}

struct Build {
    snapshot: Mutex<BuildSnapshot>,
    logs: Mutex<LogBuffer>,
    artifact: Mutex<Option<PathBuf>>,
    cancel: watch::Sender<bool>,
    done: watch::Sender<bool>,
    opener: OutputOpener,
}

impl BuildManager {
    pub async fn start(&self, mut config: BuildConfiguration) -> Result<BuildSnapshot> {
        validate_target(&config.target)?;
        validate_args(&config.args, config.output_directory.as_deref())?;
        let project = tokio::fs::canonicalize(&config.project_path)
            .await
            .context("Build project folder does not exist")?;
        anyhow::ensure!(
            project.join("pubspec.yaml").is_file(),
            "Build project has no pubspec.yaml"
        );
        config.project_path = project.to_string_lossy().into_owned();
        let mut builds = self.builds.lock().await;
        for build in builds.values() {
            let snapshot = build.snapshot.lock().await;
            if snapshot.project_path == config.project_path && !is_finished(&snapshot.state) {
                bail!("A build is already running for this project");
            }
        }
        // Keep completed history and its logs bounded as well as individual log buffers.
        if builds.len() >= 32 {
            let mut completed = Vec::new();
            for (id, build) in builds.iter() {
                if is_finished(&build.snapshot.lock().await.state) {
                    completed.push(id.clone());
                }
            }
            completed.sort_by_key(|id| {
                id.strip_prefix("build-")
                    .and_then(|id| id.parse::<u64>().ok())
                    .unwrap_or(0)
            });
            for id in completed.into_iter().take(builds.len().saturating_sub(31)) {
                builds.remove(&id);
            }
            anyhow::ensure!(builds.len() < 32, "Too many active builds");
        }
        let snapshot = BuildSnapshot {
            id: format!("build-{}", self.ids.fetch_add(1, Ordering::Relaxed)),
            project_path: config.project_path.clone(),
            state: "starting".into(),
            target: config.target.clone(),
            output_directory: None,
            error: None,
            exit_code: None,
        };
        let (cancel, _) = watch::channel(false);
        let (done, _) = watch::channel(false);
        let build = Arc::new(Build {
            snapshot: Mutex::new(snapshot.clone()),
            logs: Mutex::new(LogBuffer::new(5000, 2 * 1024 * 1024)),
            artifact: Mutex::new(None),
            cancel,
            done,
            opener: self.opener.clone(),
        });
        builds.insert(snapshot.id.clone(), build.clone());
        tokio::spawn(async move {
            build.run(config).await;
        });
        Ok(snapshot)
    }

    async fn get(&self, id: &str) -> Result<Arc<Build>> {
        self.builds
            .lock()
            .await
            .get(id)
            .cloned()
            .ok_or_else(|| anyhow!("Unknown build: {id}"))
    }

    pub async fn snapshot(&self, id: &str) -> Result<BuildSnapshot> {
        Ok(self.get(id).await?.snapshot.lock().await.clone())
    }

    pub async fn logs(&self, id: &str, after_id: u64, limit: u32) -> Result<LogPage> {
        Ok(self
            .get(id)
            .await?
            .logs
            .lock()
            .await
            .query(Some(after_id), limit as usize, None))
    }

    pub async fn stop(&self, id: &str) -> Result<()> {
        self.get(id).await?.stop().await;
        Ok(())
    }

    pub async fn open_output(&self, id: &str) -> Result<()> {
        let build = self.get(id).await?;
        let snapshot = build.snapshot.lock().await.clone();
        anyhow::ensure!(snapshot.state == "succeeded", "Build has not succeeded");
        let path = PathBuf::from(
            snapshot
                .output_directory
                .context("Build output directory is unavailable")?,
        );
        let result = build.open(path).await;
        build.snapshot.lock().await.error = result
            .as_ref()
            .err()
            .map(|error| format!("Build succeeded, but could not open output: {error:#}"));
        result
    }

    pub async fn shutdown(&self) {
        let builds: Vec<_> = self.builds.lock().await.values().cloned().collect();
        let mut tasks = Vec::new();
        for build in builds {
            tasks.push(tokio::spawn(async move {
                build.stop().await;
            }));
        }
        for task in tasks {
            let _ = task.await;
        }
        self.builds.lock().await.clear();
    }
}

fn is_finished(state: &str) -> bool {
    matches!(state, "succeeded" | "failed" | "cancelled")
}

impl Build {
    async fn stop(&self) {
        let mut done = self.done.subscribe();
        {
            let mut snapshot = self.snapshot.lock().await;
            if is_finished(&snapshot.state) {
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

    async fn run(self: Arc<Self>, config: BuildConfiguration) {
        let result = self.execute(&config).await;
        let mut snapshot = self.snapshot.lock().await;
        if *self.cancel.borrow() {
            snapshot.state = "cancelled".into();
            snapshot.error = result.err().map(|error| format!("{error:#}"));
        } else if let Err(error) = result {
            snapshot.state = "failed".into();
            snapshot.error = Some(format!("{error:#}"));
        } else {
            snapshot.state = "succeeded".into();
        }
        self.done.send_replace(true);
    }

    async fn execute(self: &Arc<Self>, config: &BuildConfiguration) -> Result<()> {
        let mut cancelled = self.cancel.subscribe();
        if *cancelled.borrow() {
            return Ok(());
        }
        let sdk = tokio::select! {
            result = crate::sdk::resolve_sdk(Some(config.project_path.clone()), config.sdk_path.clone()) => result?,
            _ = cancelled.changed() => return Ok(()),
        };
        if *cancelled.borrow() {
            return Ok(());
        }
        let mut args = vec!["build".into(), config.target.clone()];
        args.extend(config.args.clone());
        self.logs
            .lock()
            .await
            .push("system", &format!("flutter {}", args.join(" ")));
        self.logs
            .lock()
            .await
            .push("system", &format!("Flutter SDK: {}", sdk.path));
        if let Some(reason) = sdk.fallback_reason.as_ref() {
            self.logs.lock().await.push("system", reason);
        }
        let mut process = OwnedProcess::spawn(
            &flutter_program(&sdk),
            &args,
            Some(Path::new(&config.project_path)),
            &HashMap::new(),
        )?;
        // Flutter build does not consume interactive stdin.
        process.stdin.take();
        let stdout = process.stdout.take().context("Build stdout unavailable")?;
        let stderr = process.stderr.take().context("Build stderr unavailable")?;
        let out_build = self.clone();
        let err_build = self.clone();
        let out_project = config.project_path.clone();
        let err_project = config.project_path.clone();
        let out =
            tokio::spawn(
                async move { out_build.read_output(stdout, "stdout", &out_project).await },
            );
        let err =
            tokio::spawn(
                async move { err_build.read_output(stderr, "stderr", &err_project).await },
            );
        {
            let mut snapshot = self.snapshot.lock().await;
            if !*cancelled.borrow() {
                snapshot.state = "running".into();
            }
        }
        let status = tokio::select! {
            result = process.wait() => Some(result),
            _ = cancelled.changed() => { process.terminate(Duration::from_secs(2)).await?; None },
        };
        // Process ownership closes descendant pipes when it exits or is cancelled.
        let (out, err) = tokio::join!(out, err);
        out.context("Build stdout task failed")??;
        err.context("Build stderr task failed")??;
        let Some(status) = status else {
            return Ok(());
        };
        let status = status?;
        self.snapshot.lock().await.exit_code = status.code();
        anyhow::ensure!(
            status.success(),
            "Flutter build exited with {}",
            status
                .code()
                .map_or_else(|| "a signal".into(), |code| format!("code {code}"))
        );
        if *cancelled.borrow() {
            return Ok(());
        }
        let artifact = self.artifact.lock().await.clone();
        let output = resolve_output(config, artifact.as_deref());
        match output {
            Some(output) => {
                self.snapshot.lock().await.output_directory =
                    Some(output.to_string_lossy().into_owned());
                if let Err(error) = self.open(output).await {
                    let warning = format!("Build succeeded, but could not open output: {error:#}");
                    self.logs.lock().await.push("system", &warning);
                    self.snapshot.lock().await.error = Some(warning);
                }
            }
            None => {
                let warning = "Build succeeded, but the output directory could not be found. Set a custom output directory in the preset.";
                self.logs.lock().await.push("system", warning);
                self.snapshot.lock().await.error = Some(warning.into());
            }
        }
        Ok(())
    }

    async fn read_output(
        &self,
        mut stream: impl AsyncRead + Unpin,
        category: &str,
        project: &str,
    ) -> Result<()> {
        let mut buffer = [0u8; 8192];
        let mut line = Vec::new();
        loop {
            let length = stream.read(&mut buffer).await?;
            if length == 0 {
                break;
            }
            for byte in &buffer[..length] {
                if *byte == b'\n' || *byte == b'\r' || line.len() >= 16384 {
                    if !line.is_empty() {
                        self.record_output(category, &line, project).await;
                        line.clear();
                    }
                    if *byte == b'\n' || *byte == b'\r' {
                        continue;
                    }
                }
                line.push(*byte);
            }
        }
        if !line.is_empty() {
            self.record_output(category, &line, project).await;
        }
        Ok(())
    }

    async fn record_output(&self, category: &str, bytes: &[u8], project: &str) {
        let text = String::from_utf8_lossy(bytes);
        self.logs.lock().await.push(category, &text);
        if let Some(path) = built_path(&text) {
            *self.artifact.lock().await = Some(project_path(Path::new(project), &path));
        }
    }

    async fn open(&self, path: PathBuf) -> Result<()> {
        anyhow::ensure!(
            path.is_dir(),
            "Output directory no longer exists: {}",
            path.display()
        );
        let opener = self.opener.clone();
        tokio::task::spawn_blocking(move || opener(&path))
            .await
            .context("Output opener failed")?
    }
}

fn argument(args: &[String], names: &[&str]) -> Option<String> {
    let mut value = None;
    for (index, arg) in args.iter().enumerate() {
        for name in names {
            if arg == name {
                value = args
                    .get(index + 1)
                    .filter(|value| !value.starts_with('-'))
                    .cloned();
            } else if let Some(suffix) = arg.strip_prefix(&format!("{name}=")) {
                value = Some(suffix.into());
            }
        }
    }
    value.filter(|value| !value.trim().is_empty())
}

fn project_path(project: &Path, path: &str) -> PathBuf {
    let path = PathBuf::from(path);
    if path.is_absolute() {
        path
    } else {
        project.join(path)
    }
}

fn existing_directory(path: &Path) -> Option<PathBuf> {
    if path.is_dir()
        && path.extension().is_some_and(|extension| {
            extension.eq_ignore_ascii_case("app") || extension.eq_ignore_ascii_case("xcarchive")
        })
    {
        // macOS `open` launches app bundles. Reveal their containing folder instead.
        path.parent().map(Path::to_path_buf)
    } else if path.is_dir() {
        Some(path.to_path_buf())
    } else if path.is_file() {
        path.parent().map(Path::to_path_buf)
    } else {
        None
    }
}

fn resolve_output(config: &BuildConfiguration, artifact: Option<&Path>) -> Option<PathBuf> {
    let project = Path::new(&config.project_path);
    if let Some(path) = config
        .output_directory
        .as_deref()
        .filter(|path| !path.trim().is_empty())
    {
        return existing_directory(&project_path(project, path));
    }
    if let Some(path) = artifact.and_then(existing_directory) {
        return Some(path);
    }
    let output = match config.target.as_str() {
        "web" | "aar" => argument(&config.args, &["--output", "--output-dir", "-o"]),
        "bundle" => argument(&config.args, &["--asset-dir"]),
        _ => None,
    };
    if let Some(path) = output {
        let path = project_path(project, &path);
        return if config.target == "aar" {
            existing_directory(&path.join("host/outputs/repo"))
                .or_else(|| existing_directory(&path.join("outputs/repo")))
        } else {
            existing_directory(&path)
        };
    }
    // This also recognizes SDK versions/plugins that accept a custom build directory;
    // arguments are never rewritten into unsupported flags.
    let root = project_path(
        project,
        &argument(&config.args, &["--build-dir"]).unwrap_or_else(|| "build".into()),
    );
    let mode = if config.args.iter().any(|arg| arg == "--debug") {
        "debug"
    } else if config.args.iter().any(|arg| arg == "--profile") {
        "profile"
    } else {
        "release"
    };
    let capital_mode = match mode {
        "debug" => "Debug",
        "profile" => "Profile",
        _ => "Release",
    };
    let platform = argument(&config.args, &["--target-platform"]);
    let arch = platform
        .as_deref()
        .and_then(|platform| platform.rsplit_once('-').map(|(_, arch)| arch))
        .unwrap_or(if cfg!(target_arch = "aarch64") {
            "arm64"
        } else {
            "x64"
        });
    let path = match config.target.as_str() {
        "apk" => {
            let app = root.join("app/outputs/flutter-apk");
            if app.is_dir() {
                app
            } else {
                root.join("host/outputs/apk")
            }
        }
        "appbundle" => {
            let app = root.join("app/outputs/bundle");
            if app.is_dir() {
                app
            } else {
                root.join("host/outputs/bundle")
            }
        }
        "ios" => root.join(if config.args.iter().any(|arg| arg == "--simulator") {
            "ios/iphonesimulator"
        } else {
            "ios/iphoneos"
        }),
        "ipa" => {
            let ipa = root.join("ios/ipa");
            if ipa.is_dir() {
                ipa
            } else {
                root.join("ios/archive")
            }
        }
        "web" => root.join("web"),
        "macos" => {
            let flavor = argument(&config.args, &["--flavor"]);
            root.join("macos/Build/Products").join(flavor.map_or_else(
                || capital_mode.into(),
                |flavor| format!("{capital_mode}-{flavor}"),
            ))
        }
        "windows" => root
            .join("windows")
            .join(arch)
            .join("runner")
            .join(capital_mode),
        "linux" => root.join("linux").join(arch).join(mode).join("bundle"),
        "aar" => {
            let host = root.join("host/outputs/repo");
            if host.is_dir() {
                host
            } else {
                root.join("outputs/repo")
            }
        }
        "bundle" => root.join("flutter_assets"),
        _ => return None,
    };
    existing_directory(&path)
}

fn built_path(text: &str) -> Option<String> {
    let mut clean = String::new();
    let mut chars = text.chars();
    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            if chars.next() == Some('[') {
                for code in chars.by_ref() {
                    if ('@'..='~').contains(&code) {
                        break;
                    }
                }
            }
        } else {
            clean.push(ch);
        }
    }
    let (_, path) = clean.split_once("Built ")?;
    let path = path.strip_prefix("IPA to ").unwrap_or(path);
    let path = path.trim();
    // Flutter appends an optional size such as " (14.5MB).". Parentheses and
    // trailing dots can also be part of valid artifact names, so preserve them.
    let path = if let Some((candidate, suffix)) = path.rsplit_once(" (") {
        let suffix = suffix.trim_end_matches('.').strip_suffix(')');
        if suffix.is_some_and(|size| {
            let size = size.trim().to_ascii_lowercase();
            ["gb", "mb", "kb", "bytes", "b"].into_iter().any(|unit| {
                size.strip_suffix(unit).is_some_and(|number| {
                    !number.trim().is_empty()
                        && number
                            .trim()
                            .chars()
                            .all(|ch| ch.is_ascii_digit() || ch == '.')
                })
            })
        }) {
            candidate
        } else {
            path
        }
    } else {
        path
    };
    (!path.is_empty()).then(|| path.to_owned())
}

fn open_directory(path: &Path) -> Result<()> {
    use std::process::{Command, Stdio};
    let program = if cfg!(target_os = "macos") {
        "open"
    } else if cfg!(windows) {
        "explorer.exe"
    } else {
        "xdg-open"
    };
    let mut child = Command::new(program)
        .arg(path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("Start {program}"))?;
    // Explorer may reuse an existing window or stay alive as the shell process.
    if cfg!(windows) {
        return Ok(());
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = child.try_wait()? {
            anyhow::ensure!(status.success(), "{program} exited with {status}");
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("{program} timed out");
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn config(project: &Path, sdk: Option<&Path>) -> BuildConfiguration {
        BuildConfiguration {
            project_path: project.to_string_lossy().into_owned(),
            sdk_path: sdk.map(|path| path.to_string_lossy().into_owned()),
            target: "web".into(),
            args: vec!["--release".into()],
            output_directory: None,
        }
    }

    #[test]
    fn output_paths_follow_target_mode_architecture_and_custom_arguments() {
        let fixture = tempfile::tempdir().unwrap();
        let mut config = config(fixture.path(), None);
        for (target, args, path) in [
            ("apk", vec![], "build/app/outputs/flutter-apk"),
            (
                "appbundle",
                vec!["--flavor=production"],
                "build/app/outputs/bundle",
            ),
            (
                "ios",
                vec!["--debug", "--simulator"],
                "build/ios/iphonesimulator",
            ),
            ("ios", vec!["--profile"], "build/ios/iphoneos"),
            ("ipa", vec![], "build/ios/archive"),
            ("web", vec!["--output-dir", "web output"], "web output"),
            (
                "macos",
                vec!["--profile", "--flavor=staging"],
                "build/macos/Build/Products/Profile-staging",
            ),
            (
                "windows",
                vec!["--debug", "--target-platform=windows-arm64"],
                "build/windows/arm64/runner/Debug",
            ),
            (
                "linux",
                vec!["--profile", "--target-platform", "linux-x64"],
                "build/linux/x64/profile/bundle",
            ),
            ("aar", vec![], "build/host/outputs/repo"),
            ("aar", vec!["-o", "aar output"], "aar output/outputs/repo"),
            ("bundle", vec!["--asset-dir=custom assets"], "custom assets"),
            ("bundle", vec![], "build/flutter_assets"),
        ] {
            let path = fixture.path().join(path);
            fs::create_dir_all(&path).unwrap();
            config.target = target.into();
            config.args = args.into_iter().map(str::to_owned).collect();
            assert_eq!(resolve_output(&config, None), Some(path), "{target}");
        }
        config.target = "web".into();
        config.args = vec!["--build-dir=custom build".into()];
        let path = fixture.path().join("custom build/web");
        fs::create_dir_all(&path).unwrap();
        assert_eq!(resolve_output(&config, None), Some(path));
        let artifact = fixture.path().join("actual artifact/output.apk");
        fs::create_dir_all(artifact.parent().unwrap()).unwrap();
        fs::write(&artifact, "artifact").unwrap();
        assert_eq!(
            resolve_output(&config, Some(&artifact)),
            Some(artifact.parent().unwrap().to_path_buf())
        );
        config.output_directory = Some("custom assets".into());
        assert_eq!(
            resolve_output(&config, Some(&artifact)),
            Some(fixture.path().join("custom assets"))
        );
        config.output_directory = Some("missing".into());
        assert_eq!(resolve_output(&config, Some(&artifact)), None);
        config.output_directory = None;
        let app = fixture
            .path()
            .join("build/macos/Build/Products/Release/Fixture.app");
        fs::create_dir_all(&app).unwrap();
        assert_eq!(
            resolve_output(&config, Some(&app)),
            Some(app.parent().unwrap().to_path_buf())
        );
        let archive = fixture.path().join("build/ios/archive/Runner.xcarchive");
        fs::create_dir_all(&archive).unwrap();
        assert_eq!(
            resolve_output(&config, Some(&archive)),
            Some(archive.parent().unwrap().to_path_buf())
        );
        config.output_directory = Some(app.to_string_lossy().into_owned());
        assert_eq!(
            resolve_output(&config, None),
            Some(app.parent().unwrap().to_path_buf())
        );
    }

    #[test]
    fn built_log_paths_keep_spaces_and_strip_terminal_codes_and_sizes() {
        assert_eq!(
            built_path("\x1b[32m✓ Built build/custom output/app.apk (14.5MB).\x1b[0m"),
            Some("build/custom output/app.apk".into())
        );
        assert_eq!(
            built_path("Built IPA to build/ios/ipa (28MB)."),
            Some("build/ios/ipa".into())
        );
        assert_eq!(
            built_path("✓ Built build/windows/arm64/runner/Release/app.exe"),
            Some("build/windows/arm64/runner/Release/app.exe".into())
        );
        assert_eq!(built_path("Building application..."), None);
        assert_eq!(
            built_path("Built build/target (custom)/artifact."),
            Some("build/target (custom)/artifact.".into())
        );
    }

    #[cfg(unix)]
    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        let fixture = tempfile::tempdir().unwrap();
        let sdk = fixture.path().join("fake sdk");
        let project = fixture.path().join("project with spaces");
        fs::create_dir_all(sdk.join("bin")).unwrap();
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("pubspec.yaml"), "name: fixture\n").unwrap();
        let script = r#"#!/usr/bin/env python3
import json, os, subprocess, sys, time
if '--version' in sys.argv:
    print(json.dumps({'frameworkVersion':'3.test','dartSdkVersion':'3.test'})); sys.exit(0)
with open('invocation.json','w') as f: json.dump(sys.argv[1:],f)
if '--slow' in sys.argv:
    child=subprocess.Popen(['sleep','60'])
    print('child pid: '+str(child.pid),flush=True)
    time.sleep(60)
if '--fail' in sys.argv:
    print('fixture compile error',file=sys.stderr,flush=True);sys.exit(7)
if '--many-logs' in sys.argv:
    for i in range(5500): print('log '+str(i))
    sys.stdout.write('x'*300000+'\n')
os.makedirs('custom artifacts',exist_ok=True)
with open('custom artifacts/output.apk','w') as f:f.write('artifact')
print('✓ Built custom artifacts/output.apk (1MB).',flush=True)
print('fixture diagnostic',file=sys.stderr,flush=True)
"#;
        let executable = sdk.join("bin/flutter");
        fs::write(&executable, script).unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        (
            fixture,
            project.canonicalize().unwrap(),
            sdk.canonicalize().unwrap(),
        )
    }

    #[cfg(unix)]
    fn manager(opener: OutputOpener) -> BuildManager {
        BuildManager {
            builds: Mutex::new(HashMap::new()),
            ids: AtomicU64::new(1),
            opener,
        }
    }

    #[cfg(unix)]
    async fn finish(manager: &BuildManager, id: &str) -> BuildSnapshot {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let snapshot = manager.snapshot(id).await.unwrap();
                if is_finished(&snapshot.state) {
                    return snapshot;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap()
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn success_executes_literal_arguments_pages_logs_and_opens_actual_artifact() {
        let (_fixture, project, sdk) = fixture();
        let opened = Arc::new(std::sync::Mutex::new(Vec::<PathBuf>::new()));
        let open_paths = opened.clone();
        let manager = manager(Arc::new(move |path| {
            open_paths.lock().unwrap().push(path.to_path_buf());
            Ok(())
        }));
        let mut configuration = config(&project, Some(&sdk));
        configuration
            .args
            .push("--dart-define=VALUE=$(echo injection) value with spaces".into());
        let started = manager.start(configuration.clone()).await.unwrap();
        assert_eq!(started.state, "starting");
        let completed = finish(&manager, &started.id).await;
        assert_eq!(completed.state, "succeeded");
        assert_eq!(completed.exit_code, Some(0));
        assert!(completed.error.is_none());
        let expected = project.join("custom artifacts");
        assert_eq!(
            completed.output_directory,
            Some(expected.to_string_lossy().into_owned())
        );
        assert_eq!(*opened.lock().unwrap(), vec![expected]);
        let invocation: Vec<String> =
            serde_json::from_str(&fs::read_to_string(project.join("invocation.json")).unwrap())
                .unwrap();
        assert_eq!(
            invocation,
            [vec!["build".into(), "web".into()], configuration.args].concat()
        );
        let first = manager.logs(&started.id, 0, 1).await.unwrap();
        assert_eq!(first.entries.len(), 1);
        let next = manager
            .logs(&started.id, first.next_after_id.unwrap(), 100)
            .await
            .unwrap();
        assert!(next
            .entries
            .iter()
            .any(|entry| entry.category == "stderr" && entry.text == "fixture diagnostic"));
        assert!(manager
            .logs(&started.id, next.next_after_id.unwrap(), 100)
            .await
            .unwrap()
            .entries
            .is_empty());
        manager.shutdown().await;
        assert!(manager.snapshot(&started.id).await.is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn failing_build_retains_exit_code_and_stderr_without_opening_output() {
        let (_fixture, project, sdk) = fixture();
        let manager = manager(Arc::new(|_| panic!("Failed build must not open output")));
        let mut config = config(&project, Some(&sdk));
        config.args.push("--fail".into());
        let started = manager.start(config).await.unwrap();
        let failed = finish(&manager, &started.id).await;
        assert_eq!(failed.state, "failed");
        assert_eq!(failed.exit_code, Some(7));
        assert!(failed.error.unwrap().contains("code 7"));
        assert!(manager
            .logs(&started.id, 0, 100)
            .await
            .unwrap()
            .entries
            .iter()
            .any(|entry| entry.text == "fixture compile error"));
        assert!(manager.open_output(&started.id).await.is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cancellation_prevents_duplicates_cleans_owned_process_and_allows_restart() {
        let (_fixture, project, sdk) = fixture();
        let manager = manager(Arc::new(|_| Ok(())));
        let mut slow = config(&project, Some(&sdk));
        slow.args.push("--slow".into());
        let started = manager.start(slow.clone()).await.unwrap();
        assert!(manager
            .start(slow.clone())
            .await
            .unwrap_err()
            .to_string()
            .contains("already running"));
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                if manager
                    .logs(&started.id, 0, 100)
                    .await
                    .unwrap()
                    .entries
                    .iter()
                    .any(|entry| entry.text.starts_with("child pid:"))
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        tokio::time::timeout(Duration::from_secs(5), manager.stop(&started.id))
            .await
            .unwrap()
            .unwrap();
        let cancelled = manager.snapshot(&started.id).await.unwrap();
        assert_eq!(cancelled.state, "cancelled");
        assert!(cancelled.output_directory.is_none());
        let restarted = manager.start(config(&project, Some(&sdk))).await.unwrap();
        assert_eq!(finish(&manager, &restarted.id).await.state, "succeeded");
        let another = manager.start(slow).await.unwrap();
        manager.shutdown().await;
        assert!(manager.snapshot(&another.id).await.is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn opening_failure_keeps_success_and_manual_retry_clears_warning() {
        use std::sync::atomic::AtomicBool;
        let (_fixture, project, sdk) = fixture();
        let fail = Arc::new(AtomicBool::new(true));
        let opener_fail = fail.clone();
        let manager = manager(Arc::new(move |_| {
            if opener_fail.load(Ordering::Relaxed) {
                bail!("fixture open failure");
            }
            Ok(())
        }));
        let started = manager.start(config(&project, Some(&sdk))).await.unwrap();
        let completed = finish(&manager, &started.id).await;
        assert_eq!(completed.state, "succeeded");
        assert!(completed.error.unwrap().contains("fixture open failure"));
        fail.store(false, Ordering::Relaxed);
        manager.open_output(&started.id).await.unwrap();
        assert!(manager.snapshot(&started.id).await.unwrap().error.is_none());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn build_logs_bound_line_count_and_single_line_memory() {
        let (_fixture, project, sdk) = fixture();
        let manager = manager(Arc::new(|_| Ok(())));
        let mut config = config(&project, Some(&sdk));
        config.args.push("--many-logs".into());
        let started = manager.start(config).await.unwrap();
        assert_eq!(finish(&manager, &started.id).await.state, "succeeded");
        let page = manager.logs(&started.id, 0, 10000).await.unwrap();
        assert_eq!(page.entries.len(), 1000);
        assert!(page.dropped_before_id.is_some());
        let mut count = page.entries.len();
        let mut cursor = page.next_after_id.unwrap();
        loop {
            let page = manager.logs(&started.id, cursor, 1000).await.unwrap();
            if page.entries.is_empty() {
                break;
            }
            assert!(page.entries.iter().all(|entry| entry.text.len() <= 16384));
            count += page.entries.len();
            cursor = page.next_after_id.unwrap();
        }
        assert!(count <= 5000);
    }
}
