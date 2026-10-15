use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashMap,
    path::Path,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    sync::{oneshot, Mutex, Notify},
    task::JoinHandle,
};

use crate::{
    process::OwnedProcess,
    session::{RunMode, Session, SessionSnapshot, SessionState},
};

const STARTUP_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_MACHINE_LINE: usize = 64 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DevToolsPage {
    pub url: String,
}

#[derive(Default)]
struct ServerSlot {
    epoch: AtomicU64,
    cancelled: Notify,
    server: Mutex<Option<DevToolsServer>>,
}

pub(crate) struct DevToolsManager {
    slots: Mutex<HashMap<String, Arc<ServerSlot>>>,
    startup_timeout: Duration,
}

impl Default for DevToolsManager {
    fn default() -> Self {
        Self {
            slots: Mutex::new(HashMap::new()),
            startup_timeout: STARTUP_TIMEOUT,
        }
    }
}

impl DevToolsManager {
    pub(crate) async fn open(&self, session: &Session, module: &str) -> Result<DevToolsPage> {
        let route = module_route(module)?;
        let snapshot = session.snapshot.lock().await.clone();
        validate_session(&snapshot, module)?;
        let (slot, epoch) = {
            let mut slots = self.slots.lock().await;
            let slot = slots
                .entry(snapshot.session_id.clone())
                .or_default()
                .clone();
            let epoch = slot.epoch.load(Ordering::Acquire);
            (slot, epoch)
        };
        let mut server = slot.server.lock().await;
        if slot.epoch.load(Ordering::Acquire) != epoch {
            bail!("DevTools opening was cancelled");
        }
        if server.as_ref().is_some_and(|server| {
            !server.alive.load(Ordering::Acquire) || server.sdk_path != snapshot.sdk_path
        }) {
            server.take().unwrap().stop().await?;
        }
        if server.is_none() {
            *server = Some(tokio::select! {
                result = DevToolsServer::start(&snapshot.sdk_path, self.startup_timeout) => result?,
                _ = slot.cancelled.notified() => bail!("DevTools opening was cancelled"),
            });
        }
        // Starting the SDK server can take time. Never return an old URI after a
        // session restart/disconnect, or resurrect a server closed during startup.
        let current = session.snapshot.lock().await.clone();
        let current_validation = validate_session(&current, module);
        if slot.epoch.load(Ordering::Acquire) != epoch
            || current.sdk_path != snapshot.sdk_path
            || current.service_uri != snapshot.service_uri
            || current.generation != snapshot.generation
            || current_validation.is_err()
            || !server.as_ref().unwrap().alive.load(Ordering::Acquire)
        {
            server.take().unwrap().stop().await?;
            bail!("The session changed or DevTools closed while opening; reopen the module");
        }
        Ok(DevToolsPage {
            url: page_url(
                &server.as_ref().unwrap().base_url,
                route,
                current.service_uri.as_deref().unwrap(),
            ),
        })
    }

    pub(crate) async fn close(&self, session_id: &str) -> Result<()> {
        let slot = {
            let mut slots = self.slots.lock().await;
            let slot = slots.remove(session_id);
            if let Some(slot) = slot.as_ref() {
                slot.epoch.fetch_add(1, Ordering::AcqRel);
                slot.cancelled.notify_one();
            }
            slot
        };
        if let Some(slot) = slot {
            stop_slot(slot).await?;
        }
        Ok(())
    }

    pub(crate) async fn close_all(&self) -> Result<()> {
        let slots: Vec<_> = {
            let mut slots = self.slots.lock().await;
            slots
                .drain()
                .map(|(_, slot)| {
                    slot.epoch.fetch_add(1, Ordering::AcqRel);
                    slot.cancelled.notify_one();
                    slot
                })
                .collect()
        };
        let mut stops = tokio::task::JoinSet::new();
        for slot in slots {
            stops.spawn(stop_slot(slot));
        }
        let mut error = None;
        while let Some(result) = stops.join_next().await {
            if let Err(err) = result
                .map_err(anyhow::Error::from)
                .and_then(|result| result)
            {
                error.get_or_insert(err);
            }
        }
        error.map_or(Ok(()), Err)
    }
}

async fn stop_slot(slot: Arc<ServerSlot>) -> Result<()> {
    if let Some(server) = slot.server.lock().await.take() {
        server.stop().await?;
    }
    Ok(())
}

