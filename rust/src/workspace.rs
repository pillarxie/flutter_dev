use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs,
    io::Read,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunProfile {
    pub id: String,
    pub name: String,
    pub project_path: String,
    pub sdk_path: Option<String>,
    pub device_id: Option<String>,
    pub platform: Option<String>,
    pub entrypoint: String,
    pub mode: String,
    pub flavor: Option<String>,
    pub dart_defines: Vec<String>,
    pub environment: Vec<crate::session::EnvVar>,
    #[serde(default)]
    pub environment_text: Option<String>,
    #[serde(default)]
    pub tool_args_text: Option<String>,
    pub tool_args: Vec<String>,
    pub attach_uri: Option<String>,
    pub no_debug: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectRunState {
    pub project_path: String,
    pub draft: Option<RunProfile>,
    pub last_run: Option<RunProfile>,
    pub selected_profile_id: Option<String>,
    pub auto_reload: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct WorkspacePreferences {
    pub run_profiles: Vec<RunProfile>,
    pub project_states: Vec<ProjectRunState>,
    pub editor_executable: String,
    pub editor_arguments: Vec<String>,
}

impl Default for WorkspacePreferences {
    fn default() -> Self {
        Self {
            run_profiles: vec![],
            project_states: vec![],
            editor_executable: "code".into(),
            editor_arguments: vec!["--goto".into(), "{file}:{line}:{column}".into()],
        }
    }
}

fn text(value: &str, max: usize) -> bool {
    value.len() <= max && !value.contains('\0')
}
fn absolute(value: &str) -> bool {
    !value.trim().is_empty() && text(value, 16384) && Path::new(value).is_absolute()
}
fn strings(values: &[String]) -> bool {
    values.len() <= 256 && values.iter().all(|value| text(value, 16384))
}

fn validate_profile(profile: &RunProfile, named: bool) -> Result<()> {
    anyhow::ensure!(
        text(&profile.id, 256)
            && text(&profile.name, 256)
            && (!named || (!profile.id.trim().is_empty() && !profile.name.trim().is_empty())),
        "Run profile requires a bounded ID and name"
    );
    anyhow::ensure!(
        absolute(&profile.project_path),
        "Run profile project must be an absolute path"
    );
    anyhow::ensure!(
        (!named || !profile.entrypoint.trim().is_empty()) && text(&profile.entrypoint, 16384),
        "Run profile entrypoint is invalid"
    );
    anyhow::ensure!(
        matches!(profile.mode.as_str(), "debug" | "profile" | "release"),
        "Unknown run mode"
    );
    anyhow::ensure!(
        profile.sdk_path.as_deref().is_none_or(|path| if named {
            absolute(path)
        } else {
            text(path, 16384)
        }),
        "SDK path must be absolute"
    );
    for value in [
        &profile.device_id,
        &profile.platform,
        &profile.flavor,
        &profile.attach_uri,
        &profile.environment_text,
        &profile.tool_args_text,
    ]
    .into_iter()
    .flatten()
    {
        anyhow::ensure!(
            text(value, 16384),
            "Run profile value exceeds limits or contains null characters"
        );
    }
    anyhow::ensure!(
        strings(&profile.dart_defines)
            && strings(&profile.tool_args)
            && profile.environment.len() <= 256,
        "Run profile arguments exceed limits"
    );
    let mut names = HashSet::new();
    for variable in &profile.environment {
        anyhow::ensure!(
            !variable.name.is_empty()
                && text(&variable.name, 256)
                && !variable.name.contains('=')
                && text(&variable.value, 16384)
                && names.insert(&variable.name),
            "Invalid or duplicate environment variable"
        );
    }
    Ok(())
}

pub(crate) fn validate(preferences: &WorkspacePreferences) -> Result<()> {
    anyhow::ensure!(
        preferences.run_profiles.len() <= 500 && preferences.project_states.len() <= 500,
        "Workspace preferences exceed 500 profiles or projects"
    );
    anyhow::ensure!(
        !preferences.editor_executable.trim().is_empty()
            && text(&preferences.editor_executable, 16384)
            && strings(&preferences.editor_arguments),
        "Invalid editor executable or arguments"
    );
    let mut ids = HashSet::new();
    for profile in &preferences.run_profiles {
        validate_profile(profile, true)?;
        anyhow::ensure!(ids.insert(&profile.id), "Duplicate run profile ID");
    }
    let mut projects = HashSet::new();
    for state in &preferences.project_states {
        anyhow::ensure!(
            absolute(&state.project_path) && projects.insert(&state.project_path),
            "Invalid or duplicate project state path"
        );
        for profile in [&state.draft, &state.last_run].into_iter().flatten() {
            validate_profile(profile, false)?;
            anyhow::ensure!(
                profile.project_path == state.project_path,
                "Project draft belongs to another project"
            );
        }
        if let Some(id) = &state.selected_profile_id {
            anyhow::ensure!(
                preferences
                    .run_profiles
                    .iter()
                    .any(|profile| profile.id == *id && profile.project_path == state.project_path),
                "Selected run profile must belong to the project"
            );
        }
    }
    Ok(())
}

fn read_bounded(path: &Path) -> Result<Vec<u8>> {
    let mut content = Vec::new();
    fs::File::open(path)?
        .take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut content)?;
    anyhow::ensure!(
        content.len() <= 4 * 1024 * 1024,
        "Source or package configuration exceeds size limit"
    );
    Ok(content)
}

fn decode_uri(value: &str) -> Result<String> {
    let mut decoded = Vec::with_capacity(value.len());
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = value
                .get(index + 1..index + 3)
                .context("Invalid percent escape in source URI")?;
            decoded
                .push(u8::from_str_radix(hex, 16).context("Invalid percent escape in source URI")?);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).context("Source URI is not UTF-8")
}

