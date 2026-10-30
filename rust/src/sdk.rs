use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::io::AsyncReadExt;

use crate::process::{flutter_program, OwnedProcess};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SdkInfo {
    pub path: String,
    pub flutter_version: String,
    pub dart_version: String,
    pub source: String,
    pub fallback_reason: Option<String>,
}

pub async fn resolve_sdk(
    project_path: Option<String>,
    explicit_path: Option<String>,
) -> Result<SdkInfo> {
    resolve_sdk_with_settings_path(project_path, explicit_path, None).await
}

async fn resolve_sdk_with_settings_path(
    project_path: Option<String>,
    explicit_path: Option<String>,
    settings_path: Option<PathBuf>,
) -> Result<SdkInfo> {
    let selected = tokio::task::spawn_blocking(move || {
        project_sdk_candidate(project_path.as_deref(), explicit_path.as_deref())
    })
    .await?;
    let failure = match selected {
        Ok(Some((path, source))) => match validate_sdk(&path, &source).await {
            Ok(sdk) => return Ok(sdk),
            Err(error) => Some(format!(
                "Selected {source} Flutter SDK {}: {error:#}",
                path.display()
            )),
        },
        Ok(None) => None,
        Err(error) => Some(format!("Project SDK configuration: {error:#}")),
    };
    // Read the default only after checking the project: corrupt app settings must
    // not prevent a healthy project SDK from running.
    let settings = match settings_path {
        Some(path) => {
            tokio::task::spawn_blocking(move || crate::settings::read_settings(&path)).await?
        }
        None => crate::settings::get_app_settings().await,
    }
    .with_context(|| match &failure {
        Some(reason) => format!("{reason}; global SDK settings are unavailable"),
        None => "Global SDK settings are unavailable".into(),
    })?;
    if let Some(path) = settings
        .default_sdk_path
        .filter(|path| !path.trim().is_empty())
    {
        let source = if failure.is_some() {
            "globalFallback"
        } else {
            "global"
        };
        let mut sdk = validate_default_sdk(path)
            .await
            .with_context(|| match &failure {
                Some(reason) => format!("{reason}; global default Flutter SDK is also unusable"),
                None => "Global default Flutter SDK is unusable".into(),
            })?;
        sdk.source = source.into();
        sdk.fallback_reason = failure;
        return Ok(sdk);
    }
    if let Some(reason) = failure {
        bail!("{reason}");
    }
    let candidates = tokio::task::spawn_blocking(auto_sdk_candidates).await??;
    let mut failures = Vec::new();
    for (path, source) in candidates {
        match validate_sdk(&path, &source).await {
            Ok(sdk) => return Ok(sdk),
            Err(error) => failures.push(format!("{}: {error:#}", path.display())),
        }
    }
    bail!(
        "No usable Flutter SDK found. Select an SDK folder explicitly. {}",
        failures.join("; ")
    )
}

/// Strict validation for settings: saving a default never invokes fallback.
pub(crate) async fn validate_default_sdk(path: String) -> Result<SdkInfo> {
    let path = tokio::task::spawn_blocking(move || expand_path(&path, None)).await??;
    validate_sdk(&path, "global").await
}

#[cfg(test)]
fn sdk_candidates(
    project_path: Option<&str>,
    explicit_path: Option<&str>,
) -> Result<Vec<(PathBuf, String)>> {
    match project_sdk_candidate(project_path, explicit_path)? {
        Some(candidate) => Ok(vec![candidate]),
        None => auto_sdk_candidates(),
    }
}

