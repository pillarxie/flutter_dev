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

const MAX_RECORDS: usize = 4096;
const MAX_BYTES: usize = 1024 * 1024;
static REGISTRY_WRITE: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct BuildCacheCleanupResult {
    pub deleted_paths: Vec<String>,
    pub errors: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Artifact {
    project: PathBuf,
    path: PathBuf,
    directory: bool,
}

pub(crate) fn registry_path() -> Result<PathBuf> {
    Ok(crate::settings::settings_path()?.with_extension("build-cache.json"))
}

fn read_registry(path: &Path) -> Result<Vec<Artifact>> {
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
        Err(error) => return Err(error).context("Read build cache registry"),
    };
    let mut bytes = Vec::new();
    file.take(MAX_BYTES as u64 + 1).read_to_end(&mut bytes)?;
    anyhow::ensure!(
        bytes.len() <= MAX_BYTES,
        "Build cache registry exceeds size limit"
    );
    let records: Vec<Artifact> =
        serde_json::from_slice(&bytes).context("Invalid build cache registry")?;
    anyhow::ensure!(
        records.len() <= MAX_RECORDS,
        "Build cache registry exceeds record limit"
    );
    Ok(records)
}

fn write_registry(path: &Path, records: &[Artifact]) -> Result<()> {
    anyhow::ensure!(
        records.len() <= MAX_RECORDS,
        "Build cache registry is full; clear build cache before building again"
    );
    let bytes = serde_json::to_vec(records)?;
    anyhow::ensure!(
        bytes.len() <= MAX_BYTES,
        "Build cache registry is full; clear build cache before building again"
    );
    let parent = path
        .parent()
        .context("Build cache registry has no parent")?;
    fs::create_dir_all(parent)?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    file.write_all(&bytes)?;
    file.as_file().sync_all()?;
    file.persist(path).context("Save build cache registry")?;
    Ok(())
}

// The first path is the standard project build folder. Custom output folders
// become owned only when absent before this task or already tracked as output.
pub(crate) async fn prepare(
    registry: PathBuf,
    project: PathBuf,
    paths: Vec<PathBuf>,
) -> Result<Vec<String>> {
    let _guard = REGISTRY_WRITE.get_or_init(|| Mutex::new(())).lock().await;
    tokio::task::spawn_blocking(move || {
        let mut records = read_registry(&registry)?;
        let mut warnings = vec![];
        for (index, path) in paths.into_iter().enumerate() {
            let path = normalize(&path)?;
            let artifact = Artifact { project: project.clone(), path: path.clone(), directory: true };
            let absent = match fs::symlink_metadata(&path) {
                Ok(_) => false,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
                Err(error) => return Err(error).context("Inspect custom build output"),
            };
            if index == 0 || absent || records.contains(&artifact) {
                if !records.contains(&artifact) { records.push(artifact); }
            } else {
                warnings.push(format!("Existing custom output folder is not owned by this tool; only reported files or app bundles can be cleared: {}", path.display()));
            }
        }
        write_registry(&registry, &records)?;
        Ok(warnings)
    }).await?
}

pub(crate) async fn record_observed(
    registry: PathBuf,
    project: PathBuf,
    path: PathBuf,
) -> Result<bool> {
    let _guard = REGISTRY_WRITE.get_or_init(|| Mutex::new(())).lock().await;
    tokio::task::spawn_blocking(move || {
        let mut records = read_registry(&registry)?;
        let path = normalize(&path)?;
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(error).context("Inspect reported build artifact"),
        };
        anyhow::ensure!(
            !is_link(&metadata),
            "Build artifact is a symlink or junction"
        );
        let directory = metadata.is_dir();
        let bundle = path.extension().is_some_and(|extension| {
            extension.eq_ignore_ascii_case("app") || extension.eq_ignore_ascii_case("xcarchive")
        });
        if directory
            && !bundle
            && !records.iter().any(|record| {
                record.project == project && record.directory && contains(&path, &record.path)
            })
        {
            return Ok(false);
        }
        let artifact = Artifact {
            project,
            path,
            directory,
        };
        if !records.contains(&artifact) {
            records.push(artifact);
        }
        write_registry(&registry, &records)?;
        Ok(true)
    })
    .await?
}

