use anyhow::{Context, Result};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::{ExitStatus, Stdio},
    time::Duration,
};
use tokio::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command};

use crate::sdk::SdkInfo;

pub fn flutter_program(sdk: &SdkInfo) -> PathBuf {
    Path::new(&sdk.path).join("bin").join(if cfg!(windows) {
        "flutter.bat"
    } else {
        "flutter"
    })
}

/// Owns only the process tree created by this command. Never locates processes by name.
pub struct OwnedProcess {
    child: Child,
    pid: Option<u32>,
    pub stdin: Option<ChildStdin>,
    pub stdout: Option<ChildStdout>,
    pub stderr: Option<ChildStderr>,
    #[cfg(windows)]
    job: windows_job::Job,
}

impl OwnedProcess {
    pub fn spawn(
        program: &Path,
        args: &[String],
        cwd: Option<&Path>,
        env: &HashMap<String, String>,
    ) -> Result<Self> {
        Self::spawn_with_env_removed(program, args, cwd, env, &[])
    }

    /// Removes selected inherited variables for tools whose repository context must
    /// not leak from the process that launched the workbench. Other callers retain
    /// the normal inherited environment through `spawn`.
    pub(crate) fn spawn_with_env_removed(
        program: &Path,
        args: &[String],
        cwd: Option<&Path>,
        env: &HashMap<String, String>,
        removed_env: &[&str],
    ) -> Result<Self> {
        let mut command = command(program, args)?;
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        configure_environment(&mut command, env)?;
        for variable in removed_env {
            command.env_remove(variable);
        }
        if let Some(cwd) = cwd {
            #[cfg(windows)]
            if is_batch_program(program) {
                command.current_dir(command_path(cwd));
            } else {
                command.current_dir(cwd);
            }
            #[cfg(not(windows))]
            command.current_dir(cwd);
        }
        #[cfg(unix)]
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        #[cfg(windows)]
        // Keep the initial thread suspended until it belongs to the job, so early SDK
        // descendants cannot escape ownership between CreateProcess and job assignment.
        command.creation_flags(0x00000200 | 0x00000004); // NEW_PROCESS_GROUP | SUSPENDED
        let mut child = command
            .spawn()
            .with_context(|| format!("Failed to start {}", program.display()))?;
        let pid = child.id();
        #[cfg(windows)]
        let job = match windows_job::Job::assign(pid.context("Missing spawned process ID")?) {
            Ok(job) => job,
            Err(error) => {
                let _ = child.start_kill();
                return Err(error);
            }
        };
        Ok(Self {
            stdin: child.stdin.take(),
            stdout: child.stdout.take(),
            stderr: child.stderr.take(),
            child,
            pid,
            #[cfg(windows)]
            job,
        })
    }

    pub fn id(&self) -> Option<u32> {
        self.pid
    }

    pub async fn wait(&mut self) -> Result<ExitStatus> {
        let status = self.child.wait().await?;
        self.kill_tree();
        self.pid = None;
        Ok(status)
    }

    /// Call the protocol's disconnect/shutdown first, then use this as its bounded fallback.
    pub async fn terminate(&mut self, timeout: Duration) -> Result<()> {
        self.stdin.take();
        #[cfg(unix)]
        if let Some(pid) = self.pid {
            unsafe {
                libc::kill(-(pid as i32), libc::SIGTERM);
            }
        }
        // Windows adapters first receive protocol shutdown/EOF; their Job covers forced cleanup.
        match tokio::time::timeout(timeout, self.child.wait()).await {
            Ok(result) => {
                result?;
            }
            Err(_) => {
                self.kill_tree();
                self.child.start_kill().ok();
                self.child.wait().await?;
            }
        }
        self.kill_tree();
        self.pid = None;
        Ok(())
    }

    fn kill_tree(&mut self) {
        #[cfg(unix)]
        if let Some(pid) = self.pid {
            unsafe {
                libc::kill(-(pid as i32), libc::SIGKILL);
            }
        }
        #[cfg(windows)]
        self.job.terminate();
    }
}

