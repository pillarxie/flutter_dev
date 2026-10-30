use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs,
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    sync::OnceLock,
};
use tokio::sync::Mutex;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppSettings {
    pub default_sdk_path: Option<String>,
    #[serde(default = "default_theme_mode")]
    pub theme_mode: String,
    #[serde(default)]
    pub project_build_presets: Vec<ProjectBuildPresets>,
    #[serde(default)]
    pub projects: Vec<crate::project::ProjectInfo>,
    #[serde(default)]
    pub selected_project_path: Option<String>,
    #[serde(default)]
    pub workspace_preferences: crate::workspace::WorkspacePreferences,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectBuildPresets {
    pub project_path: String,
    pub presets: Vec<crate::build::BuildPreset>,
}

const MAX_SETTINGS_BYTES: usize = 1024 * 1024;
const MAX_WORKSPACE_PROJECTS: usize = 500;

fn default_theme_mode() -> String {
    "light".into()
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            default_sdk_path: None,
            theme_mode: default_theme_mode(),
            project_build_presets: vec![],
            projects: vec![],
            selected_project_path: None,
            workspace_preferences: Default::default(),
        }
    }
}

// Serialize validation and persistence so simultaneous settings submissions cannot
// overwrite a newer validated value while its version probe is still running.
static SETTINGS_WRITE: OnceLock<Mutex<()>> = OnceLock::new();

pub async fn get_app_settings() -> Result<AppSettings> {
    tokio::task::spawn_blocking(|| read_settings(&settings_path()?)).await?
}

pub async fn set_default_sdk(path: Option<String>) -> Result<AppSettings> {
    let _guard = SETTINGS_WRITE.get_or_init(|| Mutex::new(())).lock().await;
    let destination = tokio::task::spawn_blocking(settings_path).await??;
    set_default_sdk_at(destination, path).await
}

pub async fn set_theme_mode(mode: String) -> Result<AppSettings> {
    let _guard = SETTINGS_WRITE.get_or_init(|| Mutex::new(())).lock().await;
    let destination = tokio::task::spawn_blocking(settings_path).await??;
    tokio::task::spawn_blocking(move || set_theme_mode_at(&destination, mode)).await?
}

pub async fn get_build_presets(project_path: String) -> Result<Vec<crate::build::BuildPreset>> {
    tokio::task::spawn_blocking(move || build_presets_at(&settings_path()?, &project_path)).await?
}

pub async fn set_build_presets(
    project_path: String,
    presets: Vec<crate::build::BuildPreset>,
) -> Result<Vec<crate::build::BuildPreset>> {
    let _guard = SETTINGS_WRITE.get_or_init(|| Mutex::new(())).lock().await;
    let destination = tokio::task::spawn_blocking(settings_path).await??;
    tokio::task::spawn_blocking(move || set_build_presets_at(&destination, &project_path, presets))
        .await?
}

pub async fn set_workspace_projects(
    projects: Vec<crate::project::ProjectInfo>,
    selected_project_path: Option<String>,
) -> Result<AppSettings> {
    let _guard = SETTINGS_WRITE.get_or_init(|| Mutex::new(())).lock().await;
    let destination = tokio::task::spawn_blocking(settings_path).await??;
    tokio::task::spawn_blocking(move || {
        set_workspace_projects_at(&destination, projects, selected_project_path)
    })
    .await?
}

pub async fn set_workspace_preferences(
    preferences: crate::workspace::WorkspacePreferences,
) -> Result<AppSettings> {
    crate::workspace::validate(&preferences)?;
    let _guard = SETTINGS_WRITE.get_or_init(|| Mutex::new(())).lock().await;
    let destination = tokio::task::spawn_blocking(settings_path).await??;
    tokio::task::spawn_blocking(move || set_workspace_preferences_at(&destination, preferences))
        .await?
}

fn set_workspace_preferences_at(
    destination: &Path,
    preferences: crate::workspace::WorkspacePreferences,
) -> Result<AppSettings> {
    crate::workspace::validate(&preferences)?;
    let mut settings = read_settings(destination)?;
    settings.workspace_preferences = preferences;
    write_settings(destination, &settings)?;
    Ok(settings)
}