pub(crate) async fn finish_tracking(registry: PathBuf, project: PathBuf) -> Result<()> {
    let _guard = REGISTRY_WRITE.get_or_init(|| Mutex::new(())).lock().await;
    tokio::task::spawn_blocking(move || {
        let mut records = read_registry(&registry)?;
        records.retain(|record| {
            record.project != project || record.path == project.join("build")
                || !matches!(fs::symlink_metadata(&record.path), Err(error) if error.kind() == std::io::ErrorKind::NotFound)
        });
        write_registry(&registry, &records)
    }).await?
}

fn normalize(path: &Path) -> Result<PathBuf> {
    anyhow::ensure!(path.is_absolute(), "Build artifact path must be absolute");
    let mut normalized = PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                anyhow::ensure!(normalized.pop(), "Invalid build artifact path");
            }
            part => normalized.push(part.as_os_str()),
        }
    }
    Ok(normalized)
}

#[cfg(any(windows, test))]
fn windows_comparison_path(path: &str) -> String {
    let path = path.replace('/', "\\");
    let path = if let Some(path) = path.strip_prefix("\\\\?\\UNC\\") {
        format!("\\\\{path}")
    } else {
        path.strip_prefix("\\\\?\\").unwrap_or(&path).to_owned()
    };
    path.to_lowercase()
}

fn comparison_path(path: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        PathBuf::from(windows_comparison_path(&path.to_string_lossy()))
    }
    #[cfg(not(windows))]
    {
        path.to_owned()
    }
}

pub(crate) fn contains(path: &Path, ancestor: &Path) -> bool {
    comparison_path(path).starts_with(comparison_path(ancestor))
}

fn is_link(metadata: &fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        return metadata.file_attributes() & 0x400 != 0;
    }
    #[cfg(not(windows))]
    false
}

fn validate_target(path: &Path, projects: &[PathBuf]) -> Result<()> {
    anyhow::ensure!(
        path.parent().is_some() && path.components().count() > 1,
        "Refusing filesystem root"
    );
    for project in projects {
        anyhow::ensure!(
            !contains(project, path),
            "Refusing project folder or its ancestor: {}",
            path.display()
        );
        let comparable_path = comparison_path(path);
        if let Ok(relative) = comparable_path.strip_prefix(comparison_path(project)) {
            if let Some(Component::Normal(first)) = relative.components().next() {
                let first = first.to_string_lossy();
                anyhow::ensure!(
                    !matches!(
                        first.as_ref(),
                        "lib"
                            | "test"
                            | "integration_test"
                            | "assets"
                            | "android"
                            | "ios"
                            | "macos"
                            | "windows"
                            | "linux"
                            | "web"
                            | "example"
                            | "packages"
                            | ".git"
                            | ".dart_tool"
                            | ".fvm"
                            | "pubspec.yaml"
                            | "pubspec.lock"
                    ),
                    "Refusing project source or configuration path: {}",
                    path.display()
                );
            }
        }
    }
    for name in ["HOME", "USERPROFILE"] {
        if let Some(home) = std::env::var_os(name) {
            let home = PathBuf::from(home);
            anyhow::ensure!(
                !contains(&home, path),
                "Refusing home folder or its ancestor"
            );
        }
    }
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(metadata) => anyhow::ensure!(
                !is_link(&metadata),
                "Refusing symlink or junction: {}",
                ancestor.display()
            ),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error).with_context(|| format!("Inspect {}", ancestor.display()))
            }
        }
    }
    // An output flag or SDK message must never make another source checkout disposable.
    anyhow::ensure!(
        !path.join("pubspec.yaml").exists() && !path.join(".git").exists(),
        "Refusing source project folder"
    );
    Ok(())
}

pub(crate) async fn clear(
    registry: PathBuf,
    projects: Vec<PathBuf>,
) -> Result<BuildCacheCleanupResult> {
    let _guard = REGISTRY_WRITE.get_or_init(|| Mutex::new(())).lock().await;
    tokio::task::spawn_blocking(move || clear_at(&registry, projects)).await?
}