fn module_route(module: &str) -> Result<&'static str> {
    Ok(match module {
        "inspector" => "inspector",
        "performance" => "performance",
        "cpu" => "cpu-profiler",
        "memory" => "memory",
        "logging" => "logging",
        _ => bail!("Unsupported DevTools module"),
    })
}

fn validate_session(snapshot: &SessionSnapshot, module: &str) -> Result<()> {
    if !matches!(snapshot.mode, RunMode::Debug | RunMode::Profile)
        || !matches!(
            snapshot.state,
            SessionState::Running | SessionState::Paused | SessionState::Starting
        )
    {
        bail!("DevTools requires an active Debug or Profile session");
    }
    if module == "inspector" && snapshot.mode == RunMode::Profile {
        bail!("Flutter Inspector requires a Debug session");
    }
    if snapshot
        .service_uri
        .as_ref()
        .is_none_or(|uri| uri.trim().is_empty())
    {
        bail!("The session VM service is not connected yet");
    }
    Ok(())
}

fn encode_component(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    const HEX: &[u8] = b"0123456789ABCDEF";
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            encoded.push(byte as char);
        } else {
            encoded.push('%');
            encoded.push(HEX[(byte >> 4) as usize] as char);
            encoded.push(HEX[(byte & 15) as usize] as char);
        }
    }
    encoded
}

fn page_url(base: &str, route: &str, service_uri: &str) -> String {
    format!("{base}/{route}?uri={}&embed=true&compiler=js&hide=debugger,network,home,app-size,provider,vm-tools", encode_component(service_uri))
}

#[derive(Default)]
struct Diagnostics {
    stdout_bytes: AtomicU64,
    stderr_bytes: AtomicU64,
}
impl Diagnostics {
    fn summary(&self) -> String {
        // Machine output may contain authenticated DTD/VM URLs. Keep diagnostics
        // bounded and useful without putting those tokens into user-facing errors.
        format!(
            "stdout {} bytes, stderr {} bytes",
            self.stdout_bytes.load(Ordering::Relaxed),
            self.stderr_bytes.load(Ordering::Relaxed)
        )
    }
}

struct DevToolsServer {
    process: Mutex<OwnedProcess>,
    base_url: String,
    sdk_path: String,
    alive: Arc<AtomicBool>,
    readers: Vec<JoinHandle<()>>,
}

impl DevToolsServer {
    async fn start(sdk_path: &str, timeout: Duration) -> Result<Self> {
        let dart = Path::new(sdk_path)
            .join("bin/cache/dart-sdk/bin")
            .join(if cfg!(windows) { "dart.exe" } else { "dart" });
        let args = [
            "devtools",
            "--no-launch-browser",
            "--machine",
            "--port=0",
            "--host=127.0.0.1",
        ]
        .map(str::to_owned);
        let mut process = OwnedProcess::spawn(&dart, &args, None, &HashMap::new())?;
        let stdout = process.stdout.take().context("Missing DevTools stdout")?;
        let stderr = process.stderr.take().context("Missing DevTools stderr")?;
        let diagnostics = Arc::new(Diagnostics::default());
        let alive = Arc::new(AtomicBool::new(true));
        let (started, receiver) = oneshot::channel();
        let readers = vec![
            tokio::spawn(read_machine_output(
                stdout,
                started,
                diagnostics.clone(),
                alive.clone(),
            )),
            tokio::spawn(drain_stderr(stderr, diagnostics.clone())),
        ];
        let mut server = Self {
            process: Mutex::new(process),
            base_url: String::new(),
            sdk_path: sdk_path.to_owned(),
            alive,
            readers,
        };
        let result = tokio::time::timeout(timeout, receiver).await;
        match result {
            Ok(Ok(Ok(base_url))) => {
                server.base_url = base_url;
                Ok(server)
            }
            _ => {
                let reason = match result {
                    Err(_) => "DevTools startup timed out".to_owned(),
                    Ok(Ok(Err(error))) => error.to_string(),
                    _ => "DevTools exited before its server was ready".to_owned(),
                };
                server.stop().await?;
                bail!("{reason} ({})", diagnostics.summary());
            }
        }
    }