fn set_workspace_projects_at(
    destination: &Path,
    mut projects: Vec<crate::project::ProjectInfo>,
    selected_project_path: Option<String>,
) -> Result<AppSettings> {
    anyhow::ensure!(
        projects.len() <= MAX_WORKSPACE_PROJECTS,
        "Workspace exceeds 500 projects"
    );
    for project in &projects {
        anyhow::ensure!(
            !project.path.trim().is_empty()
                && !project.path.contains('\0')
                && Path::new(&project.path).is_absolute(),
            "Project path must be a nonempty absolute path"
        );
    }
    let mut paths = HashSet::new();
    projects.retain(|project| paths.insert(project.path.clone()));
    anyhow::ensure!(
        selected_project_path
            .as_ref()
            .is_none_or(|path| paths.contains(path)),
        "Selected project must belong to the workspace"
    );
    let mut settings = read_settings(destination)?;
    settings.projects = projects;
    settings.selected_project_path = selected_project_path;
    write_settings(destination, &settings)?;
    Ok(settings)
}

// Resolve aliases for existing projects while retaining settings for temporarily
// unavailable projects. Resolve through the nearest accessible ancestor where
// possible; a project becoming inaccessible must not disable all settings reads.
fn normalized_project_path(path: &str) -> Result<String> {
    anyhow::ensure!(
        !path.trim().is_empty()
            && !path.contains('\0')
            && path.len() <= 16384
            && Path::new(path).is_absolute(),
        "Project path must be a nonempty absolute path"
    );
    let mut ancestor = Path::new(path);
    let mut tail = Vec::new();
    let mut resolved = loop {
        match fs::canonicalize(ancestor) {
            Ok(path) => break path,
            Err(_) => {
                let component = ancestor
                    .components()
                    .next_back()
                    .context("Invalid project path")?;
                tail.push(component.as_os_str().to_owned());
                ancestor = ancestor.parent().context("Invalid project path")?;
            }
        }
    };
    for component in tail.into_iter().rev() {
        resolved.push(component);
    }
    let mut normalized = PathBuf::new();
    for component in resolved.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                anyhow::ensure!(normalized.pop(), "Invalid project path");
            }
            component => normalized.push(component.as_os_str()),
        }
    }
    let path = normalized
        .to_str()
        .context("Project path is not valid UTF-8")?;
    #[cfg(windows)]
    {
        Ok(windows_project_identity(path))
    }
    #[cfg(not(windows))]
    {
        Ok(path.to_owned())
    }
}

#[cfg(any(windows, test))]
fn windows_project_identity(path: &str) -> String {
    let path = path.replace('/', "\\");
    let path = if let Some(path) = path.strip_prefix("\\\\?\\UNC\\") {
        format!("\\\\{path}")
    } else {
        path.strip_prefix("\\\\?\\").unwrap_or(&path).to_owned()
    };
    path.to_lowercase()
}

fn build_presets_at(
    destination: &Path,
    project_path: &str,
) -> Result<Vec<crate::build::BuildPreset>> {
    let project_path = normalized_project_path(project_path)?;
    let settings = read_settings(destination)?;
    Ok(settings
        .project_build_presets
        .into_iter()
        .find(|record| record.project_path == project_path)
        .map_or_else(crate::build::default_build_presets, |record| record.presets))
}

fn set_build_presets_at(
    destination: &Path,
    project_path: &str,
    presets: Vec<crate::build::BuildPreset>,
) -> Result<Vec<crate::build::BuildPreset>> {
    let project_path = normalized_project_path(project_path)?;
    crate::build::validate_presets(&presets)?;
    let mut settings = read_settings(destination)?;
    if let Some(record) = settings
        .project_build_presets
        .iter_mut()
        .find(|record| record.project_path == project_path)
    {
        record.presets = presets.clone();
    } else {
        anyhow::ensure!(
            settings.project_build_presets.len() < MAX_WORKSPACE_PROJECTS,
            "Build preset settings exceed 500 projects"
        );
        settings.project_build_presets.push(ProjectBuildPresets {
            project_path,
            presets: presets.clone(),
        });
    }
    write_settings(destination, &settings)?;
    Ok(presets)
}

fn set_theme_mode_at(destination: &Path, mode: String) -> Result<AppSettings> {
    anyhow::ensure!(
        matches!(mode.as_str(), "light" | "dark"),
        "Unknown theme mode: {mode}"
    );
    // Changing appearance must not replace an unreadable SDK configuration.
    let mut settings = read_settings(destination)?;
    settings.theme_mode = mode;
    write_settings(destination, &settings)?;
    Ok(settings)
}

