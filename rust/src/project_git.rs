use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::ExitStatus,
    time::Duration,
};
use tokio::io::{AsyncRead, AsyncReadExt};

use crate::process::OwnedProcess;

const OUTPUT_LIMIT: usize = 1024 * 1024;
const ERROR_LIMIT: usize = 64 * 1024;
const COMMAND_TIMEOUT: Duration = Duration::from_secs(20);

// Git's repository-local environment (git rev-parse --local-env-vars), plus
// namespace/discovery overrides, must not redirect this project's index, object
// database, refs or worktree when the workbench is launched from another Git tool.
const REPOSITORY_ENV: &[&str] = &[
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",
    "GIT_OBJECT_DIRECTORY",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX",
    "GIT_SHALLOW_FILE",
    "GIT_COMMON_DIR",
    "GIT_NAMESPACE",
    "GIT_CEILING_DIRECTORIES",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
];

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectGitInfo {
    pub repository_root: String,
    pub current_branch: Option<String>,
    pub head_commit: Option<String>,
    pub branches: Vec<String>,
}

pub async fn project_git_info(project_path: String) -> Result<Option<ProjectGitInfo>> {
    let Some(root) = repository_root(project_path).await? else {
        return Ok(None);
    };
    read_info(&root).await.map(Some)
}

pub async fn switch_project_branch(project_path: String, branch: String) -> Result<ProjectGitInfo> {
    let root = repository_root(project_path)
        .await?
        .context("Project is not in a Git repository")?;
    let info = read_info(&root).await?;
    // Only an exact, existing local ref can be selected. Never guess a remote branch,
    // treat a revision as a branch, or let a name become an option.
    if branch.starts_with('-') || !info.branches.contains(&branch) {
        bail!("Unknown local Git branch: {branch}");
    }
    git(&root, &["switch", "--no-guess", "--", &branch])
        .await?
        .success("Switch Git branch")?;
    read_info(&root).await
}

async fn repository_root(project_path: String) -> Result<Option<PathBuf>> {
    tokio::task::spawn_blocking(move || {
        let project = PathBuf::from(project_path)
            .canonicalize()
            .context("Project folder does not exist")?;
        if !project.is_dir() {
            bail!("Project root must be a directory");
        }
        for ancestor in project.ancestors() {
            match std::fs::metadata(ancestor.join(".git")) {
                Ok(metadata) if metadata.is_dir() || metadata.is_file() => {
                    return Ok(Some(ancestor.to_path_buf()));
                }
                Ok(_) => bail!("Unsupported Git metadata entry"),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error).context("Read project Git metadata"),
            }
        }
        Ok(None)
    })
    .await?
}

async fn read_info(root: &Path) -> Result<ProjectGitInfo> {
    // Explicit metadata and worktree paths also support .git files used by worktrees
    // and submodules, and prevent ambient GIT_DIR/GIT_WORK_TREE from redirecting Git.
    git(root, &["rev-parse", "--show-toplevel"])
        .await?
        .success("Read Git repository")?;
    let branch = git(root, &["symbolic-ref", "--quiet", "HEAD"]).await?;
    let current_branch = if branch.status.success() {
        Some(
            branch
                .stdout
                .trim_end_matches(['\r', '\n'])
                .strip_prefix("refs/heads/")
                .context("Git HEAD does not refer to a local branch")?
                .to_owned(),
        )
    } else if branch.status.code() == Some(1) {
        None // Detached HEAD.
    } else {
        branch.success("Read current Git branch")?;
        unreachable!()
    };
    let head = git(root, &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]).await?;
    let head_commit = if head.status.success() {
        Some(head.stdout.trim().to_owned())
    } else if head.status.code() == Some(1) && current_branch.is_some() {
        None // A newly initialized branch has no commit yet.
    } else {
        head.success("Read Git HEAD")?;
        unreachable!()
    };
    let branches = git(
        root,
        &["for-each-ref", "--format=%(refname:strip=2)", "refs/heads/"],
    )
    .await?
    .success("List local Git branches")?
    .lines()
    .map(str::to_owned)
    .collect();
    Ok(ProjectGitInfo {
        repository_root: root.to_string_lossy().into_owned(),
        current_branch,
        head_commit,
        branches,
    })
}

struct GitOutput {
    status: ExitStatus,
    stdout: String,
    stderr: String,
}