fn project_sdk_candidate(
    project_path: Option<&str>,
    explicit_path: Option<&str>,
) -> Result<Option<(PathBuf, String)>> {
    let project = project_path.map(|path| {
        let path = PathBuf::from(path);
        path.canonicalize().unwrap_or(path)
    });
    if let Some(path) = explicit_path.filter(|path| !path.trim().is_empty()) {
        return Ok(Some((
            expand_path(path, project.as_deref())?,
            "explicit".into(),
        )));
    }
    if let Some(project) = project.as_deref() {
        // FVM is often configured at a monorepo root while the runnable package lives
        // below apps/. Prefer the closest inherited SDK over the terminal's global SDK.
        let home = std::env::var_os("HOME")
            .or_else(|| std::env::var_os("USERPROFILE"))
            .map(PathBuf::from)
            .map(|path| path.canonicalize().unwrap_or(path));
        for ancestor in project.ancestors().take(13) {
            let fvm = ancestor.join(".fvm/flutter_sdk");
            match fs::symlink_metadata(&fvm) {
                Ok(_) => return Ok(Some((fvm, "fvm".into()))),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(error).with_context(|| format!("Read FVM SDK {}", fvm.display()))
                }
            }
            if home.as_deref() == Some(ancestor) {
                break;
            }
        }
        let settings_path = project.join(".vscode/settings.json");
        let metadata = match fs::metadata(&settings_path) {
            Ok(metadata) => Some(metadata),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(error).context("Read .vscode/settings.json"),
        };
        if let Some(metadata) = metadata {
            if metadata.len() > 1024 * 1024 {
                bail!("SDK settings file exceeds size limit");
            }
            let settings = fs::read_to_string(&settings_path)?;
            if settings.len() > 1024 * 1024 {
                bail!("SDK settings file exceeds size limit");
            }
            let settings: serde_json::Value =
                serde_json::from_str(&strip_json_comments(&settings)?)
                    .context("Invalid .vscode/settings.json")?;
            let settings = settings
                .as_object()
                .context("Invalid .vscode/settings.json: expected a settings object")?;
            if let Some(path) = settings.get("dart.flutterSdkPath") {
                let path = path
                    .as_str()
                    .context("Invalid dart.flutterSdkPath: expected a string")?;
                return Ok(Some((expand_path(path, Some(project))?, "vscode".into())));
            }
        }
    }
    Ok(None)
}

fn auto_sdk_candidates() -> Result<Vec<(PathBuf, String)>> {
    let mut roots = Vec::new();
    if let Some(path) = std::env::var_os("PATH") {
        for folder in std::env::split_paths(&path) {
            let flutter = folder.join(if cfg!(windows) {
                "flutter.bat"
            } else {
                "flutter"
            });
            if let Ok(executable) = flutter.canonicalize() {
                if let Some(root) = executable.parent().and_then(Path::parent) {
                    roots.push(root.to_path_buf());
                }
            }
        }
    }
    if let Some(home) = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")) {
        let home = PathBuf::from(home);
        for folder in [
            "Flutter/flutter",
            "flutter",
            "development/flutter",
            "sdks/flutter",
            ".local/share/flutter",
            "fvm/default",
        ] {
            roots.push(home.join(folder));
        }
    }
    if cfg!(windows) {
        roots.push(PathBuf::from("C:\\src\\flutter"));
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            roots.push(PathBuf::from(local).join("flutter"));
        }
    } else {
        roots.extend([
            PathBuf::from("/opt/flutter"),
            PathBuf::from("/usr/local/flutter"),
        ]);
    }
    let mut unique = Vec::new();
    for root in roots {
        if let Ok(root) = root.canonicalize() {
            if !unique.contains(&root)
                && root
                    .join("bin")
                    .join(if cfg!(windows) {
                        "flutter.bat"
                    } else {
                        "flutter"
                    })
                    .is_file()
            {
                unique.push(root);
            }
        }
    }
    Ok(unique
        .into_iter()
        .map(|root| (root, "auto".into()))
        .collect())
}