async fn set_default_sdk_at(destination: PathBuf, path: Option<String>) -> Result<AppSettings> {
    let default_sdk_path = match path.filter(|path| !path.trim().is_empty()) {
        Some(path) => Some(crate::sdk::validate_default_sdk(path).await?.path),
        None => None,
    };
    tokio::task::spawn_blocking(move || {
        // Explicit saves also repair unreadable JSON, as the SDK editor did before.
        let mut settings = read_settings(&destination).unwrap_or_default();
        settings.default_sdk_path = default_sdk_path;
        write_settings(&destination, &settings)?;
        Ok(settings)
    })
    .await?
}

pub(crate) fn settings_path() -> Result<PathBuf> {
    // A debugging/test override keeps automated runs isolated from personal settings.
    if let Some(path) =
        std::env::var_os("FLUTTER_DEV_SETTINGS_PATH").filter(|path| !path.is_empty())
    {
        return Ok(PathBuf::from(path));
    }
    #[cfg(target_os = "macos")]
    let root = PathBuf::from(std::env::var_os("HOME").context("Home folder is unavailable")?)
        .join("Library/Application Support");
    #[cfg(target_os = "windows")]
    let root =
        PathBuf::from(std::env::var_os("APPDATA").context("App data folder is unavailable")?);
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let root = match std::env::var_os("XDG_CONFIG_HOME").filter(|path| !path.is_empty()) {
        Some(root) => PathBuf::from(root),
        None => PathBuf::from(std::env::var_os("HOME").context("Home folder is unavailable")?)
            .join(".config"),
    };
    Ok(root.join("flutter_dev/settings.json"))
}

pub(crate) fn read_settings(path: &Path) -> Result<AppSettings> {
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(AppSettings::default());
        }
        Err(error) => {
            return Err(error).with_context(|| format!("Read settings {}", path.display()))
        }
    };
    let mut content = Vec::new();
    file.take(MAX_SETTINGS_BYTES as u64 + 1)
        .read_to_end(&mut content)
        .with_context(|| format!("Read settings {}", path.display()))?;
    anyhow::ensure!(
        content.len() <= MAX_SETTINGS_BYTES,
        "App settings file exceeds size limit"
    );
    #[derive(Deserialize)]
    struct StoredSettings {
        #[serde(flatten)]
        settings: AppSettings,
        #[serde(default)]
        build_presets: Option<Vec<crate::build::BuildPreset>>,
    }
    let stored: StoredSettings = serde_json::from_slice(&content)
        .with_context(|| format!("Invalid app settings {}", path.display()))?;
    let mut settings = stored.settings;
    anyhow::ensure!(
        settings.project_build_presets.len() <= MAX_WORKSPACE_PROJECTS,
        "Build preset settings exceed 500 projects"
    );
    let mut paths = HashSet::new();
    for record in &mut settings.project_build_presets {
        record.project_path = normalized_project_path(&record.project_path)?;
        crate::build::validate_presets(&record.presets)?;
    }
    settings
        .project_build_presets
        .retain(|record| paths.insert(record.project_path.clone()));
    // Preserve legacy customization only for projects known to the old settings.
    // Later imports start with their own built-in defaults.
    if let Some(presets) = stored.build_presets {
        crate::build::validate_presets(&presets)?;
        for project in &settings.projects {
            let project_path = normalized_project_path(&project.path)?;
            if paths.insert(project_path.clone()) {
                anyhow::ensure!(
                    settings.project_build_presets.len() < MAX_WORKSPACE_PROJECTS,
                    "Build preset settings exceed 500 projects"
                );
                settings.project_build_presets.push(ProjectBuildPresets {
                    project_path,
                    presets: presets.clone(),
                });
            }
        }
    }
    // An unknown appearance value must not disable a valid saved SDK.
    if !matches!(settings.theme_mode.as_str(), "light" | "dark") {
        settings.theme_mode = default_theme_mode();
    }
    Ok(settings)
}