fn uri_path(value: &str, base: &Path) -> Result<PathBuf> {
    if let Some(value) = value.strip_prefix("file://") {
        let value = value
            .strip_prefix("localhost/")
            .map_or_else(|| value.to_owned(), |value| format!("/{value}"));
        anyhow::ensure!(
            value.starts_with('/') || cfg!(windows),
            "Remote file URI is unsupported"
        );
        let decoded = decode_uri(&value)?;
        #[cfg(windows)]
        let decoded = decoded
            .strip_prefix('/')
            .filter(|v| v.as_bytes().get(1) == Some(&b':'))
            .unwrap_or(&decoded)
            .to_owned();
        return Ok(PathBuf::from(decoded));
    }
    let value = PathBuf::from(decode_uri(value)?);
    Ok(if value.is_absolute() {
        value
    } else {
        base.join(value)
    })
}

fn source_path(project: &Path, source: &str) -> Result<PathBuf> {
    if let Some(package) = source.strip_prefix("package:") {
        let (name, relative) = package
            .split_once('/')
            .context("Package source requires a file path")?;
        let config_path = project.join(".dart_tool/package_config.json");
        let config: serde_json::Value = serde_json::from_slice(&read_bounded(&config_path)?)?;
        let packages = config["packages"]
            .as_array()
            .context("Invalid package configuration")?;
        anyhow::ensure!(
            packages.len() <= 5000,
            "Package configuration exceeds package limit"
        );
        let package = packages
            .iter()
            .find(|package| package["name"].as_str() == Some(name))
            .context("Package is absent from package configuration")?;
        let root = uri_path(
            package["rootUri"]
                .as_str()
                .context("Package root URI missing")?,
            config_path.parent().unwrap(),
        )?;
        let lib = uri_path(package["packageUri"].as_str().unwrap_or("lib/"), &root)?;
        let source = uri_path(relative, &lib)?
            .canonicalize()
            .context("Source file does not exist")?;
        anyhow::ensure!(
            source.starts_with(lib.canonicalize()?),
            "Package source escapes its package directory"
        );
        return Ok(source);
    }
    let path = if source.starts_with("file://") {
        uri_path(source, project)?
    } else {
        let path = PathBuf::from(source);
        if path.is_absolute() {
            path
        } else {
            project.join(path)
        }
    };
    path.canonicalize().context("Source file does not exist")
}