async fn validate_sdk(path: &Path, source: &str) -> Result<SdkInfo> {
    let canonical = tokio::fs::canonicalize(path)
        .await
        .context("Flutter SDK folder does not exist")?;
    let mut sdk = SdkInfo {
        path: canonical.to_string_lossy().into_owned(),
        flutter_version: String::new(),
        dart_version: String::new(),
        source: source.into(),
        fallback_reason: None,
    };
    let executable = flutter_program(&sdk);
    if !tokio::fs::try_exists(&executable).await? {
        bail!("SDK has no {}", executable.display());
    }
    let mut process = OwnedProcess::spawn(
        &executable,
        &["--version".into(), "--machine".into()],
        None,
        &HashMap::new(),
    )?;
    let mut stdout = process
        .stdout
        .take()
        .context("SDK stdout unavailable")?
        .take(1024 * 1024 + 1);
    let mut stderr = process
        .stderr
        .take()
        .context("SDK stderr unavailable")?
        .take(1024 * 1024 + 1);
    let mut out = Vec::new();
    let mut err = Vec::new();
    let operation = async {
        let (_, _, status) = tokio::try_join!(
            async {
                stdout
                    .read_to_end(&mut out)
                    .await
                    .context("Read SDK stdout")
            },
            async {
                stderr
                    .read_to_end(&mut err)
                    .await
                    .context("Read SDK stderr")
            },
            process.wait()
        )?;
        Ok::<_, anyhow::Error>(status)
    };
    let status = match tokio::time::timeout(Duration::from_secs(60), operation).await {
        Ok(result) => result?,
        Err(_) => {
            process.terminate(Duration::from_secs(2)).await?;
            bail!("Flutter SDK version probe timed out");
        }
    };
    if out.len() > 1024 * 1024 || err.len() > 1024 * 1024 {
        bail!("Flutter SDK version output exceeds limit");
    }
    if !status.success() {
        bail!(
            "Flutter SDK version probe failed: {}",
            String::from_utf8_lossy(&err)
        );
    }
    // SDK startup diagnostics may precede the machine-readable object.
    let start = out
        .iter()
        .position(|byte| *byte == b'{')
        .context("SDK returned no version JSON")?;
    let version: serde_json::Value =
        serde_json::from_slice(&out[start..]).context("Invalid SDK version response")?;
    sdk.flutter_version = version
        .get("frameworkVersion")
        .and_then(serde_json::Value::as_str)
        .context("SDK response missing Flutter version")?
        .into();
    sdk.dart_version = version
        .get("dartSdkVersion")
        .and_then(serde_json::Value::as_str)
        .context("SDK response missing Dart version")?
        .into();
    Ok(sdk)
}

fn expand_path(value: &str, project: Option<&Path>) -> Result<PathBuf> {
    let mut value = value.to_owned();
    if value.starts_with('~')
        && (value.len() == 1 || value.as_bytes()[1] == b'/' || value.as_bytes()[1] == b'\\')
    {
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .context("Home folder is unavailable")?;
        value.replace_range(..1, &home);
    }
    if value.contains("${workspaceFolder}") {
        let folder = project
            .context("workspaceFolder requires a project")?
            .to_string_lossy();
        value = value.replace("${workspaceFolder}", &folder);
    }
    while let Some(start) = value.find("${env:") {
        let end = value[start..]
            .find('}')
            .context("Unclosed environment variable in SDK path")?
            + start;
        let name = &value[start + 6..end];
        let replacement = std::env::var(name)
            .with_context(|| format!("SDK path environment variable {name} is unavailable"))?;
        value.replace_range(start..=end, &replacement);
    }
    if value.contains("${") {
        bail!("Unsupported variable in SDK path");
    }
    // Placeholder values may contain a canonical Windows verbatim prefix.
    // Unlike ordinary Win32 paths, that namespace does not translate '/'.
    #[cfg(windows)]
    let value = value.replace('/', "\\");
    let path = PathBuf::from(value);
    Ok(if path.is_relative() {
        project.unwrap_or(Path::new(".")).join(path)
    } else {
        path
    })
}