impl Drop for OwnedProcess {
    fn drop(&mut self) {
        self.kill_tree();
    }
}

/// Editors are handed off to the user and can outlive the workbench. Success
/// confirms spawning and no failure observed during the handoff window; it does
/// not claim that a long-lived GUI has finished opening the requested file.
/// Keep argument-array execution and Windows batch checks without owning its tree.
pub(crate) async fn launch_editor(program: &Path, args: &[String]) -> Result<()> {
    observe_editor_handoff(spawn_editor(program, args)?).await
}

fn spawn_editor(program: &Path, args: &[String]) -> Result<Child> {
    let mut command = command(program, args)?;
    configure_environment(&mut command, &HashMap::new())?;
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("Failed to start editor {}", program.display()))
}

async fn observe_editor_handoff(mut child: Child) -> Result<()> {
    use tokio::io::AsyncReadExt;
    let stderr = child.stderr.take();
    let output = tokio::spawn(async move {
        let mut captured = Vec::new();
        if let Some(mut stream) = stderr {
            let mut buffer = [0u8; 4096];
            while let Ok(length) = stream.read(&mut buffer).await {
                if length == 0 {
                    break;
                }
                let remaining = 16384usize.saturating_sub(captured.len());
                captured.extend_from_slice(&buffer[..length.min(remaining)]);
            }
        }
        captured
    });
    match tokio::time::timeout(Duration::from_secs(2), child.wait()).await {
        Ok(result) => {
            let status = result.context("Wait for editor handoff")?;
            if !status.success() {
                let output = tokio::time::timeout(Duration::from_millis(250), output)
                    .await
                    .ok()
                    .and_then(Result::ok)
                    .unwrap_or_default();
                anyhow::bail!(
                    "Editor exited unsuccessfully ({status}): {}",
                    String::from_utf8_lossy(&output).trim()
                );
            }
        }
        Err(_) => {
            tokio::spawn(async move {
                let _ = child.wait().await;
                let _ = output.await;
            });
        }
    }
    Ok(())
}

#[cfg(windows)]
fn is_batch_program(program: &Path) -> bool {
    program.extension().is_some_and(|ext| {
        ext.to_string_lossy().eq_ignore_ascii_case("bat")
            || ext.to_string_lossy().eq_ignore_ascii_case("cmd")
    })
}

fn command(program: &Path, args: &[String]) -> Result<Command> {
    #[cfg(windows)]
    if is_batch_program(program) {
        use std::os::windows::process::CommandExt;
        // cmd performs expansion even inside quotes. Reject expandable shell syntax rather than
        // silently allowing launch arguments to become commands or environment substitutions.
        let values: Vec<_> = std::iter::once(program.to_str().context("Invalid executable path")?)
            .chain(args.iter().map(String::as_str))
            .collect();
        if values
            .iter()
            .any(|value| value.contains(['"', '%', '!', '\r', '\n', '&', '|', '<', '>', '^']))
        {
            anyhow::bail!("Windows batch arguments contain unsupported shell characters");
        }
        let quoted = values
            .iter()
            .map(|value| format!("\"{}\"", command_path(Path::new(value))))
            .collect::<Vec<_>>()
            .join(" ");
        let mut command = Command::new("cmd.exe");
        command.args(["/D", "/V:OFF", "/S", "/C"]);
        command.as_std_mut().raw_arg(format!("\"{quoted}\""));
        return Ok(command);
    }
    let mut command = Command::new(program);
    command.args(args);
    Ok(command)
}