pub(crate) fn editor_command(
    preferences: &WorkspacePreferences,
    project: &Path,
    source: &str,
    line: u32,
    column: u32,
) -> Result<(PathBuf, Vec<String>)> {
    validate(preferences)?;
    anyhow::ensure!(
        text(source, 16384) && line > 0 && column > 0,
        "Invalid source location"
    );
    let path = source_path(project, source)?;
    anyhow::ensure!(path.is_file(), "Source location is not a file");
    let content = String::from_utf8(read_bounded(&path)?).context("Source file is not UTF-8")?;
    let source_line = content
        .split('\n')
        .nth((line - 1) as usize)
        .context("Source line is outside the file")?;
    anyhow::ensure!(
        column as usize <= source_line.encode_utf16().count() + 1,
        "Source column is outside the line"
    );
    let file = path.to_string_lossy();
    let line = line.to_string();
    let column = column.to_string();
    let project = project.to_string_lossy();
    let substitutions = [
        ("{file}", file.as_ref()),
        ("{line}", line.as_str()),
        ("{column}", column.as_str()),
        ("{project}", project.as_ref()),
    ];
    let args = preferences
        .editor_arguments
        .iter()
        .map(|argument| {
            let mut result = String::new();
            let mut remaining = argument.as_str();
            while let Some(index) = remaining.find('{') {
                result.push_str(&remaining[..index]);
                remaining = &remaining[index..];
                if let Some((token, value)) = substitutions
                    .iter()
                    .find(|(token, _)| remaining.starts_with(token))
                {
                    result.push_str(value);
                    remaining = &remaining[token.len()..];
                } else {
                    result.push('{');
                    remaining = &remaining[1..];
                }
            }
            result.push_str(remaining);
            result
        })
        .collect();
    Ok((PathBuf::from(&preferences.editor_executable), args))
}

pub async fn open_source_location(
    project_path: String,
    path: String,
    line: u32,
    column: u32,
) -> Result<()> {
    let preferences = crate::settings::get_app_settings()
        .await?
        .workspace_preferences;
    let (program, args) = tokio::task::spawn_blocking(move || {
        let project = PathBuf::from(project_path)
            .canonicalize()
            .context("Project folder does not exist")?;
        editor_command(&preferences, &project, &path, line, column)
    })
    .await??;
    crate::process::launch_editor(&program, &args).await
}

#[cfg(test)]
mod tests {
    use super::*;
    fn profile(project: &Path) -> RunProfile {
        RunProfile {
            id: "development".into(),
            name: "Development".into(),
            project_path: project.to_string_lossy().into_owned(),
            sdk_path: None,
            device_id: None,
            platform: None,
            entrypoint: "lib/main.dart".into(),
            mode: "debug".into(),
            flavor: None,
            dart_defines: vec![],
            environment: vec![],
            environment_text: Some("half edited invalid".into()),
            tool_args_text: Some("\"half edited".into()),
            tool_args: vec![],
            attach_uri: None,
            no_debug: false,
        }
    }
    #[test]
    fn validates_profiles_associations_and_allows_unparsed_draft_text() {
        let project = tempfile::tempdir().unwrap();
        let mut preferences = WorkspacePreferences {
            run_profiles: vec![profile(project.path())],
            project_states: vec![ProjectRunState {
                project_path: project.path().to_string_lossy().into_owned(),
                draft: Some(profile(project.path())),
                last_run: None,
                selected_profile_id: Some("development".into()),
                auto_reload: true,
            }],
            ..Default::default()
        };
        validate(&preferences).unwrap();
        preferences.run_profiles.push(profile(project.path()));
        assert!(validate(&preferences).is_err());
        preferences.run_profiles.pop();
        preferences.project_states[0].selected_profile_id = Some("missing".into());
        assert!(validate(&preferences).is_err());
        preferences.project_states[0].selected_profile_id = None;
        preferences.project_states[0]
            .draft
            .as_mut()
            .unwrap()
            .project_path = project.path().join("other").to_string_lossy().into_owned();
        assert!(validate(&preferences).is_err());
        preferences.project_states[0].draft = None;
        preferences.run_profiles[0]
            .environment
            .push(crate::session::EnvVar {
                name: "BAD=NAME".into(),
                value: "value".into(),
            });
        assert!(validate(&preferences).is_err());
        preferences.run_profiles[0].environment.clear();
        preferences.run_profiles[0].tool_args_text = Some("\0".into());
        assert!(validate(&preferences).is_err());
    }
    #[test]
    fn incomplete_draft_entrypoint_and_sdk_are_saved_but_named_profiles_are_validated() {
        let project = tempfile::tempdir().unwrap();
        let mut draft = profile(project.path());
        draft.entrypoint.clear();
        draft.sdk_path = Some("~/partially entered sdk".into());
        let mut preferences = WorkspacePreferences {
            project_states: vec![ProjectRunState {
                project_path: project.path().to_string_lossy().into_owned(),
                draft: Some(draft.clone()),
                last_run: None,
                selected_profile_id: None,
                auto_reload: false,
            }],
            ..Default::default()
        };
        validate(&preferences).unwrap();
        preferences.run_profiles.push(draft);
        assert!(validate(&preferences).is_err());
        preferences.run_profiles.clear();
        preferences.project_states[0]
            .draft
            .as_mut()
            .unwrap()
            .entrypoint = "\0".into();
        assert!(validate(&preferences).is_err());
    }

