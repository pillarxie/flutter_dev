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
    pub version: Option<BuildVersion>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BuildVersion {
    pub build_name: Option<String>,
    pub build_number: Option<String>,
}

pub async fn read_build_version(project_path: String, args: Vec<String>) -> Result<BuildVersion> {
    validate_args(&args, None)?;
    tokio::task::spawn_blocking(move || {
        use std::io::Read;
        let path = Path::new(&project_path).join("pubspec.yaml");
        let file = std::fs::File::open(&path)
            .with_context(|| format!("Read build version from {}", path.display()))?;
        let mut content = Vec::new();
        file.take(1024 * 1024 + 1).read_to_end(&mut content)?;
        anyhow::ensure!(
            content.len() <= 1024 * 1024,
            "Project pubspec exceeds build version size limit"
        );
        let manifest: serde_yaml::Value =
            serde_yaml::from_slice(&content).context("Invalid project pubspec YAML")?;
        let manifest = manifest
            .as_mapping()
            .context("Project pubspec must contain a YAML mapping")?;
        let version = manifest.get("version").and_then(serde_yaml::Value::as_str);
        Ok(build_version(version, &args))
    })
    .await?
}

fn build_version(version: Option<&str>, args: &[String]) -> BuildVersion {
    // Match FlutterManifest's '+' split without inventing platform-specific defaults.
    let mut components = version
        .filter(|version| valid_manifest_version(version))
        .unwrap_or_default()
        .split('+');
    let mut version = BuildVersion {
        build_name: components
            .next()
            .filter(|value| !value.is_empty())
            .map(str::to_owned),
        build_number: components
            .next()
            .filter(|value| !value.is_empty())
            .map(str::to_owned),
    };
    let mut arguments = args.iter();
    while let Some(arg) = arguments.next() {
        if arg == "--" {
            break;
        }
        let (name, inline_value) = arg
            .split_once('=')
            .map_or((arg.as_str(), None), |(name, value)| (name, Some(value)));
        let destination = match name {
            "--build-name" => Some(&mut version.build_name),
            "--build-number" => Some(&mut version.build_number),
            _ => None,
        };
        if let Some(destination) = destination {
            let value = inline_value.or_else(|| arguments.next().map(String::as_str));
            if let Some(value) = value {
                *destination = (!value.is_empty()).then(|| value.to_owned());
            }
        } else if inline_value.is_none()
            && matches!(
                name,
                "--dart-define"
                    | "--dart-defines"
                    | "-D"
                    | "--dart-define-from-file"
                    | "--flavor"
                    | "--target"
                    | "-t"
                    | "--output"
                    | "--output-dir"
                    | "-o"
                    | "--target-platform"
                    | "--target-arch"
                    | "--target-sysroot"
                    | "--asset-dir"
                    | "--depfile"
                    | "--split-debug-info"
                    | "--packages"
                    | "--filesystem-root"
                    | "--filesystem-scheme"
                    | "--extra-front-end-options"
                    | "--extra-gen-snapshot-options"
                    | "--enable-experiment"
                    | "--performance-measurement-file"
                    | "--code-size-directory"
                    | "--export-options-plist"
                    | "--export-method"
                    | "--base-href"
                    | "--pwa-strategy"
                    | "--static-assets-url"
                    | "--optimization-level"
                    | "-O"
                    | "--dart2js-optimization"
                    | "--web-renderer"
                    | "--web-browser-flag"
                    | "--web-header"
                    | "--web-hostname"
                    | "--web-port"
                    | "--android-project-arg"
                    | "-P"
                    | "--android-project-cache-dir"
                    | "--frontend-server-starter-path"
                    | "--initialize-from-dill"
                    | "--native-assets-yaml-file"
            )
        {
            // An option's value can itself begin with '--'; it is still not a version flag.
            let _ = arguments.next();
        }
    }
    version
}