/// Small JSONC reader for imported SDK settings; preserves quoted URLs and escape sequences.
fn strip_json_comments(input: &str) -> Result<String> {
    let bytes = input.as_bytes();
    let mut clean = bytes.to_vec();
    let (mut i, mut quoted) = (0, false);
    while i < bytes.len() {
        if quoted {
            if bytes[i] == b'\\' {
                i += 2;
                continue;
            }
            if bytes[i] == b'"' {
                quoted = false;
            }
        } else if bytes[i] == b'"' {
            quoted = true;
        } else if bytes[i..].starts_with(b"//") {
            while i < bytes.len() && bytes[i] != b'\n' {
                clean[i] = b' ';
                i += 1;
            }
            continue;
        } else if bytes[i..].starts_with(b"/*") {
            let start = i;
            i += 2;
            while i + 1 < bytes.len() && !bytes[i..].starts_with(b"*/") {
                i += 1;
            }
            if i + 1 >= bytes.len() {
                bail!("Unterminated JSON settings comment");
            }
            i += 2;
            for byte in &mut clean[start..i] {
                if *byte != b'\n' {
                    *byte = b' ';
                }
            }
            continue;
        }
        i += 1;
    }
    // VS Code settings also accept trailing commas.
    let (mut i, mut quoted) = (0, false);
    while i < clean.len() {
        if quoted {
            if clean[i] == b'\\' {
                i += 2;
                continue;
            }
            if clean[i] == b'"' {
                quoted = false;
            }
        } else if clean[i] == b'"' {
            quoted = true;
        } else if clean[i] == b',' {
            let next = clean[i + 1..]
                .iter()
                .copied()
                .find(|byte| !byte.is_ascii_whitespace());
            if next.is_some_and(|byte| byte == b'}' || byte == b']') {
                clean[i] = b' ';
            }
        }
        i += 1;
    }
    Ok(String::from_utf8(clean)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_placeholder_sdk_paths_resolve_to_existing_directories() {
        let fixture = tempfile::tempdir().unwrap();
        let root = fixture.path().canonicalize().unwrap();
        let sdk = root.join("SDK 中文");
        fs::create_dir(&sdk).unwrap();
        let expanded = expand_path("${workspaceFolder}/SDK 中文", Some(&root)).unwrap();
        assert_eq!(expanded, sdk);
        assert_eq!(
            expanded.canonicalize().unwrap(),
            sdk.canonicalize().unwrap()
        );
    }

    #[test]
    fn package_inherits_nearest_monorepo_fvm_before_global_sdk() {
        let fixture = tempfile::tempdir().unwrap();
        let root = fixture.path().canonicalize().unwrap();
        let package = root.join("apps/app");
        fs::create_dir_all(&package).unwrap();
        fs::create_dir_all(root.join(".fvm/flutter_sdk")).unwrap();
        let inherited = sdk_candidates(package.to_str(), None).unwrap().remove(0);
        assert_eq!(inherited.0, root.join(".fvm/flutter_sdk"));
        assert_eq!(inherited.1, "fvm");
        fs::create_dir_all(package.join(".fvm/flutter_sdk")).unwrap();
        let nearest = sdk_candidates(package.to_str(), None).unwrap().remove(0);
        assert_eq!(nearest.0, package.join(".fvm/flutter_sdk"));
        let explicit = sdk_candidates(package.to_str(), Some("selected-sdk"))
            .unwrap()
            .remove(0);
        assert_eq!(explicit.0, package.join("selected-sdk"));
        assert_eq!(explicit.1, "explicit");
    }

    #[test]
    fn explicit_fvm_settings_precedence_and_jsonc() {
        let root =
            std::env::temp_dir().join(format!("flutter-dev-sdk-selection-{}", std::process::id()));
        fs::create_dir_all(root.join(".fvm/flutter_sdk")).unwrap();
        fs::create_dir_all(root.join(".vscode")).unwrap();
        let root = root.canonicalize().unwrap();
        fs::write(
            root.join(".vscode/settings.json"),
            "{ // imported\n \"dart.flutterSdkPath\": \"${workspaceFolder}/sdk\", /* ok */\n}",
        )
        .unwrap();
        let project = root.to_str().unwrap();
        assert_eq!(
            sdk_candidates(Some(project), Some("explicit")).unwrap()[0].1,
            "explicit"
        );
        assert_eq!(sdk_candidates(Some(project), None).unwrap()[0].1, "fvm");
        fs::remove_dir_all(root.join(".fvm")).unwrap();
        let candidate = sdk_candidates(Some(project), None).unwrap().remove(0);
        assert_eq!(candidate.1, "vscode");
        assert_eq!(candidate.0, root.join("sdk"));
        fs::remove_dir_all(root).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(
            &strip_json_comments("{\"url\":\"https://test/a/*b*/\",}").unwrap(),
        )
        .unwrap();
        assert_eq!(parsed["url"], "https://test/a/*b*/");
    }

    #[cfg(unix)]
    fn fake_sdk(root: &Path, version: &str, fails: bool) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        fs::create_dir_all(root.join("bin")).unwrap();
        let flutter = root.join("bin/flutter");
        let script = if fails {
            "#!/bin/sh\necho 'broken SDK' >&2\nexit 1\n".into()
        } else {
            format!("#!/bin/sh\nprintf '%s\\n' '{{\"frameworkVersion\":\"{version}\",\"dartSdkVersion\":\"3.dart\"}}'\n")
        };
        fs::write(&flutter, script).unwrap();
        fs::set_permissions(flutter, fs::Permissions::from_mode(0o755)).unwrap();
        root.canonicalize().unwrap()
    }

    #[cfg(unix)]
    fn save_default(path: &Path, sdk: Option<&Path>) {
        fs::write(
            path,
            serde_json::to_vec(&crate::settings::AppSettings {
                default_sdk_path: sdk.map(|sdk| sdk.to_string_lossy().into_owned()),
                ..crate::settings::AppSettings::default()
            })
            .unwrap(),
        )
        .unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn missing_explicit_sdk_falls_back_without_changing_project() {
        let fixture = tempfile::tempdir().unwrap();
        let project = fixture.path().join("project");
        fs::create_dir_all(project.join(".vscode")).unwrap();
        let content = "{\"dart.flutterSdkPath\":\"project-sdk\"}";
        fs::write(project.join(".vscode/settings.json"), content).unwrap();
        let global = fake_sdk(&fixture.path().join("global"), "global-version", false);
        let settings = fixture.path().join("settings.json");
        save_default(&settings, Some(&global));
        let sdk = resolve_sdk_with_settings_path(
            Some(project.to_string_lossy().into_owned()),
            Some("missing-sdk".into()),
            Some(settings),
        )
        .await
        .unwrap();
        assert_eq!(sdk.path, global.to_string_lossy());
        assert_eq!(sdk.source, "globalFallback");
        assert!(sdk.fallback_reason.unwrap().contains("explicit"));
        assert_eq!(
            fs::read_to_string(project.join(".vscode/settings.json")).unwrap(),
            content
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn broken_fvm_and_vscode_config_fall_back_to_global() {
        use std::os::unix::fs::symlink;
        let fixture = tempfile::tempdir().unwrap();
        let project = fixture.path().join("project");
        fs::create_dir_all(project.join(".fvm")).unwrap();
        symlink("missing", project.join(".fvm/flutter_sdk")).unwrap();
        let global = fake_sdk(&fixture.path().join("global"), "global-version", false);
        let settings = fixture.path().join("settings.json");
        save_default(&settings, Some(&global));
        let sdk = resolve_sdk_with_settings_path(
            Some(project.to_string_lossy().into_owned()),
            None,
            Some(settings.clone()),
        )
        .await
        .unwrap();
        assert_eq!(sdk.source, "globalFallback");
        assert!(sdk.fallback_reason.unwrap().contains("fvm"));
        fs::remove_dir_all(project.join(".fvm")).unwrap();
        fs::create_dir_all(project.join(".vscode")).unwrap();
        fs::write(project.join(".vscode/settings.json"), "{/* broken").unwrap();
        let sdk = resolve_sdk_with_settings_path(
            Some(project.to_string_lossy().into_owned()),
            None,
            Some(settings),
        )
        .await
        .unwrap();
        assert_eq!(sdk.source, "globalFallback");
        assert!(sdk.fallback_reason.unwrap().contains("comment"));
        fs::write(
            project.join(".vscode/settings.json"),
            "{\"dart.flutterSdkPath\":42}",
        )
        .unwrap();
        let sdk = resolve_sdk_with_settings_path(
            Some(project.to_string_lossy().into_owned()),
            None,
            Some(fixture.path().join("settings.json")),
        )
        .await
        .unwrap();
        assert_eq!(sdk.source, "globalFallback");
        assert!(sdk.fallback_reason.unwrap().contains("expected a string"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn failing_project_probe_falls_back_but_healthy_project_has_priority() {
        let fixture = tempfile::tempdir().unwrap();
        let explicit = fake_sdk(&fixture.path().join("explicit"), "project-version", false);
        let failing = fake_sdk(&fixture.path().join("failing"), "", true);
        let global = fake_sdk(&fixture.path().join("global"), "global-version", false);
        let settings = fixture.path().join("settings.json");
        save_default(&settings, Some(&global));
        let fallback = resolve_sdk_with_settings_path(
            None,
            Some(failing.to_string_lossy().into_owned()),
            Some(settings.clone()),
        )
        .await
        .unwrap();
        assert_eq!(fallback.flutter_version, "global-version");
        assert!(fallback.fallback_reason.unwrap().contains("broken SDK"));
        let selected = resolve_sdk_with_settings_path(
            None,
            Some(explicit.to_string_lossy().into_owned()),
            Some(settings.clone()),
        )
        .await
        .unwrap();
        assert_eq!(selected.flutter_version, "project-version");
        assert_eq!(selected.source, "explicit");
        assert!(selected.fallback_reason.is_none());
        fs::write(&settings, "{broken").unwrap();
        let selected = resolve_sdk_with_settings_path(
            None,
            Some(explicit.to_string_lossy().into_owned()),
            Some(settings),
        )
        .await
        .unwrap();
        assert_eq!(selected.flutter_version, "project-version");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn global_default_precedes_auto_discovery() {
        let fixture = tempfile::tempdir().unwrap();
        let global = fake_sdk(&fixture.path().join("global"), "global-version", false);
        let settings = fixture.path().join("settings.json");
        save_default(&settings, Some(&global));
        let sdk = resolve_sdk_with_settings_path(None, None, Some(settings))
            .await
            .unwrap();
        assert_eq!(sdk.path, global.to_string_lossy());
        assert_eq!(sdk.source, "global");
        assert!(sdk.fallback_reason.is_none());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn unusable_project_and_global_report_both_failures() {
        let fixture = tempfile::tempdir().unwrap();
        let missing = fixture.path().join("missing-project");
        let global = fake_sdk(&fixture.path().join("global"), "", true);
        let settings = fixture.path().join("settings.json");
        save_default(&settings, Some(&global));
        let error = resolve_sdk_with_settings_path(
            None,
            Some(missing.to_string_lossy().into_owned()),
            Some(settings.clone()),
        )
        .await
        .unwrap_err();
        let message = format!("{error:#}");
        assert!(message.contains("missing-project"));
        assert!(message.contains("global default"));
        assert!(message.contains("broken SDK"));
        save_default(&settings, None);
        let error = resolve_sdk_with_settings_path(
            None,
            Some(missing.to_string_lossy().into_owned()),
            Some(settings),
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("Selected explicit Flutter SDK"));
        assert!(!error.to_string().contains("global"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn reports_actual_executed_sdk_version() {
        use std::os::unix::fs::PermissionsExt;
        let root =
            std::env::temp_dir().join(format!("flutter-dev-sdk-probe-{}", std::process::id()));
        fs::create_dir_all(root.join("bin")).unwrap();
        let flutter = root.join("bin/flutter");
        fs::write(&flutter, "#!/bin/sh\nprintf '%s\\n' '{\"frameworkVersion\":\"3.test\",\"dartSdkVersion\":\"3.dart\"}'\n").unwrap();
        fs::set_permissions(&flutter, fs::Permissions::from_mode(0o755)).unwrap();
        let sdk = resolve_sdk(None, Some(root.to_string_lossy().into_owned()))
            .await
            .unwrap();
        assert_eq!(sdk.flutter_version, "3.test");
        assert_eq!(sdk.dart_version, "3.dart");
        assert_eq!(sdk.source, "explicit");
        fs::remove_dir_all(root).unwrap();
    }
}