    #[test]
    fn editor_arguments_preserve_spaces_and_shell_characters_as_literal_values() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("a $(literal) {line} file.dart");
        fs::write(&file, "void main() {}\n").unwrap();
        let preferences = WorkspacePreferences::default();
        let (executable, args) = editor_command(
            &preferences,
            root.path(),
            "a $(literal) {line} file.dart",
            1,
            6,
        )
        .unwrap();
        assert_eq!(executable, PathBuf::from("code"));
        assert_eq!(
            args,
            vec![
                "--goto".to_owned(),
                format!("{}:1:6", file.canonicalize().unwrap().display())
            ]
        );
        assert!(editor_command(
            &preferences,
            root.path(),
            "a $(literal) {line} file.dart",
            2,
            2
        )
        .is_err());
        assert!(editor_command(
            &preferences,
            root.path(),
            "a $(literal) {line} file.dart",
            0,
            1
        )
        .is_err());
    }
    #[test]
    fn plain_source_paths_preserve_literal_percent_and_uri_like_characters() {
        let root = tempfile::tempdir().unwrap();
        for name in ["100%.dart", "literal%20space.dart", "actual space.dart"] {
            let path = root.path().join(name);
            fs::write(&path, "void main() {}\n").unwrap();
            assert_eq!(
                source_path(root.path(), name).unwrap(),
                path.canonicalize().unwrap()
            );
            assert_eq!(
                source_path(root.path(), path.to_str().unwrap()).unwrap(),
                path.canonicalize().unwrap()
            );
        }
        fs::write(root.path().join("unicode.dart"), "😀").unwrap();
        assert!(editor_command(
            &WorkspacePreferences::default(),
            root.path(),
            "unicode.dart",
            1,
            3
        )
        .is_ok());
    }
    #[test]
    fn resolves_file_and_package_uris_from_actual_configuration() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir_all(root.path().join(".dart_tool")).unwrap();
        fs::create_dir_all(root.path().join("dependency/lib")).unwrap();
        let file = root.path().join("dependency/lib/a file.dart");
        fs::write(&file, "source\n").unwrap();
        fs::write(
            root.path().join(".dart_tool/package_config.json"),
            r#"{"packages":[{"name":"dependency","rootUri":"../dependency","packageUri":"lib/"}]}"#,
        )
        .unwrap();
        assert_eq!(
            source_path(root.path(), "package:dependency/a%20file.dart").unwrap(),
            file.canonicalize().unwrap()
        );
        assert_eq!(
            source_path(
                root.path(),
                &format!("file://{}", file.to_string_lossy().replace(' ', "%20"))
            )
            .unwrap(),
            file.canonicalize().unwrap()
        );
        fs::write(root.path().join("dependency/outside.dart"), "source").unwrap();
        assert!(source_path(root.path(), "package:dependency/../outside.dart").is_err());
        assert!(source_path(root.path(), "package:missing/file.dart").is_err());
    }
}