    async fn stop(self) -> Result<()> {
        self.alive.store(false, Ordering::Release);
        let result = self
            .process
            .lock()
            .await
            .terminate(Duration::from_millis(500))
            .await;
        for reader in self.readers {
            reader.abort();
        }
        result
    }
}

fn started_url(line: &[u8]) -> Result<Option<String>> {
    let Ok(value) = serde_json::from_slice::<Value>(line) else {
        return Ok(None);
    };
    if value["event"] != "server.started" && value["method"] != "server.started" {
        return Ok(None);
    }
    let host = value["params"]["host"]
        .as_str()
        .context("DevTools returned an invalid server host")?;
    if !matches!(host, "127.0.0.1" | "localhost" | "::1" | "[::1]") {
        bail!("DevTools returned a non-loopback server host");
    }
    let port = value["params"]["port"]
        .as_u64()
        .filter(|port| *port > 0 && *port <= u16::MAX as u64)
        .context("DevTools returned an invalid server port")?;
    let host = if host == "::1" { "[::1]" } else { host };
    Ok(Some(format!("http://{host}:{port}")))
}

async fn read_machine_output(
    mut stdout: impl AsyncRead + Unpin,
    started: oneshot::Sender<Result<String>>,
    diagnostics: Arc<Diagnostics>,
    alive: Arc<AtomicBool>,
) {
    let mut started = Some(started);
    let mut buffer = [0u8; 8192];
    let mut line = Vec::new();
    let mut oversized_line = false;
    loop {
        let count = match stdout.read(&mut buffer).await {
            Ok(0) | Err(_) => break,
            Ok(count) => count,
        };
        diagnostics
            .stdout_bytes
            .fetch_add(count as u64, Ordering::Relaxed);
        for &byte in &buffer[..count] {
            if byte == b'\n' {
                if !oversized_line && started.is_some() {
                    match started_url(&line) {
                        Ok(Some(url)) => {
                            let _ = started.take().unwrap().send(Ok(url));
                        }
                        Err(error) => {
                            let _ = started.take().unwrap().send(Err(error));
                        }
                        _ => {}
                    }
                }
                line.clear();
                oversized_line = false;
            } else if line.len() < MAX_MACHINE_LINE {
                line.push(byte);
            } else {
                oversized_line = true;
            }
        }
    }
    alive.store(false, Ordering::Release);
    if let Some(sender) = started {
        let _ = sender.send(Err(anyhow!("DevTools exited before its server was ready")));
    }
}