// Git and cmd.exe do not accept Rust's canonical Windows verbatim paths.
// Convert external command paths only; filesystem paths and API results retain
// their canonical representation. Non-path arguments remain unchanged.
pub(crate) fn command_path(path: &Path) -> String {
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

fn configure_environment(command: &mut Command, env: &HashMap<String, String>) -> Result<()> {
    command.envs(env);
    #[cfg(target_os = "macos")]
    if !env.contains_key("PATH") {
        // Finder-launched apps inherit a minimal PATH. Preserve terminal/custom tool
        // precedence while adding installed Homebrew tools for every Flutter subprocess.
        let prefix = env
            .get("HOMEBREW_PREFIX")
            .map(std::ffi::OsString::from)
            .or_else(|| std::env::var_os("HOMEBREW_PREFIX"));
        command.env(
            "PATH",
            complete_macos_path(
                std::env::var_os("PATH").as_deref(),
                &homebrew_path_candidates(prefix.as_deref()),
            )?,
        );
    }
    Ok(())
}

#[cfg(any(target_os = "macos", all(test, unix)))]
fn homebrew_path_candidates(prefix: Option<&std::ffi::OsStr>) -> Vec<PathBuf> {
    prefix
        .map(PathBuf::from)
        .into_iter()
        .filter(|path| path.is_absolute() && path.is_dir())
        .chain([PathBuf::from("/opt/homebrew"), PathBuf::from("/usr/local")])
        .flat_map(|prefix| {
            [
                prefix.join("bin"),
                prefix.join("sbin"),
                prefix.join("opt/ruby/bin"),
            ]
        })
        .collect()
}

#[cfg(any(target_os = "macos", all(test, unix)))]
fn complete_macos_path(
    inherited: Option<&std::ffi::OsStr>,
    candidates: &[PathBuf],
) -> Result<std::ffi::OsString> {
    let inherited = inherited.filter(|path| !path.is_empty());
    let paths = inherited
        .map(|path| std::env::split_paths(path).collect::<Vec<_>>())
        .unwrap_or_else(|| {
            ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                .into_iter()
                .map(PathBuf::from)
                .collect()
        });
    let mut unique = Vec::new();
    for path in paths
        .into_iter()
        .chain(candidates.iter().filter(|path| path.is_dir()).cloned())
    {
        if !unique.contains(&path) {
            unique.push(path);
        }
    }
    std::env::join_paths(unique).context("Configure Flutter subprocess PATH")
}

#[cfg(windows)]
mod windows_job {
    use anyhow::{Context, Result};
    use std::ffi::c_void;
    #[repr(C)]
    #[derive(Default)]
    struct BasicLimits {
        process_time: i64,
        job_time: i64,
        flags: u32,
        minimum_working_set: usize,
        maximum_working_set: usize,
        active_process_limit: u32,
        affinity: usize,
        priority: u32,
        scheduling: u32,
    }
    #[repr(C)]
    #[derive(Default)]
    struct IoCounters {
        read_count: u64,
        write_count: u64,
        other_count: u64,
        read_bytes: u64,
        write_bytes: u64,
        other_bytes: u64,
    }
    #[repr(C)]
    #[derive(Default)]
    struct ExtendedLimits {
        basic: BasicLimits,
        io: IoCounters,
        process_memory: usize,
        job_memory: usize,
        peak_process_memory: usize,
        peak_job_memory: usize,
    }
    #[repr(C)]
    #[derive(Default)]
    struct ThreadEntry {
        size: u32,
        usage: u32,
        thread_id: u32,
        owner_pid: u32,
        base_priority: i32,
        delta_priority: i32,
        flags: u32,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> isize;
        fn SetInformationJobObject(job: isize, class: u32, info: *const c_void, length: u32)
            -> i32;
        fn OpenProcess(access: u32, inherit: i32, pid: u32) -> isize;
        fn AssignProcessToJobObject(job: isize, process: isize) -> i32;
        fn TerminateJobObject(job: isize, code: u32) -> i32;
        fn CreateToolhelp32Snapshot(flags: u32, pid: u32) -> isize;
        fn Thread32First(snapshot: isize, entry: *mut ThreadEntry) -> i32;
        fn Thread32Next(snapshot: isize, entry: *mut ThreadEntry) -> i32;
        fn OpenThread(access: u32, inherit: i32, thread_id: u32) -> isize;
        fn ResumeThread(thread: isize) -> u32;
        fn CloseHandle(handle: isize) -> i32;
    }
    pub struct Job(isize);
    impl Job {
        pub fn assign(pid: u32) -> Result<Self> {
            unsafe {
                let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if handle == 0 {
                    return Err(std::io::Error::last_os_error())
                        .context("Create Windows process job");
                }
                let job = Self(handle);
                let mut limits = ExtendedLimits::default();
                limits.basic.flags = 0x00002000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                if SetInformationJobObject(
                    handle,
                    9,
                    &limits as *const _ as *const c_void,
                    std::mem::size_of::<ExtendedLimits>() as u32,
                ) == 0
                {
                    return Err(std::io::Error::last_os_error())
                        .context("Configure Windows process job");
                }
                let process = OpenProcess(0x0100 | 0x0001, 0, pid);
                if process == 0 {
                    return Err(std::io::Error::last_os_error())
                        .context("Open owned Windows process");
                }
                let assigned = AssignProcessToJobObject(handle, process);
                let error = std::io::Error::last_os_error();
                CloseHandle(process);
                if assigned == 0 {
                    return Err(error).context("Assign owned process to Windows job");
                }
                resume_owned_thread(pid)?;
                Ok(job)
            }
        }
        pub fn terminate(&self) {
            unsafe {
                TerminateJobObject(self.0, 1);
            }
        }
    }
    impl Drop for Job {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }

    unsafe fn resume_owned_thread(pid: u32) -> Result<()> {
        let snapshot = CreateToolhelp32Snapshot(0x00000004, 0); // SNAPTHREAD
        if snapshot == -1 {
            return Err(std::io::Error::last_os_error()).context("Read owned Windows thread");
        }
        let mut entry = ThreadEntry {
            size: std::mem::size_of::<ThreadEntry>() as u32,
            ..ThreadEntry::default()
        };
        let mut available = Thread32First(snapshot, &mut entry);
        let mut thread_id = None;
        while available != 0 {
            if entry.owner_pid == pid {
                thread_id = Some(entry.thread_id);
                break;
            }
            available = Thread32Next(snapshot, &mut entry);
        }
        CloseHandle(snapshot);
        let thread_id = thread_id.context("Suspended owned process has no initial thread")?;
        let thread = OpenThread(0x0002, 0, thread_id); // THREAD_SUSPEND_RESUME
        if thread == 0 {
            return Err(std::io::Error::last_os_error()).context("Open owned Windows thread");
        }
        let result = ResumeThread(thread);
        let error = std::io::Error::last_os_error();
        CloseHandle(thread);
        if result == u32::MAX {
            return Err(error).context("Resume owned Windows process");
        }
        Ok(())
    }
}

#[cfg(all(test, windows))]
mod windows_tests {
    use super::*;
    use std::fs;
    use tokio::io::AsyncReadExt;

    #[tokio::test]
    async fn canonical_batch_paths_and_working_directory_preserve_output_and_exit_status() {
        let fixture = tempfile::tempdir().unwrap();
        let root = fixture.path().join("batch 空格");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("relative.txt"), "fixture").unwrap();
        let input = root.join("参数 file.txt");
        fs::write(&input, "fixture").unwrap();
        let cwd = root.canonicalize().unwrap();
        let args = [
            input.canonicalize().unwrap().to_string_lossy().into_owned(),
            "literal/name=value".into(),
        ];
        for extension in ["bat", "cmd"] {
            let program = root.join(format!("probe script.{extension}"));
            fs::write(
                &program,
                "@echo off\r\nif not exist \"%~1\" exit /b 21\r\nif not exist \"relative.txt\" exit /b 22\r\necho path-ok\r\necho %~2\r\nexit /b 7\r\n",
            )
            .unwrap();
            let mut process = OwnedProcess::spawn(
                &program.canonicalize().unwrap(),
                &args,
                Some(&cwd),
                &HashMap::new(),
            )
            .unwrap();
            process.stdin.take();
            let mut stdout = process.stdout.take().unwrap();
            let (output, status) = tokio::time::timeout(Duration::from_secs(15), async {
                tokio::try_join!(
                    async {
                        let mut output = String::new();
                        stdout.read_to_string(&mut output).await?;
                        Ok::<_, std::io::Error>(output)
                    },
                    async { process.wait().await.map_err(std::io::Error::other) },
                )
            })
            .await
            .unwrap()
            .unwrap();
            assert_eq!(status.code(), Some(7));
            assert_eq!(
                output.lines().collect::<Vec<_>>(),
                ["path-ok", "literal/name=value"]
            );
        }
    }

    #[test]
    fn batch_commands_still_reject_shell_expansion_and_metacharacters() {
        let program = Path::new(r"\\?\C:\SDK folder\flutter.bat");
        for character in ['"', '%', '!', '\r', '\n', '&', '|', '<', '>', '^'] {
            let error = command(program, &[format!("unsafe{character}value")])
                .err()
                .unwrap();
            assert!(error.to_string().contains("unsupported shell characters"));
        }
        assert!(command(Path::new(r"C:\unsafe&folder\flutter.bat"), &[]).is_err());
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, BufReader};

    // The interpreter can take several seconds to start under a parallel full
    // suite. Readiness is an explicit fixture condition, independent of the
    // production handoff observation window.
    async fn editor_ready(child: &mut Child, pid_file: &Path) -> i32 {
        let ready = tokio::time::timeout(Duration::from_secs(15), async {
            loop {
                if let Ok(pid) = std::fs::read_to_string(pid_file) {
                    if let Ok(pid) = pid.parse::<i32>() {
                        return pid;
                    }
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await;
        if ready.is_err() {
            let _ = child.kill().await;
        }
        ready.expect("editor fixture did not report readiness")
    }

    struct FixtureEditor(i32);
    impl Drop for FixtureEditor {
        fn drop(&mut self) {
            // Only the single process spawned by the fixture is addressed.
            unsafe {
                libc::kill(self.0, libc::SIGTERM);
            }
        }
    }

    #[tokio::test]
    async fn editor_handoff_reports_command_failure_without_shell_interpolation() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let program = root.path().join("editor");
        let pid_file = root.path().join("editor.pid");
        std::fs::write(&program,
            "#!/usr/bin/env python3\nimport os,sys\nopen(sys.argv[1],'w').write(str(os.getpid()))\nprint(sys.argv[2],file=sys.stderr)\nsys.exit(7)\n").unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut child = spawn_editor(
            &program,
            &[
                pid_file.to_string_lossy().into_owned(),
                "literal $(do-not-run)".into(),
            ],
        )
        .unwrap();
        editor_ready(&mut child, &pid_file).await;
        // Waiting for this quick-exit fixture, rather than guessing when Python
        // has started, makes the unsuccessful-exit branch deterministic.
        let status = tokio::time::timeout(Duration::from_secs(15), child.wait())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(status.code(), Some(7));
        let error = observe_editor_handoff(child).await.unwrap_err();
        assert!(error.to_string().contains("literal $(do-not-run)"));
        assert!(error.to_string().contains("7"));
    }

    #[tokio::test]
    async fn long_lived_editor_is_handed_off_without_terminating_it() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let program = root.path().join("editor");
        let pid_file = root.path().join("editor.pid");
        std::fs::write(&program, "#!/usr/bin/env python3\nimport os,sys,time\nopen(sys.argv[1],'w').write(str(os.getpid()))\ntime.sleep(60)\n").unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut child = spawn_editor(&program, &[pid_file.to_string_lossy().into_owned()]).unwrap();
        let pid = editor_ready(&mut child, &pid_file).await;
        let _fixture = FixtureEditor(pid);
        observe_editor_handoff(child).await.unwrap();
        assert_eq!(unsafe { libc::kill(pid, 0) }, 0);
    }

    #[test]
    fn gui_path_adds_installed_tools_after_inherited_paths() {
        let directory = tempfile::tempdir().unwrap();
        let bin = directory.path().join("bin");
        let sbin = directory.path().join("sbin");
        let ruby = directory.path().join("opt/ruby/bin");
        for path in [&bin, &sbin, &ruby] {
            std::fs::create_dir_all(path).unwrap();
        }
        let inherited = std::ffi::OsStr::new("/usr/bin:/bin:/usr/sbin:/sbin");
        let path = complete_macos_path(
            Some(inherited),
            &[
                bin.clone(),
                sbin.clone(),
                ruby.clone(),
                directory.path().join("missing"),
            ],
        )
        .unwrap();
        assert_eq!(
            std::env::split_paths(&path).collect::<Vec<_>>(),
            vec![
                PathBuf::from("/usr/bin"),
                PathBuf::from("/bin"),
                PathBuf::from("/usr/sbin"),
                PathBuf::from("/sbin"),
                bin,
                sbin,
                ruby,
            ]
        );
    }

    #[test]
    fn inherited_tool_order_and_paths_with_spaces_are_preserved_and_deduplicated() {
        let directory = tempfile::tempdir().unwrap();
        let custom = directory.path().join("custom tools");
        let brew = directory.path().join("brew tools");
        std::fs::create_dir(&custom).unwrap();
        std::fs::create_dir(&brew).unwrap();
        let inherited = std::env::join_paths([&custom, &brew, &custom]).unwrap();
        let path = complete_macos_path(Some(&inherited), &[brew.clone(), custom.clone()]).unwrap();
        assert_eq!(
            std::env::split_paths(&path).collect::<Vec<_>>(),
            vec![custom, brew]
        );
    }

    #[test]
    fn missing_or_empty_path_receives_system_defaults() {
        for inherited in [None, Some(std::ffi::OsStr::new(""))] {
            let path = complete_macos_path(inherited, &[]).unwrap();
            assert_eq!(path, "/usr/bin:/bin:/usr/sbin:/sbin");
        }
    }

    #[test]
    fn custom_homebrew_prefix_requires_an_existing_absolute_directory() {
        let directory = tempfile::tempdir().unwrap();
        let candidates = homebrew_path_candidates(Some(directory.path().as_os_str()));
        assert_eq!(candidates[0], directory.path().join("bin"));
        assert_eq!(candidates[1], directory.path().join("sbin"));
        assert_eq!(candidates[2], directory.path().join("opt/ruby/bin"));
        let defaults = homebrew_path_candidates(None);
        assert_eq!(
            homebrew_path_candidates(Some(std::ffi::OsStr::new("relative"))),
            defaults
        );
        assert_eq!(
            homebrew_path_candidates(Some(directory.path().join("missing").as_os_str())),
            defaults
        );
    }

    #[test]
    fn explicit_path_and_other_environment_overrides_are_unchanged() {
        for explicit_path in ["", "/custom tools/bin:/usr/bin:/custom tools/bin"] {
            let env = HashMap::from([
                ("PATH".into(), explicit_path.into()),
                ("HOME".into(), "/custom home".into()),
                ("FLUTTER_DEV_ENV_TEST".into(), "value with spaces".into()),
            ]);
            let mut command = command(Path::new("/bin/sh"), &[]).unwrap();
            configure_environment(&mut command, &env).unwrap();
            let configured = command.as_std().get_envs().collect::<HashMap<_, _>>();
            for (name, value) in &env {
                assert_eq!(
                    configured.get(std::ffi::OsStr::new(name)),
                    Some(&Some(std::ffi::OsStr::new(value)))
                );
            }
        }
    }

    #[tokio::test]
    async fn completed_gui_path_is_visible_to_owned_process_and_its_child() {
        use std::os::unix::fs::PermissionsExt;
        use tokio::io::AsyncReadExt;
        let directory = tempfile::tempdir().unwrap();
        let bin = directory.path().join("Homebrew tools/bin");
        let ruby_bin = directory.path().join("Homebrew tools/opt/ruby/bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(&ruby_bin).unwrap();
        for (path, label) in [
            (bin.join("flutter-dev-test-pod"), "pod"),
            (bin.join("flutter-dev-test-brew"), "brew"),
            (ruby_bin.join("flutter-dev-test-ruby"), "ruby"),
        ] {
            std::fs::write(&path, format!("#!/bin/sh\nprintf '{label} found\\n'\n")).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let path = complete_macos_path(
            Some(std::ffi::OsStr::new("/usr/bin:/bin:/usr/sbin:/sbin")),
            &[bin, ruby_bin],
        )
        .unwrap();
        let mut process = OwnedProcess::spawn(
            Path::new("/bin/sh"),
            &[
                "-c".into(),
                "flutter-dev-test-pod && flutter-dev-test-brew && /bin/sh -c 'flutter-dev-test-ruby' && printf '%s\\n' \"$HOME\" \"$FLUTTER_DEV_ENV_TEST\"".into(),
            ],
            None,
            &HashMap::from([
                ("PATH".into(), path.into_string().unwrap()),
                ("HOME".into(), "/custom home".into()),
                ("FLUTTER_DEV_ENV_TEST".into(), "value with spaces".into()),
            ]),
        )
        .unwrap();
        let mut output = String::new();
        process
            .stdout
            .take()
            .unwrap()
            .read_to_string(&mut output)
            .await
            .unwrap();
        assert!(process.wait().await.unwrap().success());
        assert_eq!(
            output,
            "pod found\nbrew found\nruby found\n/custom home\nvalue with spaces\n"
        );
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn owned_process_discovers_tools_from_custom_homebrew_prefix() {
        use std::os::unix::fs::PermissionsExt;
        use tokio::io::AsyncReadExt;
        let directory = tempfile::tempdir().unwrap();
        let bin = directory.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        let tool = bin.join("flutter-dev-custom-homebrew-tool");
        std::fs::write(&tool, "#!/bin/sh\nprintf 'custom Homebrew found\\n'\n").unwrap();
        std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut process = OwnedProcess::spawn(
            Path::new("/bin/sh"),
            &["-c".into(), "flutter-dev-custom-homebrew-tool".into()],
            None,
            &HashMap::from([(
                "HOMEBREW_PREFIX".into(),
                directory.path().to_str().unwrap().into(),
            )]),
        )
        .unwrap();
        let mut output = String::new();
        process
            .stdout
            .take()
            .unwrap()
            .read_to_string(&mut output)
            .await
            .unwrap();
        assert!(process.wait().await.unwrap().success());
        assert_eq!(output, "custom Homebrew found\n");
    }

    #[tokio::test]
    async fn owned_tree_is_cleaned_and_other_process_is_untouched() {
        let mut unrelated = OwnedProcess::spawn(
            Path::new("/bin/sleep"),
            &["60".into()],
            None,
            &HashMap::new(),
        )
        .unwrap();
        let mut process = OwnedProcess::spawn(
            Path::new("/bin/sh"),
            &["-c".into(), "sleep 60 & echo $!; wait".into()],
            None,
            &HashMap::new(),
        )
        .unwrap();
        let mut output = BufReader::new(process.stdout.take().unwrap()).lines();
        let descendant = output
            .next_line()
            .await
            .unwrap()
            .unwrap()
            .parse::<i32>()
            .unwrap();
        let pgid = unsafe { libc::getpgid(descendant) };
        assert_eq!(pgid, process.id().unwrap() as i32);
        process.terminate(Duration::from_secs(1)).await.unwrap();
        assert!(process.id().is_none());
        // The descendant inherited stdout; EOF proves it released the pipe after tree cleanup.
        assert!(
            tokio::time::timeout(Duration::from_secs(2), output.next_line())
                .await
                .unwrap()
                .unwrap()
                .is_none()
        );
        assert_eq!(unsafe { libc::kill(unrelated.id().unwrap() as i32, 0) }, 0);
        assert_ne!(pgid, unsafe { libc::getpgrp() });
        unrelated.terminate(Duration::from_secs(1)).await.unwrap();
    }

    #[tokio::test]
    async fn no_shell_interpolation_for_arguments() {
        use tokio::io::AsyncReadExt;
        let mut process = OwnedProcess::spawn(
            Path::new("/bin/echo"),
            &["$(echo injected) path with spaces".into()],
            None,
            &HashMap::new(),
        )
        .unwrap();
        let mut text = String::new();
        process
            .stdout
            .take()
            .unwrap()
            .read_to_string(&mut text)
            .await
            .unwrap();
        process.wait().await.unwrap();
        assert_eq!(text, "$(echo injected) path with spaces\n");
    }
}