impl GitOutput {
    fn success(self, action: &str) -> Result<String> {
        if !self.status.success() {
            bail!("{action}: {}", self.stderr.trim());
        }
        Ok(self.stdout)
    }
}

async fn git(root: &Path, args: &[&str]) -> Result<GitOutput> {
    // Use an empty, absolute hooks directory on every platform. No user/repository
    // post-checkout hooks or fsmonitor hooks run as a side effect of the picker.
    let hooks = tempfile::tempdir().context("Create empty Git hooks directory")?;
    let mut arguments = vec![
        "--no-pager".into(),
        "--no-optional-locks".into(),
        "-c".into(),
        format!("core.hooksPath={}", git_path(hooks.path())),
        "-c".into(),
        "core.fsmonitor=false".into(),
        "--git-dir".into(),
        git_path(&root.join(".git")),
        "--work-tree".into(),
        git_path(root),
    ];
    arguments.extend(args.iter().map(|arg| (*arg).to_owned()));
    let environment = HashMap::from([
        ("GIT_TERMINAL_PROMPT".into(), "0".into()),
        ("LC_ALL".into(), "C".into()),
    ]);
    let mut process = OwnedProcess::spawn_with_env_removed(
        Path::new("git"),
        &arguments,
        Some(root),
        &environment,
        REPOSITORY_ENV,
    )?;
    process.stdin.take();
    let stdout = process.stdout.take().context("Git stdout unavailable")?;
    let stderr = process.stderr.take().context("Git stderr unavailable")?;
    let operation = async {
        let (stdout, stderr, status) = tokio::try_join!(
            read_output(stdout, OUTPUT_LIMIT),
            read_output(stderr, ERROR_LIMIT),
            process.wait(),
        )?;
        Ok::<_, anyhow::Error>(GitOutput {
            status,
            stdout,
            stderr,
        })
    };
    match tokio::time::timeout(COMMAND_TIMEOUT, operation).await {
        Ok(result) => result,
        Err(_) => {
            process.terminate(Duration::from_secs(2)).await?;
            bail!("Git command timed out");
        }
    }
}

// Rust canonicalization uses Windows verbatim paths, which Git does not accept
// in --git-dir/--work-tree. Keep canonical paths for filesystem access and API
// results; convert only command arguments, including verbatim UNC shares.
fn git_path(path: &Path) -> String {
    let path = path.to_string_lossy();
    if let Some(share) = path.strip_prefix(r"\\?\UNC\") {
        return format!(r"\\{share}");
    }
    if let Some(drive) = path.strip_prefix(r"\\?\") {
        let bytes = drive.as_bytes();
        if bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && matches!(bytes[2], b'\\' | b'/')
        {
            return drive.to_owned();
        }
    }
    path.into_owned()
}

