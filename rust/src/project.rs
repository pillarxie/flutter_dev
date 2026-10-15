use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{fs, path::Path};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectInfo {
    pub name: String,
    pub path: String,
    pub entrypoint: String,
    pub platforms: Vec<String>,
}

pub async fn discover_projects(root: String) -> Result<Vec<ProjectInfo>> {
    tokio::task::spawn_blocking(move || discover(Path::new(&root))).await?
}

fn discover(root: &Path) -> Result<Vec<ProjectInfo>> {
    let root = root
        .canonicalize()
        .context("Project folder does not exist")?;
    if !root.is_dir() {
        bail!("Project root must be a directory");
    }
    let mut pending = vec![(root, 0usize)];
    let mut projects = Vec::new();
    let mut visited = 0;
    while let Some((directory, depth)) = pending.pop() {
        visited += 1;
        if visited > 10_000 {
            bail!("Project scan exceeds 10000 folders; select a narrower root");
        }
        let pubspec = directory.join("pubspec.yaml");
        if pubspec.is_file() {
            if fs::metadata(&pubspec)?.len() > 1024 * 1024 {
                bail!("pubspec.yaml exceeds size limit: {}", pubspec.display());
            }
            let content =
                fs::read(&pubspec).with_context(|| format!("Read {}", pubspec.display()))?;
            if content.len() > 1024 * 1024 {
                bail!("pubspec.yaml exceeds size limit: {}", pubspec.display());
            }
            let value: serde_yaml::Value = serde_yaml::from_slice(&content)
                .with_context(|| format!("Parse {}", pubspec.display()))?;
            let flutter = value
                .get("dependencies")
                .and_then(|v| v.get("flutter"))
                .and_then(|v| v.get("sdk"))
                .and_then(serde_yaml::Value::as_str)
                == Some("flutter");
            if flutter {
                let name = value
                    .get("name")
                    .and_then(serde_yaml::Value::as_str)
                    .context("Flutter package is missing its pubspec name")?;
                let platforms = ["android", "ios", "macos", "windows", "linux", "web"]
                    .into_iter()
                    .filter(|platform| directory.join(platform).is_dir())
                    .map(str::to_owned)
                    .collect();
                projects.push(ProjectInfo {
                    name: name.to_owned(),
                    path: directory.to_string_lossy().into_owned(),
                    entrypoint: "lib/main.dart".into(),
                    platforms,
                });
            }
        }
        if depth >= 12 {
            continue;
        }
        for entry in
            fs::read_dir(&directory).with_context(|| format!("Scan {}", directory.display()))?
        {
            let entry = entry?;
            let kind = entry.file_type()?;
            // Symlinked directories (including FVM and package caches) cannot create loops.
            if !kind.is_dir() || kind.is_symlink() {
                continue;
            }
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with('.')
                || ["build", "node_modules", "Pods", "vendor", "ephemeral"].contains(&name.as_ref())
            {
                continue;
            }
            pending.push((entry.path(), depth + 1));
        }
    }
    projects.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(projects)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn discovers_packages_not_repository_root_or_caches() {
        let root =
            std::env::temp_dir().join(format!("flutter-dev-project-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for folder in ["apps/a", "packages/plain", "build/generated"] {
            fs::create_dir_all(root.join(folder)).unwrap();
        }
        fs::write(
            root.join("apps/a/pubspec.yaml"),
            "name: sample\ndependencies:\n  flutter:\n    sdk: flutter\n",
        )
        .unwrap();
        fs::create_dir_all(root.join("apps/a/macos")).unwrap();
        fs::write(
            root.join("packages/plain/pubspec.yaml"),
            "name: plain\ndependencies:\n  collection: any\n",
        )
        .unwrap();
        fs::write(
            root.join("build/generated/pubspec.yaml"),
            "name: cached\ndependencies:\n  flutter:\n    sdk: flutter\n",
        )
        .unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&root, root.join("apps/a/loop")).unwrap();
        let found = discover_projects(root.to_string_lossy().into_owned())
            .await
            .unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].name, "sample");
        assert_eq!(found[0].platforms, vec!["macos"]);
        fs::remove_dir_all(root).unwrap();
    }
}