fn valid_manifest_version(version: &str) -> bool {
    // pub_semver's completeVersion requires three numeric parts, followed by
    // optional dot-separated ASCII prerelease/build identifiers. Leading zeros
    // are accepted by Flutter, and the original spelling is preserved.
    let identifiers = |value: &str| {
        value.split('.').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
    };
    let (name, build) = version
        .split_once('+')
        .map_or((version, None), |(name, build)| (name, Some(build)));
    if build.is_some_and(|build| !identifiers(build)) {
        return false;
    }
    let (core, prerelease) = name
        .split_once('-')
        .map_or((name, None), |(core, prerelease)| (core, Some(prerelease)));
    if prerelease.is_some_and(|prerelease| !identifiers(prerelease)) {
        return false;
    }
    let mut parts = core.split('.');
    (0..3).all(|_| {
        parts.next().is_some_and(|part| {
            !part.is_empty()
                && part.bytes().all(|byte| byte.is_ascii_digit())
                && part.parse::<i64>().is_ok()
        })
    }) && parts.next().is_none()
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
        let version = read_build_version(config.project_path.clone(), config.args.clone()).await;
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
            version: version.as_ref().ok().cloned(),
        };
        let (cancel, _) = watch::channel(false);
        let (done, _) = watch::channel(false);
        let mut logs = LogBuffer::new(5000, 2 * 1024 * 1024);
        if let Err(error) = version {
            logs.push(
                "system",
                &format!("Could not read build version: {error:#}"),
            );
        }
        let build = Arc::new(Build {
            snapshot: Mutex::new(snapshot.clone()),
            logs: Mutex::new(logs),
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

    pub async fn list(&self) -> Vec<BuildSnapshot> {
        let builds: Vec<_> = self.builds.lock().await.values().cloned().collect();
        let mut snapshots = Vec::with_capacity(builds.len());
        for build in builds {
            snapshots.push(build.snapshot.lock().await.clone());
        }
        snapshots.sort_unstable_by_key(|snapshot| {
            std::cmp::Reverse(
                snapshot
                    .id
                    .strip_prefix("build-")
                    .and_then(|id| id.parse::<u64>().ok())
                    .unwrap_or(0),
            )
        });
        snapshots
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

    #[tokio::test]
    async fn build_version_reads_yaml_quotes_optional_number_and_missing_fields() {
        let fixture = tempfile::tempdir().unwrap();
        for (manifest, build_name, build_number) in [
            (
                "name: fixture\nversion: 1.2.3+42\n",
                Some("1.2.3"),
                Some("42"),
            ),
            (
                "version: '2.3.4-beta+007'\n",
                Some("2.3.4-beta"),
                Some("007"),
            ),
            ("version: \"3.4.5+12\"\n", Some("3.4.5"), Some("12")),
            ("version: 4.5.6\n", Some("4.5.6"), None),
            (
                "version: 01.02.03-dev.01+build.007\n",
                Some("01.02.03-dev.01"),
                Some("build.007"),
            ),
            ("name: fixture\n", None, None),
            ("version: null\n", None, None),
            ("version: invalid+42\n", None, None),
            ("version: 1.2.3+4+5\n", None, None),
            ("version: 1.2.3-dev..1+42\n", None, None),
            ("version: 1.2.3+\n", None, None),
            ("version: 1.2\n", None, None),
            ("version: [1, 2, 3]\n", None, None),
            ("version: true\n", None, None),
        ] {
            fs::write(fixture.path().join("pubspec.yaml"), manifest).unwrap();
            let version = read_build_version(fixture.path().to_string_lossy().into_owned(), vec![])
                .await
                .unwrap();
            assert_eq!(
                version,
                BuildVersion {
                    build_name: build_name.map(str::to_owned),
                    build_number: build_number.map(str::to_owned)
                },
                "{manifest}"
            );
        }
    }

    #[test]
    fn build_version_overrides_respect_values_repetition_and_end_of_options() {
        let args = [
            "--release",
            "--build-name=2.0.0",
            "--build-number",
            "8",
            "--build-name",
            "3.0.0",
            "--build-number=9",
            "--dart-define",
            "--build-name=not-a-version",
            "--dart-define=--build-number=99",
            "-D",
            "--build-number=100",
            "--flavor",
            "--build-name=also-not-a-version",
            "--target-sysroot",
            "--build-name=not-the-sysroot",
            "--static-assets-url",
            "--build-number=not-the-assets-url",
            "--optimization-level",
            "--build-name=not-the-optimization-level",
            "-O",
            "--build-number=not-the-short-optimization-level",
            "--",
            "--build-name=4.0.0",
            "--build-number",
            "10",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
        assert_eq!(
            build_version(Some("1.0.0+7"), &args),
            BuildVersion {
                build_name: Some("3.0.0".into()),
                build_number: Some("9".into())
            }
        );
        assert_eq!(
            build_version(None, &["--build-number=42".into()]),
            BuildVersion {
                build_name: None,
                build_number: Some("42".into())
            }
        );
        assert_eq!(
            build_version(Some("1.0.0+7"), &["--build-name=2.0.0".into()]),
            BuildVersion {
                build_name: Some("2.0.0".into()),
                build_number: Some("7".into())
            }
        );
        let args = [
            "--dart-define",
            "--",
            "--build-name=2.0.0",
            "--",
            "--build-number=99",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
        assert_eq!(
            build_version(Some("1.0.0+7"), &args),
            BuildVersion {
                build_name: Some("2.0.0".into()),
                build_number: Some("7".into())
            }
        );
        assert_eq!(
            build_version(
                Some("invalid+42"),
                &[
                    "--build-name=configured-by-cli".into(),
                    "--build-number=43".into()
                ]
            ),
            BuildVersion {
                build_name: Some("configured-by-cli".into()),
                build_number: Some("43".into())
            }
        );
    }

    #[tokio::test]
    async fn build_version_bounds_reads_and_reports_invalid_or_missing_manifests() {
        let fixture = tempfile::tempdir().unwrap();
        let project = fixture.path().to_string_lossy().into_owned();
        assert!(read_build_version(project.clone(), vec![]).await.is_err());
        let pubspec = fixture.path().join("pubspec.yaml");
        for content in ["version: [broken", "- invalid-root"] {
            fs::write(&pubspec, content).unwrap();
            assert!(
                read_build_version(project.clone(), vec![]).await.is_err(),
                "{content}"
            );
        }
        let mut content = String::from("version: 1.2.3+4\n#");
        content.push_str(&"x".repeat(1024 * 1024 - content.len()));
        fs::write(&pubspec, &content).unwrap();
        assert_eq!(
            read_build_version(project.clone(), vec![])
                .await
                .unwrap()
                .build_number
                .as_deref(),
            Some("4")
        );
        content.push('x');
        fs::write(&pubspec, content).unwrap();
        assert!(read_build_version(project, vec![])
            .await
            .unwrap_err()
            .to_string()
            .contains("size limit"));
    }

    #[tokio::test]
    async fn list_preserves_active_and_terminal_snapshots_across_projects_without_reading_logs() {
        let manager = BuildManager::default();
        assert!(manager.list().await.is_empty());
        for (id, project, state, exit_code, error) in [
            (2, "/fixture/project-a", "succeeded", Some(0), None),
            (10, "/fixture/project-b", "running", None, None),
            (
                1,
                "/fixture/project-a",
                "failed",
                Some(7),
                Some("compile error"),
            ),
        ] {
            let snapshot = BuildSnapshot {
                id: format!("build-{id}"),
                project_path: project.into(),
                state: state.into(),
                target: "web".into(),
                output_directory: (state == "succeeded").then(|| "/fixture/output".into()),
                error: error.map(str::to_owned),
                exit_code,
                version: None,
            };
            let (cancel, _) = watch::channel(false);
            let (done, _) = watch::channel(state != "running");
            manager.builds.lock().await.insert(
                snapshot.id.clone(),
                Arc::new(Build {
                    snapshot: Mutex::new(snapshot),
                    logs: Mutex::new(LogBuffer::new(10, 1024)),
                    artifact: Mutex::new(None),
                    cancel,
                    done,
                    opener: Arc::new(|_| panic!("Listing builds must not open output")),
                }),
            );
        }
        let active = manager.get("build-10").await.unwrap();
        // Holding the log lock proves listing only accesses authoritative snapshots.
        let _logs = active.logs.lock().await;
        let snapshots = tokio::time::timeout(Duration::from_secs(1), manager.list())
            .await
            .unwrap();
        assert_eq!(
            snapshots
                .iter()
                .map(|snapshot| snapshot.id.as_str())
                .collect::<Vec<_>>(),
            vec!["build-10", "build-2", "build-1"]
        );
        assert_eq!(snapshots[0].project_path, "/fixture/project-b");
        assert_eq!(snapshots[0].state, "running");
        assert_eq!(snapshots[1].project_path, "/fixture/project-a");
        assert_eq!(snapshots[1].state, "succeeded");
        assert_eq!(
            snapshots[1].output_directory.as_deref(),
            Some("/fixture/output")
        );
        assert_eq!(snapshots[1].exit_code, Some(0));
        assert_eq!(snapshots[2].state, "failed");
        assert_eq!(snapshots[2].exit_code, Some(7));
        assert_eq!(snapshots[2].error.as_deref(), Some("compile error"));
        assert!(!*active.cancel.borrow());
        assert!(!*active.done.borrow());
        assert_eq!(manager.snapshot("build-10").await.unwrap().state, "running");
    }

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
    async fn build_version_snapshot_is_frozen_at_start_after_pubspec_changes() {
        let (_fixture, project, sdk) = fixture();
        fs::write(
            project.join("pubspec.yaml"),
            "name: fixture\nversion: 1.2.3+42\n",
        )
        .unwrap();
        let manager = manager(Arc::new(|_| Ok(())));
        let mut configuration = config(&project, Some(&sdk));
        configuration
            .args
            .extend(["--slow".into(), "--build-number=43".into()]);
        let started = manager.start(configuration).await.unwrap();
        let expected = Some(BuildVersion {
            build_name: Some("1.2.3".into()),
            build_number: Some("43".into()),
        });
        assert_eq!(started.version, expected);
        fs::write(
            project.join("pubspec.yaml"),
            "name: fixture\nversion: 9.8.7+99\n",
        )
        .unwrap();
        let preview = read_build_version(project.to_string_lossy().into_owned(), vec![])
            .await
            .unwrap();
        assert_eq!(preview.build_name.as_deref(), Some("9.8.7"));
        assert_eq!(
            manager.snapshot(&started.id).await.unwrap().version,
            expected
        );
        assert_eq!(manager.list().await[0].version, expected);
        manager.stop(&started.id).await.unwrap();
        assert_eq!(
            manager.snapshot(&started.id).await.unwrap().version,
            expected
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn build_version_read_errors_warn_without_blocking_flutter_build() {
        let (_fixture, project, sdk) = fixture();
        fs::write(project.join("pubspec.yaml"), "version: [invalid yaml").unwrap();
        let manager = manager(Arc::new(|_| Ok(())));
        let started = manager.start(config(&project, Some(&sdk))).await.unwrap();
        assert!(started.version.is_none());
        let finished = finish(&manager, &started.id).await;
        assert_eq!(finished.state, "succeeded");
        assert!(finished.version.is_none());
        assert!(manager
            .logs(&started.id, 0, 100)
            .await
            .unwrap()
            .entries
            .iter()
            .any(|entry| entry.category == "system"
                && entry.text.contains("Could not read build version")));
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