async fn read_output(reader: impl AsyncRead + Unpin, limit: usize) -> Result<String> {
    let mut bytes = Vec::new();
    reader
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .await?;
    if bytes.len() > limit {
        bail!("Git command output exceeds limit");
    }
    String::from_utf8(bytes).context("Git command returned invalid UTF-8")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, process::Command};

    #[test]
    fn git_arguments_convert_verbatim_drive_and_unc_paths_only() {
        for (input, expected) in [
            (r"\\?\C:\项目\repo\.git", r"C:\项目\repo\.git"),
            (
                r"\\?\UNC\server\share\项目\repo",
                r"\\server\share\项目\repo",
            ),
            (r"C:\project\repo", r"C:\project\repo"),
            (r"\\server\share\repo", r"\\server\share\repo"),
            ("/tmp/project/repo", "/tmp/project/repo"),
            (r"\\?\Volume{example}\repo", r"\\?\Volume{example}\repo"),
        ] {
            assert_eq!(git_path(Path::new(input)), expected);
        }
    }

    struct Repository(tempfile::TempDir);

    impl Repository {
        fn new() -> Self {
            let repo = Self(tempfile::tempdir().unwrap());
            repo.run(&["init", "-b", "main"]);
            repo
        }

        fn path(&self) -> &Path {
            self.0.path()
        }

        fn project(&self) -> String {
            self.path().to_string_lossy().into_owned()
        }

        fn run(&self, args: &[&str]) -> String {
            let output = Command::new("git")
                .args([
                    "-c",
                    "user.name=Flutter Dev Test",
                    "-c",
                    "user.email=test@example.invalid",
                ])
                .args(["-c", "commit.gpgSign=false", "-c", "core.hooksPath="])
                .args(args)
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .env(
                    "GIT_CONFIG_GLOBAL",
                    if cfg!(windows) { "NUL" } else { "/dev/null" },
                )
                .current_dir(self.path())
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8(output.stdout).unwrap().trim().to_owned()
        }

        fn commit(&self) {
            self.run(&["add", "."]);
            self.run(&["commit", "--allow-empty", "-m", "test"]);
        }
    }

    #[tokio::test]
    async fn recognizes_repository_and_projects_inside_it() {
        let repo = Repository::new();
        repo.commit();
        repo.run(&["branch", "feature/nested"]);
        fs::create_dir_all(repo.path().join("apps/sample")).unwrap();
        let direct = project_git_info(repo.project()).await.unwrap().unwrap();
        let nested = project_git_info(
            repo.path()
                .join("apps/sample")
                .to_string_lossy()
                .into_owned(),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(direct, nested);
        assert_eq!(
            direct.repository_root,
            repo.path().canonicalize().unwrap().to_string_lossy()
        );
        assert_eq!(direct.current_branch.as_deref(), Some("main"));
        assert_eq!(direct.branches, ["feature/nested", "main"]);
        assert_eq!(
            direct.head_commit.as_deref(),
            Some(repo.run(&["rev-parse", "HEAD"]).as_str())
        );
    }

    #[tokio::test]
    async fn plain_directories_have_no_branch_picker_and_missing_paths_report_errors() {
        let folder = tempfile::tempdir().unwrap();
        assert!(
            project_git_info(folder.path().to_string_lossy().into_owned())
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            project_git_info(folder.path().join("missing").to_string_lossy().into_owned())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn unborn_branch_is_reported_without_a_commit_or_switch_targets() {
        let repo = Repository::new();
        let info = project_git_info(repo.project()).await.unwrap().unwrap();
        assert_eq!(info.current_branch.as_deref(), Some("main"));
        assert!(info.head_commit.is_none());
        assert!(info.branches.is_empty());
        assert!(switch_project_branch(repo.project(), "missing".into())
            .await
            .is_err());
    }

    #[tokio::test]
    async fn switches_existing_branches_and_recovers_from_detached_head() {
        let repo = Repository::new();
        repo.commit();
        repo.run(&["branch", "feature/nested"]);
        repo.run(&["checkout", "--detach"]);
        let info = project_git_info(repo.project()).await.unwrap().unwrap();
        assert!(info.current_branch.is_none());
        assert!(info.head_commit.is_some());
        let switched = switch_project_branch(repo.project(), "feature/nested".into())
            .await
            .unwrap();
        assert_eq!(switched.current_branch.as_deref(), Some("feature/nested"));
        assert_eq!(
            repo.run(&["symbolic-ref", "--short", "HEAD"]),
            "feature/nested"
        );
    }

    #[tokio::test]
    async fn worktree_git_files_are_recognized_and_checked_out_branches_are_not_forced() {
        let repo = Repository::new();
        repo.commit();
        let other = tempfile::tempdir().unwrap();
        let path = other.path().join("worktree");
        repo.run(&["worktree", "add", "-b", "work", path.to_str().unwrap()]);
        assert!(path.join(".git").is_file());
        let info = project_git_info(path.to_string_lossy().into_owned())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(info.current_branch.as_deref(), Some("work"));
        assert!(
            switch_project_branch(path.to_string_lossy().into_owned(), "main".into())
                .await
                .is_err()
        );
        assert_eq!(repo.run(&["symbolic-ref", "--short", "HEAD"]), "main");
    }

    #[tokio::test]
    async fn conflicting_dirty_files_are_preserved_and_switch_reports_git_error() {
        let repo = Repository::new();
        fs::write(repo.path().join("tracked.txt"), "main version").unwrap();
        repo.commit();
        repo.run(&["checkout", "-b", "feature"]);
        fs::write(repo.path().join("tracked.txt"), "feature version").unwrap();
        repo.commit();
        repo.run(&["checkout", "main"]);
        fs::write(repo.path().join("tracked.txt"), "unsaved work").unwrap();
        let error = switch_project_branch(repo.project(), "feature".into())
            .await
            .unwrap_err();
        assert!(error.to_string().contains("overwritten"), "{error}");
        assert_eq!(
            fs::read_to_string(repo.path().join("tracked.txt")).unwrap(),
            "unsaved work"
        );
        assert_eq!(repo.run(&["symbolic-ref", "--short", "HEAD"]), "main");
    }

    #[tokio::test]
    async fn rejects_missing_remote_only_and_option_shaped_branch_names() {
        let repo = Repository::new();
        repo.commit();
        repo.run(&["update-ref", "refs/remotes/origin/remote-only", "HEAD"]);
        for branch in [
            "missing",
            "remote-only",
            "--discard-changes",
            "main;touch injected",
            "main\n--force",
        ] {
            assert!(switch_project_branch(repo.project(), branch.into())
                .await
                .is_err());
            assert_eq!(repo.run(&["symbolic-ref", "--short", "HEAD"]), "main");
        }
        assert!(!repo.path().join("injected").exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn branch_switch_does_not_run_repository_hooks() {
        use std::os::unix::fs::PermissionsExt;
        let repo = Repository::new();
        repo.commit();
        repo.run(&["branch", "feature"]);
        let hook = repo.path().join(".git/hooks/post-checkout");
        fs::write(&hook, "#!/bin/sh\ntouch hook-ran\nexit 1\n").unwrap();
        fs::set_permissions(&hook, fs::Permissions::from_mode(0o755)).unwrap();
        switch_project_branch(repo.project(), "feature".into())
            .await
            .unwrap();
        assert!(!repo.path().join("hook-ran").exists());
    }

    #[tokio::test]
    async fn inherited_git_environment_does_not_redirect_branch_switch_or_index() {
        const CHILD_PROJECT: &str = "FLUTTER_DEV_GIT_ENV_TEST_PROJECT";
        if let Some(project) = std::env::var_os(CHILD_PROJECT) {
            let info =
                switch_project_branch(project.to_string_lossy().into_owned(), "feature".into())
                    .await
                    .unwrap();
            assert_eq!(info.current_branch.as_deref(), Some("feature"));
            return;
        }

        let repo = Repository::new();
        fs::write(repo.path().join("tracked.txt"), "main version").unwrap();
        repo.commit();
        repo.run(&["checkout", "-b", "feature"]);
        fs::write(repo.path().join("tracked.txt"), "feature version").unwrap();
        repo.commit();
        repo.run(&["checkout", "main"]);
        let foreign = Repository::new();
        foreign.commit();
        let alternate_index = foreign.path().join("alternate-index");
        fs::copy(repo.path().join(".git/index"), &alternate_index).unwrap();
        let original_alternate_index = fs::read(&alternate_index).unwrap();
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "project_git::tests::inherited_git_environment_does_not_redirect_branch_switch_or_index",
                "--nocapture",
            ])
            .env(CHILD_PROJECT, repo.path())
            .env("GIT_DIR", foreign.path().join(".git"))
            .env("GIT_WORK_TREE", foreign.path())
            .env("GIT_COMMON_DIR", foreign.path().join(".git"))
            .env("GIT_INDEX_FILE", &alternate_index)
            .env("GIT_OBJECT_DIRECTORY", foreign.path().join(".git/objects"))
            .env("GIT_ALTERNATE_OBJECT_DIRECTORIES", foreign.path().join("missing-objects"))
            .env("GIT_NAMESPACE", "foreign-namespace")
            .env("GIT_SHALLOW_FILE", foreign.path().join("missing-shallow"))
            .env("GIT_CONFIG_PARAMETERS", "invalid config parameters")
            .env("GIT_CONFIG_COUNT", "1")
            .env("GIT_CONFIG_KEY_0", "core.bare")
            .env("GIT_CONFIG_VALUE_0", "true")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "child test failed: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(repo.run(&["symbolic-ref", "--short", "HEAD"]), "feature");
        assert_eq!(
            fs::read_to_string(repo.path().join("tracked.txt")).unwrap(),
            "feature version"
        );
        assert!(repo.run(&["diff", "--cached", "--name-only"]).is_empty());
        assert!(repo.run(&["diff", "--name-only"]).is_empty());
        assert_eq!(
            fs::read(&alternate_index).unwrap(),
            original_alternate_index
        );
        assert_eq!(foreign.run(&["symbolic-ref", "--short", "HEAD"]), "main");
    }

    #[tokio::test]
    async fn command_output_is_bounded() {
        assert_eq!(read_output(&b"four"[..], 4).await.unwrap(), "four");
        assert!(read_output(&b"exceeds"[..], 4).await.is_err());
    }
}