async fn drain_stderr(mut stderr: impl AsyncRead + Unpin, diagnostics: Arc<Diagnostics>) {
    let mut buffer = [0u8; 8192];
    while let Ok(count) = stderr.read(&mut buffer).await {
        if count == 0 {
            break;
        }
        diagnostics
            .stderr_bytes
            .fetch_add(count as u64, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::RunConfiguration;
    use serde_json::json;
    use tokio::sync::broadcast;

    fn session(id: &str, sdk_path: &Path) -> Arc<Session> {
        let (events, _) = broadcast::channel(10);
        Session::new(
            id.into(),
            RunConfiguration {
                project_path: sdk_path.to_string_lossy().into_owned(),
                sdk_path: sdk_path.to_string_lossy().into_owned(),
                program: "lib/main.dart".into(),
                device_id: "fixture".into(),
                mode: RunMode::Debug,
                no_debug: false,
                attach_uri: None,
                env: vec![],
                tool_args: vec![],
                args: vec![],
                flavor: None,
                dart_defines: vec![],
            },
            events,
        )
    }

    async fn ready_session(id: &str, sdk: &Path) -> Arc<Session> {
        let session = session(id, sdk);
        {
            let mut snapshot = session.snapshot.lock().await;
            snapshot.state = SessionState::Running;
            snapshot.service_uri = Some("ws://127.0.0.1:1234/a+/ws?x=y&k=中文".into());
        }
        session
    }

    #[test]
    fn validates_exact_modules_and_percent_encodes_service_uri() {
        assert_eq!(module_route("cpu").unwrap(), "cpu-profiler");
        for module in ["network", "debugger", "../memory", "", "cpu-profiler"] {
            assert!(module_route(module).is_err());
        }
        let url = page_url(
            "http://127.0.0.1:9100",
            "memory",
            "ws://localhost/a+%/ws?x=中文&y=1",
        );
        assert_eq!(url, "http://127.0.0.1:9100/memory?uri=ws%3A%2F%2Flocalhost%2Fa%2B%25%2Fws%3Fx%3D%E4%B8%AD%E6%96%87%26y%3D1&embed=true&compiler=js&hide=debugger,network,home,app-size,provider,vm-tools");
        assert_eq!(encode_component("abc-_.~"), "abc-_.~");
    }

    #[test]
    fn accepts_only_machine_started_schema_and_loopback_port() {
        assert_eq!(
            started_url(
                br#"{"event":"server.started","params":{"host":"127.0.0.1","port":2345,"pid":1}}"#
            )
            .unwrap()
            .unwrap(),
            "http://127.0.0.1:2345"
        );
        assert_eq!(
            started_url(br#"{"method":"server.started","params":{"host":"::1","port":1}}"#)
                .unwrap()
                .unwrap(),
            "http://[::1]:1"
        );
        assert!(started_url(b"SDK warning").unwrap().is_none());
        assert!(started_url(br#"{"event":"server.different"}"#)
            .unwrap()
            .is_none());
        for params in [
            json!({"host":"0.0.0.0","port":1}),
            json!({"host":"127.0.0.1","port":0}),
            json!({"host":"127.0.0.1","port":65536}),
            json!({"host":"127.0.0.1","port":"9100"}),
            json!({"host":"127.0.0.1"}),
        ] {
            assert!(started_url(
                json!({"event":"server.started","params":params})
                    .to_string()
                    .as_bytes()
            )
            .is_err());
        }
    }

    #[tokio::test]
    async fn session_validation_accepts_profile_no_debug_and_rejects_release_or_ended() {
        let session = ready_session("validation", Path::new("/unused")).await;
        let mut snapshot = session.snapshot.lock().await.clone();
        validate_session(&snapshot, "inspector").unwrap();
        snapshot.no_debug = true;
        validate_session(&snapshot, "memory").unwrap();
        snapshot.mode = RunMode::Profile;
        validate_session(&snapshot, "performance").unwrap();
        assert!(validate_session(&snapshot, "inspector").is_err());
        snapshot.mode = RunMode::Release;
        assert!(validate_session(&snapshot, "memory").is_err());
        snapshot.mode = RunMode::Debug;
        for state in [
            SessionState::Preparing,
            SessionState::Stopping,
            SessionState::Ended,
            SessionState::Failed,
        ] {
            snapshot.state = state;
            assert!(validate_session(&snapshot, "memory").is_err());
        }
        snapshot.state = SessionState::Running;
        snapshot.service_uri = None;
        assert!(validate_session(&snapshot, "memory").is_err());
    }

    #[cfg(unix)]
    fn fake_sdk(behavior: &str) -> tempfile::TempDir {
        use std::{fs, os::unix::fs::PermissionsExt};
        let sdk = tempfile::tempdir().unwrap();
        let executable = sdk.path().join("bin/cache/dart-sdk/bin/dart");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        let script = format!("#!/usr/bin/env python3\nBEHAVIOR = {behavior:?}\n")
            + r#"
import os, sys, json, time
root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))))
with open(os.path.join(root, 'starts.jsonl'), 'a') as f:
    f.write(json.dumps({'pid':os.getpid(), 'args':sys.argv[1:]})+'\n')
if BEHAVIOR == 'exit':
    sys.stderr.write('secret authenticated uri=http://localhost/token/\n');sys.exit(1)
if BEHAVIOR == 'delayed':time.sleep(.25)
if BEHAVIOR == 'noisy':
    sys.stderr.write('e'*200000);sys.stderr.flush()
    print('x'*100000,flush=True)
if BEHAVIOR != 'silent':
    host='nonloopback.example' if BEHAVIOR == 'badhost' else '127.0.0.1'
    print(json.dumps({'event':'server.started','params':{'host':host,'port':32123,'pid':os.getpid()}}),flush=True)
for line in sys.stdin:pass
"#;
        fs::write(&executable, script).unwrap();
        fs::set_permissions(executable, fs::Permissions::from_mode(0o755)).unwrap();
        sdk
    }

    #[cfg(unix)]
    async fn starts(sdk: &Path, expected: usize) -> Vec<Value> {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if let Ok(text) = std::fs::read_to_string(sdk.join("starts.jsonl")) {
                    let values: Vec<_> = text
                        .lines()
                        .filter_map(|line| serde_json::from_str(line).ok())
                        .collect();
                    if values.len() >= expected {
                        return values;
                    }
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap()
    }

    #[cfg(unix)]
    async fn assert_reaped(pid: u64) {
        tokio::time::timeout(Duration::from_secs(3), async {
            while unsafe { libc::kill(pid as i32, 0) } == 0 {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn selected_sdk_process_reused_between_modules_and_idempotently_closed() {
        let sdk = fake_sdk("noisy");
        let session = ready_session("reuse", sdk.path()).await;
        let manager = DevToolsManager::default();
        let first = manager.open(&session, "memory").await.unwrap();
        let second = manager.open(&session, "cpu").await.unwrap();
        assert!(first.url.contains("/memory?"));
        assert!(second.url.contains("/cpu-profiler?"));
        let records = starts(sdk.path(), 1).await;
        assert_eq!(records.len(), 1);
        assert_eq!(
            records[0]["args"],
            json!([
                "devtools",
                "--no-launch-browser",
                "--machine",
                "--port=0",
                "--host=127.0.0.1"
            ])
        );
        manager.close("reuse").await.unwrap();
        manager.close("reuse").await.unwrap();
        assert_reaped(records[0]["pid"].as_u64().unwrap()).await;
        manager.open(&session, "logging").await.unwrap();
        let records = starts(sdk.path(), 2).await;
        manager.close_all().await.unwrap();
        assert_reaped(records[1]["pid"].as_u64().unwrap()).await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn close_during_startup_cancels_and_reaps_without_waiting_for_readiness() {
        let sdk = fake_sdk("silent");
        let session = ready_session("cancel", sdk.path()).await;
        let manager = Arc::new(DevToolsManager::default());
        let opening_manager = manager.clone();
        let opening = tokio::spawn(async move { opening_manager.open(&session, "memory").await });
        let records = starts(sdk.path(), 1).await;
        tokio::time::timeout(Duration::from_secs(2), manager.close("cancel"))
            .await
            .unwrap()
            .unwrap();
        assert!(opening.await.unwrap().is_err());
        assert_reaped(records[0]["pid"].as_u64().unwrap()).await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn session_uri_or_state_change_during_startup_cannot_return_stale_page() {
        for change_uri in [true, false] {
            let sdk = fake_sdk("delayed");
            let session = ready_session("stale", sdk.path()).await;
            let opening_session = session.clone();
            let manager = Arc::new(DevToolsManager::default());
            let opening_manager = manager.clone();
            let opening =
                tokio::spawn(
                    async move { opening_manager.open(&opening_session, "performance").await },
                );
            let records = starts(sdk.path(), 1).await;
            {
                let mut snapshot = session.snapshot.lock().await;
                if change_uri {
                    snapshot.service_uri = Some("http://127.0.0.1:4321/new-token/".into());
                } else {
                    snapshot.state = SessionState::Ended;
                }
            }
            assert!(opening.await.unwrap().is_err());
            assert_reaped(records[0]["pid"].as_u64().unwrap()).await;
            manager.close_all().await.unwrap();
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn startup_failures_timeout_and_bad_machine_event_release_process_without_tokens() {
        for behavior in ["silent", "exit", "badhost"] {
            let sdk = fake_sdk(behavior);
            let session = ready_session("failure", sdk.path()).await;
            let manager = DevToolsManager {
                startup_timeout: if behavior == "silent" {
                    Duration::from_secs(1)
                } else {
                    STARTUP_TIMEOUT
                },
                ..DevToolsManager::default()
            };
            let error = manager
                .open(&session, "logging")
                .await
                .unwrap_err()
                .to_string();
            assert!(!error.contains("token"));
            // A deliberately short deadline may terminate the interpreter before
            // the fixture writes its first record on a busy parallel test run.
            if behavior != "silent" || sdk.path().join("starts.jsonl").exists() {
                let records = starts(sdk.path(), 1).await;
                assert_reaped(records[0]["pid"].as_u64().unwrap()).await;
            }
            assert!(manager
                .slots
                .lock()
                .await
                .get("failure")
                .unwrap()
                .server
                .lock()
                .await
                .is_none());
            manager.close_all().await.unwrap();
        }
    }
}