fn write_settings(path: &Path, settings: &AppSettings) -> Result<()> {
    let mut content = serde_json::to_vec_pretty(settings).context("Serialize app settings")?;
    content.push(b'\n');
    anyhow::ensure!(
        content.len() <= MAX_SETTINGS_BYTES,
        "App settings exceed size limit"
    );
    let parent = path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent)
        .with_context(|| format!("Create settings folder {}", parent.display()))?;
    archive_unowned_legacy_presets(path, parent)?;
    let mut file =
        tempfile::NamedTempFile::new_in(parent).context("Create temporary settings file")?;
    file.write_all(&content)?;
    file.as_file().sync_all().context("Flush app settings")?;
    file.persist(path)
        .with_context(|| format!("Save app settings {}", path.display()))?;
    Ok(())
}

fn archive_unowned_legacy_presets(path: &Path, parent: &Path) -> Result<()> {
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error).context("Read legacy settings for migration"),
    };
    let mut original = Vec::new();
    file.take(MAX_SETTINGS_BYTES as u64 + 1)
        .read_to_end(&mut original)?;
    // Explicit SDK saves can still repair corrupt or oversized settings.
    if original.len() > MAX_SETTINGS_BYTES {
        return Ok(());
    }
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&original) else {
        return Ok(());
    };
    let custom = value
        .get("build_presets")
        .and_then(|value| value.as_array())
        .is_some_and(|presets| !presets.is_empty());
    let has_projects = value
        .get("projects")
        .and_then(|value| value.as_array())
        .is_some_and(|projects| !projects.is_empty());
    if !custom || has_projects {
        return Ok(());
    }
    let archive_path = path.with_extension("legacy-global-presets.json");
    if let Ok(archived) = fs::read(&archive_path) {
        anyhow::ensure!(
            archived == original,
            "Legacy settings backup already contains different data: {}",
            archive_path.display()
        );
        return Ok(());
    }
    let mut archive =
        tempfile::NamedTempFile::new_in(parent).context("Create legacy settings backup")?;
    archive.write_all(&original)?;
    archive
        .as_file()
        .sync_all()
        .context("Flush legacy settings backup")?;
    archive
        .persist_noclobber(&archive_path)
        .with_context(|| format!("Archive legacy settings {}", archive_path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(path: &Path, name: &str) -> crate::project::ProjectInfo {
        crate::project::ProjectInfo {
            name: name.into(),
            path: path.to_string_lossy().into_owned(),
            entrypoint: "lib/alternate.dart".into(),
            platforms: vec!["android".into(), "web".into()],
        }
    }

    #[test]
    fn preferences_round_trip_migrates_and_preserves_other_settings() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        fs::write(
            &path,
            r#"{"default_sdk_path":"/sdk/flutter","theme_mode":"dark"}"#,
        )
        .unwrap();
        let original = read_settings(&path).unwrap();
        assert_eq!(original.workspace_preferences.editor_executable, "code");
        let mut preferences = original.workspace_preferences.clone();
        preferences.editor_executable = "/custom/editor".into();
        preferences.editor_arguments = vec!["{file}".into(), "--line={line}".into()];
        let saved = set_workspace_preferences_at(&path, preferences.clone()).unwrap();
        assert_eq!(saved.workspace_preferences, preferences);
        assert_eq!(saved.default_sdk_path, original.default_sdk_path);
        assert_eq!(saved.theme_mode, original.theme_mode);
        assert_eq!(saved.project_build_presets, original.project_build_presets);
        assert_eq!(read_settings(&path).unwrap(), saved);
        let themed = set_theme_mode_at(&path, "light".into()).unwrap();
        assert_eq!(themed.workspace_preferences, preferences);
        let before = fs::read(&path).unwrap();
        preferences.editor_executable.clear();
        assert!(set_workspace_preferences_at(&path, preferences).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
    }

    #[test]
    fn old_settings_migrate_workspace_without_losing_sdk_theme_or_presets() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        fs::write(
            &path,
            r#"{"default_sdk_path":"/saved/flutter","theme_mode":"dark","build_presets":[]}"#,
        )
        .unwrap();
        let settings = read_settings(&path).unwrap();
        assert!(settings.projects.is_empty());
        assert!(settings.selected_project_path.is_none());
        assert_eq!(settings.default_sdk_path.as_deref(), Some("/saved/flutter"));
        assert_eq!(settings.theme_mode, "dark");
        assert!(settings.project_build_presets.is_empty());
    }

    #[tokio::test]
    async fn workspace_round_trip_deduplicates_and_preserves_all_other_settings() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        let original = AppSettings {
            default_sdk_path: Some("/saved/flutter".into()),
            theme_mode: "dark".into(),
            ..AppSettings::default()
        };
        write_settings(&path, &original).unwrap();
        let missing_path = fixture.path().join("missing/project");
        assert!(!missing_path.exists());
        let first = project(&missing_path, "first");
        let duplicate = project(&missing_path, "duplicate");
        let second = project(&fixture.path().join("other missing project"), "second");
        let saved = set_workspace_projects_at(
            &path,
            vec![first.clone(), duplicate, second.clone()],
            Some(second.path.clone()),
        )
        .unwrap();
        assert_eq!(saved.projects, vec![first, second.clone()]);
        assert_eq!(
            saved.selected_project_path.as_deref(),
            Some(second.path.as_str())
        );
        assert_eq!(saved.default_sdk_path, original.default_sdk_path);
        assert_eq!(saved.theme_mode, original.theme_mode);
        assert_eq!(saved.project_build_presets, original.project_build_presets);
        assert_eq!(read_settings(&path).unwrap(), saved);
        let themed = set_theme_mode_at(&path, "light".into()).unwrap();
        assert_eq!(themed.projects, saved.projects);
        assert_eq!(themed.selected_project_path, saved.selected_project_path);
        set_build_presets_at(&path, &second.path, vec![]).unwrap();
        let presets = read_settings(&path).unwrap();
        assert_eq!(presets.projects, saved.projects);
        assert_eq!(presets.selected_project_path, saved.selected_project_path);
        assert_eq!(presets.default_sdk_path, original.default_sdk_path);
        let sdk_cleared = set_default_sdk_at(path.clone(), None).await.unwrap();
        assert_eq!(sdk_cleared.projects, saved.projects);
        assert_eq!(
            sdk_cleared.selected_project_path,
            saved.selected_project_path
        );
        assert_eq!(sdk_cleared.theme_mode, "light");
        assert!(build_presets_at(&path, &second.path).unwrap().is_empty());
        assert_eq!(read_settings(&path).unwrap(), sdk_cleared);
        let cleared = set_workspace_projects_at(&path, vec![], None).unwrap();
        assert!(cleared.projects.is_empty());
        assert!(cleared.selected_project_path.is_none());
        assert_eq!(cleared.theme_mode, "light");
        assert!(build_presets_at(&path, &second.path).unwrap().is_empty());
    }

    #[test]
    fn invalid_workspace_and_oversized_settings_cannot_overwrite_saved_file() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        let valid = project(&fixture.path().join("saved missing project"), "saved");
        let saved = set_workspace_projects_at(&path, vec![valid.clone()], Some(valid.path.clone()))
            .unwrap();
        let content = fs::read(&path).unwrap();
        for invalid_path in ["", " ", "relative/project", "\0"] {
            let mut invalid = valid.clone();
            invalid.path = invalid_path.into();
            assert!(set_workspace_projects_at(&path, vec![invalid], None).is_err());
            assert_eq!(fs::read(&path).unwrap(), content);
        }
        assert!(set_workspace_projects_at(
            &path,
            vec![valid.clone()],
            Some("/not/in/workspace".into())
        )
        .is_err());
        assert!(set_workspace_projects_at(&path, vec![], Some(valid.path.clone())).is_err());
        assert!(set_workspace_projects_at(
            &path,
            vec![valid.clone(); MAX_WORKSPACE_PROJECTS + 1],
            None
        )
        .is_err());
        let mut oversized = valid;
        oversized.name = "x".repeat(MAX_SETTINGS_BYTES);
        assert!(set_workspace_projects_at(&path, vec![oversized], None)
            .unwrap_err()
            .to_string()
            .contains("size limit"));
        assert_eq!(fs::read(&path).unwrap(), content);
        assert_eq!(read_settings(&path).unwrap(), saved);
        fs::write(&path, "{broken").unwrap();
        assert!(set_workspace_projects_at(&path, saved.projects, None).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "{broken");
    }

    fn custom_preset() -> crate::build::BuildPreset {
        crate::build::BuildPreset {
            id: "custom-web".into(),
            name: "Custom Web".into(),
            target: "web".into(),
            args: vec!["--release".into(), "--output=dist with spaces".into()],
            output_directory: Some("dist with spaces".into()),
        }
    }

    #[tokio::test]
    async fn project_presets_are_independent_persist_and_preserve_other_settings() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        fs::write(
            &path,
            r#"{"default_sdk_path":"/sdk/flutter","theme_mode":"dark"}"#,
        )
        .unwrap();
        let first = fixture.path().join("first").to_string_lossy().into_owned();
        let second = fixture.path().join("second").to_string_lossy().into_owned();
        let custom = custom_preset();
        let defaults = crate::build::default_build_presets();
        assert_eq!(build_presets_at(&path, &first).unwrap(), defaults);
        assert_eq!(
            set_build_presets_at(&path, &first, vec![custom.clone()]).unwrap(),
            vec![custom.clone()]
        );
        assert_eq!(
            build_presets_at(&path, &first).unwrap(),
            vec![custom.clone()]
        );
        assert_eq!(build_presets_at(&path, &second).unwrap(), defaults);
        set_build_presets_at(&path, &second, vec![]).unwrap();
        assert!(build_presets_at(&path, &second).unwrap().is_empty());
        let preferences = crate::workspace::WorkspacePreferences {
            editor_executable: "custom-editor".into(),
            ..Default::default()
        };
        set_workspace_preferences_at(&path, preferences).unwrap();
        set_workspace_projects_at(
            &path,
            vec![project(Path::new(&first), "first")],
            Some(first.clone()),
        )
        .unwrap();
        set_theme_mode_at(&path, "light".into()).unwrap();
        set_default_sdk_at(path.clone(), None).await.unwrap();
        assert_eq!(
            build_presets_at(&path, &first).unwrap(),
            vec![custom.clone()]
        );
        assert!(build_presets_at(&path, &second).unwrap().is_empty());
        let saved = read_settings(&path).unwrap();
        assert_eq!(saved.project_build_presets.len(), 2);
        assert_eq!(saved.theme_mode, "light");
        let before = fs::read(&path).unwrap();
        assert!(set_build_presets_at(&path, &first, vec![custom.clone(), custom.clone()]).is_err());
        for invalid in ["", " ", "relative/project", "\0"] {
            assert!(set_build_presets_at(&path, invalid, vec![]).is_err());
            assert!(build_presets_at(&path, invalid).is_err());
        }
        let mut oversized = custom;
        oversized.args = vec!["x".repeat(16384); 70];
        assert!(set_build_presets_at(&path, &first, vec![oversized])
            .unwrap_err()
            .to_string()
            .contains("size limit"));
        assert_eq!(fs::read(&path).unwrap(), before);
        fs::write(&path, "{broken").unwrap();
        assert!(set_build_presets_at(&path, &first, vec![]).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "{broken");
    }

    #[test]
    fn legacy_presets_migrate_only_for_imported_projects_and_scoped_records_win() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        let first = project(&fixture.path().join("first"), "first");
        let second = project(&fixture.path().join("second"), "second");
        let third = fixture.path().join("new").to_string_lossy().into_owned();
        let custom = custom_preset();
        fs::write(
            &path,
            serde_json::to_vec(&serde_json::json!({
                "build_presets": [custom.clone()], "projects": [first.clone(), second.clone()],
                "project_build_presets": [{"project_path": second.path, "presets": []}],
            }))
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            build_presets_at(&path, &first.path).unwrap(),
            vec![custom.clone()]
        );
        assert!(build_presets_at(&path, &second.path).unwrap().is_empty());
        set_theme_mode_at(&path, "dark".into()).unwrap();
        let stored: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert!(stored.get("build_presets").is_none());
        assert_eq!(build_presets_at(&path, &first.path).unwrap(), vec![custom]);
        assert_eq!(
            build_presets_at(&path, &third).unwrap(),
            crate::build::default_build_presets()
        );
        set_workspace_projects_at(
            &path,
            vec![project(Path::new(&third), "new")],
            Some(third.clone()),
        )
        .unwrap();
        assert_eq!(
            build_presets_at(&path, &third).unwrap(),
            crate::build::default_build_presets()
        );
    }

    #[test]
    fn project_preset_paths_share_identity_and_records_are_bounded() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        let project = fixture.path().join("project");
        fs::create_dir(&project).unwrap();
        let normalized = project.to_string_lossy().into_owned();
        set_build_presets_at(&path, &format!("{normalized}/./"), vec![]).unwrap();
        assert!(build_presets_at(&path, &normalized).unwrap().is_empty());
        set_build_presets_at(
            &path,
            &format!("{normalized}/missing/.."),
            vec![custom_preset()],
        )
        .unwrap();
        assert_eq!(read_settings(&path).unwrap().project_build_presets.len(), 1);
        #[cfg(unix)]
        {
            let alias = fixture.path().join("alias");
            std::os::unix::fs::symlink(&project, &alias).unwrap();
            assert_eq!(
                build_presets_at(&path, alias.to_str().unwrap()).unwrap(),
                vec![custom_preset()]
            );
        }
        assert_eq!(
            windows_project_identity(r"C:\Projects\APP"),
            windows_project_identity(r"\\?\c:\projects\app")
        );
        assert_eq!(
            windows_project_identity(r"\\server\share\app"),
            windows_project_identity(r"\\?\UNC\SERVER\share\APP")
        );
        let mut settings = read_settings(&path).unwrap();
        settings.project_build_presets = (0..MAX_WORKSPACE_PROJECTS)
            .map(|index| ProjectBuildPresets {
                project_path: fixture
                    .path()
                    .join(index.to_string())
                    .to_string_lossy()
                    .into_owned(),
                presets: vec![],
            })
            .collect();
        write_settings(&path, &settings).unwrap();
        let before = fs::read(&path).unwrap();
        assert!(set_build_presets_at(&path, &normalized, vec![]).is_err());
        assert_eq!(fs::read(&path).unwrap(), before);
    }

    #[cfg(unix)]
    #[test]
    fn inaccessible_project_does_not_disable_other_presets_or_settings() {
        use std::os::unix::fs::PermissionsExt;
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        let blocked = fixture.path().join("blocked");
        fs::create_dir_all(blocked.join("project")).unwrap();
        let blocked_project = blocked.join("project").to_string_lossy().into_owned();
        let available = fixture
            .path()
            .join("available")
            .to_string_lossy()
            .into_owned();
        set_build_presets_at(&path, &blocked_project, vec![custom_preset()]).unwrap();
        set_build_presets_at(&path, &available, vec![]).unwrap();
        fs::set_permissions(&blocked, fs::Permissions::from_mode(0o000)).unwrap();
        let saved = set_theme_mode_at(&path, "dark".into());
        let blocked_presets = build_presets_at(&path, &blocked_project);
        let available_presets = build_presets_at(&path, &available);
        fs::set_permissions(&blocked, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(saved.unwrap().project_build_presets.len(), 2);
        assert_eq!(blocked_presets.unwrap(), vec![custom_preset()]);
        assert!(available_presets.unwrap().is_empty());
        // A canonicalization error other than NotFound must also retain a usable
        // lexical identity rather than making the entire settings file unreadable.
        let loop_path = fixture.path().join("loop");
        std::os::unix::fs::symlink(&loop_path, &loop_path).unwrap();
        set_build_presets_at(&path, loop_path.to_str().unwrap(), vec![]).unwrap();
        assert!(build_presets_at(&path, loop_path.to_str().unwrap())
            .unwrap()
            .is_empty());
        assert_eq!(read_settings(&path).unwrap().project_build_presets.len(), 3);
    }

    #[test]
    fn unowned_legacy_customization_is_archived_without_becoming_new_project_defaults() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        let original =
            serde_json::to_vec(&serde_json::json!({"build_presets": [custom_preset()]})).unwrap();
        fs::write(&path, &original).unwrap();
        let project = fixture.path().join("new").to_string_lossy().into_owned();
        assert_eq!(
            build_presets_at(&path, &project).unwrap(),
            crate::build::default_build_presets()
        );
        set_theme_mode_at(&path, "dark".into()).unwrap();
        assert_eq!(
            fs::read(path.with_extension("legacy-global-presets.json")).unwrap(),
            original
        );
        assert_eq!(
            build_presets_at(&path, &project).unwrap(),
            crate::build::default_build_presets()
        );
        let stored: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert!(stored.get("build_presets").is_none());
    }

    #[test]
    fn old_settings_migrate_to_light_and_theme_changes_preserve_sdk() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        fs::write(&path, r#"{"default_sdk_path":"/missing/flutter"}"#).unwrap();
        let original = read_settings(&path).unwrap();
        assert_eq!(original.theme_mode, "light");
        let dark = set_theme_mode_at(&path, "dark".into()).unwrap();
        assert_eq!(dark.default_sdk_path, original.default_sdk_path);
        assert_eq!(dark.theme_mode, "dark");
        assert_eq!(read_settings(&path).unwrap(), dark);
        assert!(set_theme_mode_at(&path, "system".into()).is_err());
        assert_eq!(read_settings(&path).unwrap(), dark);
        assert_eq!(set_theme_mode_at(&path, "light".into()).unwrap(), original);
    }

    #[test]
    fn unknown_saved_theme_uses_light_without_losing_sdk() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        fs::write(
            &path,
            r#"{"default_sdk_path":"/sdk/flutter","theme_mode":"unknown"}"#,
        )
        .unwrap();
        let settings = read_settings(&path).unwrap();
        assert_eq!(settings.theme_mode, "light");
        assert_eq!(settings.default_sdk_path.as_deref(), Some("/sdk/flutter"));
    }

    #[tokio::test]
    async fn sdk_clear_preserves_theme_and_explicit_saves_repair_broken_json() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        let dark = set_theme_mode_at(&path, "dark".into()).unwrap();
        let cleared = set_default_sdk_at(path.clone(), None).await.unwrap();
        assert_eq!(cleared, dark);
        fs::write(&path, "{broken").unwrap();
        assert_eq!(
            set_default_sdk_at(path.clone(), None).await.unwrap(),
            AppSettings::default()
        );
        fs::write(&path, "{broken").unwrap();
        assert!(set_theme_mode_at(&path, "dark".into()).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "{broken");
    }

    #[test]
    fn settings_round_trip_clear_and_decode_errors() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("nested/settings.json");
        assert_eq!(read_settings(&path).unwrap(), AppSettings::default());
        let settings = AppSettings {
            default_sdk_path: Some("/sdk/flutter".into()),
            ..AppSettings::default()
        };
        write_settings(&path, &settings).unwrap();
        assert_eq!(read_settings(&path).unwrap(), settings);
        write_settings(&path, &AppSettings::default()).unwrap();
        assert_eq!(read_settings(&path).unwrap(), AppSettings::default());
        fs::write(&path, "{broken").unwrap();
        assert!(read_settings(&path)
            .unwrap_err()
            .to_string()
            .contains("Invalid app settings"));
    }

    #[tokio::test]
    async fn invalid_submission_preserves_saved_settings() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().join("settings.json");
        let settings = AppSettings {
            default_sdk_path: Some("/previous/flutter".into()),
            ..AppSettings::default()
        };
        write_settings(&path, &settings).unwrap();
        assert!(set_default_sdk_at(
            path.clone(),
            Some(
                fixture
                    .path()
                    .join("missing")
                    .to_string_lossy()
                    .into_owned()
            )
        )
        .await
        .is_err());
        assert_eq!(read_settings(&path).unwrap(), settings);
        assert_eq!(
            set_default_sdk_at(path.clone(), Some(" ".into()))
                .await
                .unwrap(),
            AppSettings::default()
        );
        assert_eq!(read_settings(&path).unwrap(), AppSettings::default());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn validated_submission_persists_canonical_path() {
        use std::os::unix::fs::PermissionsExt;
        let fixture = tempfile::tempdir().unwrap();
        let sdk = fixture.path().join("sdk");
        fs::create_dir_all(sdk.join("bin")).unwrap();
        let program = sdk.join("bin/flutter");
        fs::write(&program, "#!/bin/sh\nprintf '%s\\n' '{\"frameworkVersion\":\"3.test\",\"dartSdkVersion\":\"3.dart\"}'\n").unwrap();
        fs::set_permissions(program, fs::Permissions::from_mode(0o755)).unwrap();
        let path = fixture.path().join("settings.json");
        set_theme_mode_at(&path, "dark".into()).unwrap();
        let saved = set_default_sdk_at(
            path.clone(),
            Some(sdk.join(".").to_string_lossy().into_owned()),
        )
        .await
        .unwrap();
        assert_eq!(saved.theme_mode, "dark");
        assert_eq!(
            saved.default_sdk_path,
            Some(sdk.canonicalize().unwrap().to_string_lossy().into_owned())
        );
        assert_eq!(
            read_settings(&fixture.path().join("settings.json")).unwrap(),
            saved
        );
    }
}