fn clear_at(registry: &Path, projects: Vec<PathBuf>) -> Result<BuildCacheCleanupResult> {
    let records = read_registry(registry)?;
    let mut protected = Vec::new();
    for project in projects
        .iter()
        .chain(records.iter().map(|record| &record.project))
    {
        let project = normalize(project)?;
        protected.push(fs::canonicalize(&project).unwrap_or(project));
    }
    protected.sort();
    protected.dedup();
    let mut targets: Vec<(PathBuf, bool)> = projects
        .iter()
        .map(|project| {
            (
                fs::canonicalize(project)
                    .unwrap_or_else(|_| project.clone())
                    .join("build"),
                true,
            )
        })
        .collect();
    targets.extend(
        records
            .iter()
            .map(|record| (record.path.clone(), record.directory)),
    );
    let mut unique = HashSet::new();
    targets.retain(|(path, _)| unique.insert(comparison_path(path)));
    // Parents first avoid double-counting nested artifacts after their build folder was deleted.
    targets.sort_by_key(|(path, _)| path.components().count());
    let mut result = BuildCacheCleanupResult::default();
    let mut removed = HashSet::new();
    for (path, directory) in targets {
        let outcome = (|| -> Result<()> {
            let path = normalize(&path)?;
            validate_target(&path, &protected)?;
            let metadata = match fs::symlink_metadata(&path) {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    removed.insert(path);
                    return Ok(());
                }
                Err(error) => return Err(error.into()),
            };
            anyhow::ensure!(
                metadata.is_dir() == directory,
                "Build artifact type changed since it was recorded"
            );
            if metadata.is_dir() {
                fs::remove_dir_all(&path)?;
            } else {
                fs::remove_file(&path)?;
            }
            result
                .deleted_paths
                .push(path.to_string_lossy().into_owned());
            removed.insert(path);
            Ok(())
        })();
        if let Err(error) = outcome {
            result.errors.push(format!("{}: {error:#}", path.display()));
        }
    }
    let retained: Vec<_> = records
        .into_iter()
        .filter(|record| !removed.iter().any(|path| contains(&record.path, path)))
        .collect();
    if let Err(error) = write_registry(registry, &retained) {
        result
            .errors
            .push(format!("Save build cache registry: {error:#}"));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_path_comparison_normalizes_verbatim_prefix_and_case() {
        assert_eq!(
            windows_comparison_path(r"\\?\C:\Users\Iron\Project"),
            windows_comparison_path(r"c:/users/iron/project")
        );
        assert_eq!(
            windows_comparison_path(r"\\?\UNC\Server\Share\Project"),
            windows_comparison_path(r"\\server\share\project")
        );
    }

    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let project = root.join("project");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("pubspec.yaml"), "name: fixture").unwrap();
        (temp, root.join("registry.json"), project)
    }
    fn put(path: &Path) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "fixture").unwrap();
    }

    #[tokio::test]
    async fn all_projects_and_persisted_custom_artifacts_clear_without_reveal_folders() {
        let (_temp, registry, project) = fixture();
        let second = project.parent().unwrap().join("second");
        fs::create_dir_all(&second).unwrap();
        let custom = project.parent().unwrap().join("custom/output.apk");
        let reveal = project.join("reveal/keep.txt");
        put(&project.join("build/app.apk"));
        put(&second.join("build/web/index.html"));
        put(&custom);
        put(&reveal);
        prepare(
            registry.clone(),
            project.clone(),
            vec![project.join("build")],
        )
        .await
        .unwrap();
        assert!(
            record_observed(registry.clone(), project.clone(), custom.clone())
                .await
                .unwrap()
        );
        // The registry survives manager/history eviction and process restarts.
        let result = clear(registry.clone(), vec![second.clone(), second])
            .await
            .unwrap();
        assert!(result.errors.is_empty(), "{:?}", result.errors);
        assert_eq!(result.deleted_paths.len(), 3);
        assert!(!custom.exists());
        assert!(!project.join("build").exists());
        assert!(reveal.exists());
        assert!(read_registry(&registry).unwrap().is_empty());
    }

    #[tokio::test]
    async fn existing_custom_directories_need_ownership_and_reported_files_stay_precise() {
        let (_temp, registry, project) = fixture();
        let custom = project.parent().unwrap().join("existing-dist");
        put(&custom.join("personal.txt"));
        let warnings = prepare(
            registry.clone(),
            project.clone(),
            vec![project.join("build"), custom.clone()],
        )
        .await
        .unwrap();
        assert_eq!(warnings.len(), 1);
        assert!(
            !record_observed(registry.clone(), project.clone(), custom.clone())
                .await
                .unwrap()
        );
        put(&custom.join("app.apk"));
        assert!(
            record_observed(registry.clone(), project.clone(), custom.join("app.apk"))
                .await
                .unwrap()
        );
        let result = clear(registry, vec![project]).await.unwrap();
        assert!(result.errors.is_empty());
        assert!(custom.join("personal.txt").exists());
        assert!(!custom.join("app.apk").exists());
    }

    #[tokio::test]
    async fn new_custom_directory_is_owned_and_missing_outputs_are_harmless() {
        let (_temp, registry, project) = fixture();
        let custom = project.parent().unwrap().join("new-dist");
        let absent = project.parent().unwrap().join("never-created");
        assert!(prepare(
            registry.clone(),
            project.clone(),
            vec![project.join("build"), custom.clone(), absent]
        )
        .await
        .unwrap()
        .is_empty());
        put(&custom.join("index.html"));
        assert!(
            record_observed(registry.clone(), project.clone(), custom.clone())
                .await
                .unwrap()
        );
        let result = clear(registry.clone(), vec![]).await.unwrap();
        assert!(result.errors.is_empty());
        assert_eq!(
            result.deleted_paths,
            vec![custom.to_string_lossy().into_owned()]
        );
        assert!(read_registry(&registry).unwrap().is_empty());
    }

    #[tokio::test]
    async fn source_paths_and_project_ancestors_are_rejected_with_partial_success() {
        let (_temp, registry, project) = fixture();
        let source = project.join("lib/generated");
        let artifact = project.parent().unwrap().join("output.apk");
        put(&source.join("keep.dart"));
        put(&artifact);
        write_registry(
            &registry,
            &[
                Artifact {
                    project: project.clone(),
                    path: source.clone(),
                    directory: true,
                },
                Artifact {
                    project: project.clone(),
                    path: project.clone(),
                    directory: true,
                },
                Artifact {
                    project: project.clone(),
                    path: artifact.clone(),
                    directory: false,
                },
            ],
        )
        .unwrap();
        let result = clear(registry.clone(), vec![project.clone()])
            .await
            .unwrap();
        assert_eq!(result.errors.len(), 2, "{:?}", result.errors);
        assert_eq!(
            result.deleted_paths,
            vec![artifact.to_string_lossy().into_owned()]
        );
        assert!(source.join("keep.dart").exists());
        assert!(project.join("pubspec.yaml").exists());
        assert_eq!(read_registry(&registry).unwrap().len(), 2);
    }

    #[tokio::test]
    async fn duplicates_are_removed_once_and_failed_paths_remain_retryable() {
        let (_temp, registry, project) = fixture();
        let output = project.parent().unwrap().join("output.apk");
        put(&output);
        assert!(
            record_observed(registry.clone(), project.clone(), output.clone())
                .await
                .unwrap()
        );
        assert!(
            record_observed(registry.clone(), project.clone(), output.clone())
                .await
                .unwrap()
        );
        assert_eq!(read_registry(&registry).unwrap().len(), 1);
        fs::remove_file(&output).unwrap();
        fs::create_dir(&output).unwrap();
        let failed = clear(registry.clone(), vec![]).await.unwrap();
        assert_eq!(failed.errors.len(), 1);
        assert_eq!(read_registry(&registry).unwrap().len(), 1);
        fs::remove_dir(&output).unwrap();
        put(&output);
        let retry = clear(registry.clone(), vec![]).await.unwrap();
        assert!(retry.errors.is_empty());
        assert_eq!(retry.deleted_paths.len(), 1);
        assert!(read_registry(&registry).unwrap().is_empty());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn symlink_targets_are_rejected_and_nested_links_do_not_escape_build() {
        use std::os::unix::fs::symlink;
        let (_temp, registry, project) = fixture();
        let external = project.parent().unwrap().join("external");
        put(&external.join("keep.txt"));
        fs::create_dir(project.join("build")).unwrap();
        symlink(&external, project.join("build/nested-link")).unwrap();
        let result = clear(registry.clone(), vec![project.clone()])
            .await
            .unwrap();
        assert!(result.errors.is_empty());
        assert!(external.join("keep.txt").exists());
        symlink(&external, project.join("build")).unwrap();
        let result = clear(registry, vec![project.clone()]).await.unwrap();
        assert_eq!(result.errors.len(), 1);
        assert!(external.join("keep.txt").exists());
        assert!(project.join("build").is_symlink());
    }

    #[tokio::test]
    async fn full_registry_reports_failure_without_eviction() {
        let (_temp, registry, project) = fixture();
        let records: Vec<_> = (0..MAX_RECORDS)
            .map(|index| Artifact {
                project: project.clone(),
                path: project.join(format!("build/{index}")),
                directory: false,
            })
            .collect();
        write_registry(&registry, &records).unwrap();
        let result = prepare(
            registry.clone(),
            project.clone(),
            vec![project.join("build")],
        )
        .await;
        assert!(result.is_err());
        assert_eq!(read_registry(&registry).unwrap(), records);
    }
}
