pub use crate::build::{BuildConfiguration, BuildPreset, BuildSnapshot, BuildVersion};
pub use crate::device::{DeviceInfo, EmulatorInfo};
pub use crate::devtools::DevToolsPage;
pub use crate::log::{LogEntry, LogPage};
pub use crate::project::ProjectInfo;
pub use crate::project_git::ProjectGitInfo;
pub use crate::sdk::SdkInfo;
pub use crate::session::{
    CoreEvent, CoreEventKind, DebugAction, DebugThread, EnvVar, JsonResponse, RunConfiguration,
    RunMode, SessionSnapshot, SessionState, SourceBreakpoint,
};
pub use crate::settings::AppSettings;
pub use crate::test_runner::{TestResult, TestRunConfig, TestRunSnapshot, TestSelection};
pub use crate::workspace::{ProjectRunState, RunProfile, WorkspacePreferences};
use crate::{device::DeviceManager, session::Session};
use anyhow::{anyhow, bail, Result};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, OnceLock,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{broadcast, watch, Mutex};

struct Core {
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    builds: crate::build::BuildManager,
    tests: crate::test_runner::TestManager,
    workspace_updates: Mutex<()>,
    devices: DeviceManager,
    devtools: crate::devtools::DevToolsManager,
    events: broadcast::Sender<CoreEvent>,
    ids: AtomicU64,
    subscriptions: watch::Sender<u64>,
}
static CORE: OnceLock<Arc<Core>> = OnceLock::new();
fn core() -> Arc<Core> {
    CORE.get_or_init(|| {
        let (events, _) = broadcast::channel(1024);
        let (subscriptions, _) = watch::channel(0);
        let core = Arc::new(Core {
            sessions: Mutex::new(HashMap::new()),
            builds: crate::build::BuildManager::default(),
            tests: crate::test_runner::TestManager::default(),
            workspace_updates: Mutex::new(()),
            devices: DeviceManager::new(events.clone()),
            devtools: crate::devtools::DevToolsManager::default(),
            events,
            ids: AtomicU64::new(1),
            subscriptions,
        });
        let mut removed = core.devices.removed.subscribe();
        let mut devtools_events = core.events.subscribe();
        let devtools_core = Arc::downgrade(&core);
        tokio::spawn(async move {
            loop {
                let event = devtools_events.recv().await;
                let Some(core) = devtools_core.upgrade() else {
                    break;
                };
                let sessions: Vec<_> = core.sessions.lock().await.values().cloned().collect();
                match event {
                    Ok(event) => {
                        if !matches!(event.kind, CoreEventKind::State) {
                            continue;
                        }
                        for session in sessions {
                            let snapshot = session.snapshot.lock().await.clone();
                            if snapshot.session_id == event.session_id
                                && matches!(
                                    snapshot.state,
                                    SessionState::Stopping
                                        | SessionState::Ended
                                        | SessionState::Failed
                                )
                            {
                                let _ = core.devtools.close(&snapshot.session_id).await;
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        for session in sessions {
                            let snapshot = session.snapshot.lock().await.clone();
                            if matches!(
                                snapshot.state,
                                SessionState::Stopping | SessionState::Ended | SessionState::Failed
                            ) {
                                let _ = core.devtools.close(&snapshot.session_id).await;
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
        let weak = Arc::downgrade(&core);
        tokio::spawn(async move {
            loop {
                let event = removed.recv().await;
                let Some(core) = weak.upgrade() else {
                    break;
                };
                let sessions: Vec<_> = core.sessions.lock().await.values().cloned().collect();
                match event {
                    Ok((sdk_path, device_id)) => {
                        for session in sessions {
                            let matches = {
                                let snapshot = session.snapshot.lock().await;
                                snapshot.sdk_path == sdk_path
                                    && (snapshot.device_id == device_id || device_id == "*")
                                    && !matches!(
                                        snapshot.state,
                                        SessionState::Ended | SessionState::Failed
                                    )
                            };
                            if matches {
                                tokio::spawn(async move {
                                    session.device_disconnected().await;
                                });
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        // Rescan after lost changes; keep consuming new changes while cleanup runs.
                        tokio::spawn(async move {
                            let mut devices = HashMap::new();
                            for session in &sessions {
                                let snapshot = session.snapshot.lock().await.clone();
                                if !matches!(
                                    snapshot.state,
                                    SessionState::Ended | SessionState::Failed
                                ) && !devices.contains_key(&snapshot.sdk_path)
                                {
                                    let result = core.devices.devices(&snapshot.sdk_path).await;
                                    devices.insert(snapshot.sdk_path, result);
                                }
                            }
                            for session in sessions {
                                let disconnected = {
                                    let snapshot = session.snapshot.lock().await;
                                    devices.get(&snapshot.sdk_path).is_some_and(|result| {
                                        result.as_ref().map_or(true, |devices| {
                                            !devices
                                                .iter()
                                                .any(|device| device.id == snapshot.device_id)
                                        })
                                    }) && !matches!(
                                        snapshot.state,
                                        SessionState::Ended | SessionState::Failed
                                    )
                                };
                                if disconnected {
                                    session.device_disconnected().await;
                                }
                            }
                        });
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
        core
    })
    .clone()
}
async fn session(id: &str) -> Result<Arc<Session>> {
    core()
        .sessions
        .lock()
        .await
        .get(id)
        .cloned()
        .ok_or_else(|| anyhow!("Unknown session: {id}"))
}
pub async fn discover_projects(root: String) -> Result<Vec<ProjectInfo>> {
    crate::project::discover_projects(root).await
}
pub async fn project_git_info(project_path: String) -> Result<Option<ProjectGitInfo>> {
    crate::project_git::project_git_info(project_path).await
}
pub async fn switch_project_branch(project_path: String, branch: String) -> Result<ProjectGitInfo> {
    crate::project_git::switch_project_branch(project_path, branch).await
}
pub async fn resolve_sdk(
    project_path: Option<String>,
    explicit_path: Option<String>,
) -> Result<SdkInfo> {
    crate::sdk::resolve_sdk(project_path, explicit_path).await
}
pub async fn get_app_settings() -> Result<AppSettings> {
    crate::settings::get_app_settings().await
}
pub async fn set_default_sdk(path: Option<String>) -> Result<AppSettings> {
    crate::settings::set_default_sdk(path).await
}
pub async fn set_theme_mode(mode: String) -> Result<AppSettings> {
    crate::settings::set_theme_mode(mode).await
}
pub async fn set_build_presets(presets: Vec<BuildPreset>) -> Result<AppSettings> {
    crate::settings::set_build_presets(presets).await
}
pub async fn set_workspace_projects(
    projects: Vec<ProjectInfo>,
    selected_project_path: Option<String>,
) -> Result<AppSettings> {
    crate::settings::set_workspace_projects(projects, selected_project_path).await
}
pub async fn set_workspace_preferences(preferences: WorkspacePreferences) -> Result<AppSettings> {
    let core = core();
    let _update = core.workspace_updates.lock().await;
    let settings = crate::settings::set_workspace_preferences(preferences).await?;
    let sessions: Vec<_> = core.sessions.lock().await.values().cloned().collect();
    for session in sessions {
        let path = session.snapshot.lock().await.project_path.clone();
        let enabled = settings
            .workspace_preferences
            .project_states
            .iter()
            .any(|state| state.project_path == path && state.auto_reload);
        session.set_auto_reload(enabled);
    }
    Ok(settings)
}
pub async fn open_source_location(
    project_path: String,
    path: String,
    line: u32,
    column: u32,
) -> Result<()> {
    crate::workspace::open_source_location(project_path, path, line, column).await
}
pub async fn discover_test_files(project_path: String) -> Result<Vec<String>> {
    crate::test_runner::discover_test_files(project_path).await
}
pub async fn start_test_run(config: TestRunConfig) -> Result<TestRunSnapshot> {
    core().tests.start(config).await
}
pub async fn test_run_snapshot(run_id: String) -> Result<TestRunSnapshot> {
    core().tests.snapshot(&run_id).await
}
pub async fn list_test_runs() -> Vec<TestRunSnapshot> {
    core().tests.list().await
}
pub async fn read_test_logs(run_id: String, after_id: u64, limit: u32) -> Result<LogPage> {
    core().tests.logs(&run_id, after_id, limit).await
}
pub async fn stop_test_run(run_id: String) -> Result<()> {
    core().tests.stop(&run_id).await
}
pub async fn start_build(config: BuildConfiguration) -> Result<BuildSnapshot> {
    core().builds.start(config).await
}
pub async fn read_build_version(project_path: String, args: Vec<String>) -> Result<BuildVersion> {
    crate::build::read_build_version(project_path, args).await
}
pub async fn build_snapshot(build_id: String) -> Result<BuildSnapshot> {
    core().builds.snapshot(&build_id).await
}
pub async fn list_builds() -> Vec<BuildSnapshot> {
    core().builds.list().await
}
pub async fn read_build_logs(build_id: String, after_id: u64, limit: u32) -> Result<LogPage> {
    core().builds.logs(&build_id, after_id, limit).await
}
pub async fn stop_build(build_id: String) -> Result<()> {
    core().builds.stop(&build_id).await
}
pub async fn open_build_output(build_id: String) -> Result<()> {
    core().builds.open_output(&build_id).await
}
pub async fn list_devices(sdk_path: String) -> Result<Vec<DeviceInfo>> {
    core().devices.devices(&sdk_path).await
}
pub async fn list_emulators(sdk_path: String) -> Result<Vec<EmulatorInfo>> {
    core().devices.emulators(&sdk_path).await
}
pub async fn launch_emulator(sdk_path: String, emulator_id: String) -> Result<DeviceInfo> {
    core().devices.launch(&sdk_path, &emulator_id).await
}
pub async fn start_session(config: RunConfiguration) -> Result<SessionSnapshot> {
    if config.device_id.trim().is_empty() {
        bail!("Select a device before starting");
    }
    if config.env.iter().any(|e| {
        e.name.is_empty() || e.name.contains('=') || e.name.contains('\0') || e.value.contains('\0')
    }) {
        bail!("Invalid environment variable");
    }
    let core = core();
    // iOS SDK log readers identify apps by executable name (often Runner).
    // Resolve the target platform from the selected SDK, never from its ID.
    let isolate_device_logs = core
        .devices
        .devices(&config.sdk_path)
        .await
        .map_err(|error| anyhow!("SDK device discovery failed: {error}"))
        .and_then(|devices| {
            devices
                .iter()
                .find(|device| device.id == config.device_id)
                .map(|device| {
                    device.platform_type.as_deref() == Some("ios")
                        || device.platform.starts_with("ios")
                })
                .ok_or_else(|| anyhow!("Selected SDK device is no longer available"))
        });
    let update = core.workspace_updates.lock().await;
    let auto_reload = crate::settings::get_app_settings()
        .await
        .map(|settings| {
            settings
                .workspace_preferences
                .project_states
                .iter()
                .any(|state| state.project_path == config.project_path && state.auto_reload)
        })
        .unwrap_or(false);
    let mut sessions = core.sessions.lock().await;
    // Retain only a small recent history; each session has its own bounded logs.
    if sessions.len() >= 32 {
        let mut ended = vec![];
        for (id, s) in sessions.iter() {
            if matches!(
                s.snapshot.lock().await.state,
                SessionState::Ended | SessionState::Failed
            ) {
                ended.push(id.clone());
            }
        }
        for id in ended {
            sessions.remove(&id);
        }
        if sessions.len() >= 32 {
            bail!("Maximum active sessions reached");
        }
    }
    let id = format!(
        "{}-{}",
        SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis(),
        core.ids.fetch_add(1, Ordering::Relaxed)
    );
    let session = Session::new(id.clone(), config, core.events.clone(), isolate_device_logs);
    session.set_auto_reload(auto_reload);
    crate::auto_reload::start(session.clone());
    sessions.insert(id, session.clone());
    drop(sessions);
    drop(update);
    session.emit(CoreEventKind::State, None).await;
    let snapshot = session.snapshot.lock().await.clone();
    let runner = session.clone();
    tokio::spawn(async move {
        runner.run().await;
    });
    // A single periodic availability signal batches all logs instead of sending text per line.
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(150));
        let mut last = 0;
        loop {
            interval.tick().await;
            if matches!(
                session.snapshot.lock().await.state,
                SessionState::Ended | SessionState::Failed
            ) {
                session.emit(CoreEventKind::OutputAvailable, None).await;
                break;
            }
            let latest = session.logs.lock().await.latest_id();
            if latest > last {
                last = latest;
                session.emit(CoreEventKind::OutputAvailable, None).await;
            }
        }
    });
    Ok(snapshot)
}
pub async fn stop_session(session_id: String) -> Result<()> {
    session(&session_id).await?.stop().await
}
pub async fn hot_reload(session_id: String) -> Result<()> {
    session(&session_id).await?.hot_update(false).await
}
pub async fn hot_restart(session_id: String) -> Result<()> {
    session(&session_id).await?.hot_update(true).await
}
pub async fn session_snapshots() -> Result<Vec<SessionSnapshot>> {
    let sessions: Vec<_> = core().sessions.lock().await.values().cloned().collect();
    let mut snapshots = vec![];
    for session in sessions {
        snapshots.push(session.snapshot.lock().await.clone());
    }
    snapshots.sort_by(|a, b| a.session_id.cmp(&b.session_id));
    Ok(snapshots)
}
pub async fn read_logs(
    session_id: String,
    after_id: u64,
    limit: u32,
    query: String,
) -> Result<LogPage> {
    let session = session(&session_id).await?;
    let page = session.logs.lock().await.query(
        Some(after_id),
        (limit as usize).clamp(1, 1000),
        if query.is_empty() {
            None
        } else {
            Some(query.as_str())
        },
    );
    Ok(page)
}
pub async fn subscribe_events(sink: crate::frb_generated::StreamSink<CoreEvent>) -> Result<()> {
    let core = core();
    let mut cancelled = core.subscriptions.subscribe();
    let mut receiver = core.events.subscribe();
    loop {
        let event =
            tokio::select! {event=receiver.recv()=>event,_=cancelled.changed()=>return Ok(())};
        match event {
            Ok(event) => {
                if sink.add(event).is_err() {
                    return Ok(());
                }
            }
            Err(broadcast::error::RecvError::Lagged(_)) => {
                let sessions: Vec<_> = core.sessions.lock().await.values().cloned().collect();
                for session in sessions {
                    for event in session.recovery_events().await {
                        if sink.add(event).is_err() {
                            return Ok(());
                        }
                    }
                }
            }
            Err(broadcast::error::RecvError::Closed) => return Ok(()),
        }
    }
}
pub async fn cancel_event_subscription() -> Result<()> {
    core()
        .subscriptions
        .send_modify(|epoch| *epoch = epoch.wrapping_add(1));
    Ok(())
}
async fn debug_request(id: &str, command: &str, args: serde_json::Value) -> Result<JsonResponse> {
    let session = session(id).await?;
    {
        let snapshot = session.snapshot.lock().await;
        if snapshot.mode != RunMode::Debug
            || snapshot.no_debug
            || !matches!(
                snapshot.state,
                SessionState::Running | SessionState::Paused | SessionState::Starting
            )
        {
            bail!("Debugger requires an active Debug session with debugging enabled");
        }
    }
    let response = session
        .request(command, args, Duration::from_secs(30))
        .await?;
    Ok(JsonResponse {
        json: response.to_string(),
    })
}
pub async fn threads(session_id: String) -> Result<JsonResponse> {
    debug_request(&session_id, "threads", json!({})).await
}
pub async fn debug_action(
    session_id: String,
    action: DebugAction,
    thread_id: i64,
) -> Result<JsonResponse> {
    debug_request(
        &session_id,
        match action {
            DebugAction::Pause => "pause",
            DebugAction::Continue => "continue",
            DebugAction::Next => "next",
            DebugAction::StepIn => "stepIn",
            DebugAction::StepOut => "stepOut",
        },
        json!({"threadId":thread_id}),
    )
    .await
}
pub async fn set_breakpoints(
    session_id: String,
    path: String,
    breakpoints: Vec<SourceBreakpoint>,
) -> Result<JsonResponse> {
    let breakpoints:Vec<_>=breakpoints.into_iter().map(|b|json!({"line":b.line,"condition":b.condition,"hitCondition":b.hit_condition,"logMessage":b.log_message})).collect();
    debug_request(
        &session_id,
        "setBreakpoints",
        json!({"source":{"path":path},"breakpoints":breakpoints}),
    )
    .await
}
pub async fn stack_trace(
    session_id: String,
    thread_id: i64,
    start_frame: i64,
    levels: i64,
) -> Result<JsonResponse> {
    debug_request(
        &session_id,
        "stackTrace",
        json!({"threadId":thread_id,"startFrame":start_frame,"levels":levels.clamp(1,200)}),
    )
    .await
}
pub async fn scopes(session_id: String, frame_id: i64) -> Result<JsonResponse> {
    debug_request(&session_id, "scopes", json!({"frameId":frame_id})).await
}
pub async fn variables(
    session_id: String,
    variables_reference: i64,
    start: i64,
    count: i64,
) -> Result<JsonResponse> {
    debug_request(
        &session_id,
        "variables",
        json!({"variablesReference":variables_reference,"start":start,"count":count.clamp(1,200)}),
    )
    .await
}
pub async fn evaluate(
    session_id: String,
    expression: String,
    frame_id: Option<i64>,
) -> Result<JsonResponse> {
    debug_request(
        &session_id,
        "evaluate",
        json!({"expression":expression,"frameId":frame_id,"context":"repl"}),
    )
    .await
}

fn network_arguments(method: &str, params_json: &str) -> Result<serde_json::Value> {
    if !matches!(
        method,
        "getVM"
            | "getIsolate"
            | "ext.dart.io.getVersion"
            | "ext.dart.io.httpEnableTimelineLogging"
            | "ext.dart.io.getHttpProfile"
            | "ext.dart.io.getHttpProfileRequest"
    ) {
        bail!("Unsupported network service method: {method}");
    }
    let params: serde_json::Value = serde_json::from_str(params_json)
        .map_err(|error| anyhow!("Invalid network service parameters: {error}"))?;
    if !params.is_object() {
        bail!("Network service parameters must be a JSON object");
    }
    Ok(json!({"method": method, "params": params}))
}

fn validate_network_session(snapshot: &SessionSnapshot) -> Result<()> {
    if snapshot.mode != RunMode::Debug
        || snapshot.no_debug
        || !matches!(
            snapshot.state,
            SessionState::Running | SessionState::Paused | SessionState::Starting
        )
    {
        bail!("Network inspection requires an active Debug session with debugging enabled");
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

async fn network_request_for_session(
    session: &Session,
    arguments: serde_json::Value,
) -> Result<JsonResponse> {
    validate_network_session(&*session.snapshot.lock().await)?;
    let response = session
        .request("callService", arguments, Duration::from_secs(10))
        .await?;
    if !response.is_object() {
        bail!("The debug adapter returned no network service response");
    }
    Ok(JsonResponse {
        json: response.to_string(),
    })
}

/// Calls the VM HTTP profiling APIs through the session's existing debug adapter.
pub async fn network_request(
    session_id: String,
    method: String,
    params_json: String,
) -> Result<JsonResponse> {
    let arguments = network_arguments(&method, &params_json)?;
    let session = session(&session_id).await?;
    network_request_for_session(&session, arguments).await
}

pub async fn open_devtools(session_id: String, module: String) -> Result<DevToolsPage> {
    let session = session(&session_id).await?;
    core().devtools.open(&session, &module).await
}

pub async fn close_devtools(session_id: String) -> Result<()> {
    core().devtools.close(&session_id).await
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SourcePage {
    pub path: String,
    pub start_line: u32,
    pub lines: Vec<String>,
    pub total_lines: u32,
}
pub async fn read_source(path: String, start_line: u32, limit: u32) -> Result<SourcePage> {
    let metadata = tokio::fs::metadata(&path).await?;
    if !metadata.is_file() || metadata.len() > 1024 * 1024 {
        bail!("Source must be a regular UTF-8 file smaller than 1 MiB");
    }
    // Read limit remains enforced even if the file grows after metadata is checked.
    let mut file = tokio::fs::File::open(&path).await?;
    let mut bytes = Vec::new();
    use tokio::io::AsyncReadExt;
    (&mut file)
        .take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .await?;
    if bytes.len() > 1024 * 1024 {
        bail!("Source exceeds 1 MiB");
    }
    let text = String::from_utf8(bytes)?;
    let lines: Vec<_> = text.lines().collect();
    let total_lines = lines.len() as u32;
    let start_line = start_line.max(1);
    let selected = lines
        .into_iter()
        .skip((start_line - 1) as usize)
        .take((limit as usize).clamp(1, 2000))
        .map(str::to_owned)
        .collect();
    Ok(SourcePage {
        path,
        start_line,
        lines: selected,
        total_lines,
    })
}
pub async fn shutdown_core() -> Result<()> {
    cancel_event_subscription().await?;
    let core = core();
    core.builds.shutdown().await;
    core.tests.shutdown().await;
    let sessions: Vec<_> = core.sessions.lock().await.values().cloned().collect();
    for session in sessions {
        let _ = session.stop().await;
    }
    let _ = core.devtools.close_all().await;
    core.devices.shutdown().await;
    core.sessions.lock().await.clear();
    Ok(())
}

#[cfg(test)]
mod network_tests {
    use super::*;

    fn configuration() -> RunConfiguration {
        RunConfiguration {
            project_path: String::new(),
            sdk_path: String::new(),
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
        }
    }

    #[test]
    fn allows_only_http_profile_and_isolate_discovery_methods() {
        for method in [
            "getVM",
            "getIsolate",
            "ext.dart.io.getVersion",
            "ext.dart.io.httpEnableTimelineLogging",
            "ext.dart.io.getHttpProfile",
            "ext.dart.io.getHttpProfileRequest",
        ] {
            let arguments = network_arguments(method, r#"{"isolateId":"isolates/1"}"#).unwrap();
            assert_eq!(arguments["method"], method);
            assert_eq!(arguments["params"]["isolateId"], "isolates/1");
        }
        for method in ["evaluate", "resume", "ext.dart.io.clearHttpProfile", ""] {
            assert!(network_arguments(method, "{}")
                .unwrap_err()
                .to_string()
                .contains("Unsupported network service method"));
        }
    }

    #[test]
    fn rejects_malformed_or_non_object_parameters() {
        for params in ["null", "[]", "1", "true", r#""value""#] {
            assert!(network_arguments("getVM", params)
                .unwrap_err()
                .to_string()
                .contains("JSON object"));
        }
        assert!(network_arguments("getVM", "{")
            .unwrap_err()
            .to_string()
            .contains("Invalid network service parameters"));
    }

    #[tokio::test]
    async fn requires_active_debugging_and_connected_vm_service() {
        let (events, _) = broadcast::channel(10);
        let session = Session::new(
            "network-validation".into(),
            configuration(),
            events,
            Ok(false),
        );
        let mut snapshot = session.snapshot.lock().await.clone();
        snapshot.state = SessionState::Running;
        assert!(validate_network_session(&snapshot)
            .unwrap_err()
            .to_string()
            .contains("VM service"));
        snapshot.service_uri = Some("http://127.0.0.1:1234/token/".into());
        for state in [
            SessionState::Running,
            SessionState::Paused,
            SessionState::Starting,
        ] {
            snapshot.state = state;
            validate_network_session(&snapshot).unwrap();
        }
        for state in [
            SessionState::Preparing,
            SessionState::Stopping,
            SessionState::Ended,
            SessionState::Failed,
        ] {
            snapshot.state = state;
            assert!(validate_network_session(&snapshot).is_err());
        }
        snapshot.state = SessionState::Running;
        for mode in [RunMode::Profile, RunMode::Release] {
            snapshot.mode = mode;
            assert!(validate_network_session(&snapshot).is_err());
        }
        snapshot.mode = RunMode::Debug;
        snapshot.no_debug = true;
        assert!(validate_network_session(&snapshot).is_err());
        snapshot.no_debug = false;
        snapshot.service_uri = Some(" ".into());
        assert!(validate_network_session(&snapshot).is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn forwards_profile_rpc_and_returns_unwrapped_dap_body() {
        let sdk = crate::session::tests::fake_sdk(false);
        let script_path = sdk.path().join("bin/flutter");
        let script = std::fs::read_to_string(&script_path).unwrap().replace(
            "elif command=='hotReload':",
            "elif command=='callService':response(request,{'type':'HttpProfile','requests':[],'received':request['arguments']})\n    elif command=='hotReload':",
        );
        std::fs::write(script_path, script).unwrap();
        let mut config = configuration();
        config.sdk_path = sdk.path().to_string_lossy().into_owned();
        config.project_path = config.sdk_path.clone();
        let (events, _) = broadcast::channel(100);
        let session = Session::new("network-forward".into(), config, events, Ok(false));
        let runner = session.clone();
        let task = tokio::spawn(async move { runner.run().await });
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let snapshot = session.snapshot.lock().await.clone();
                if snapshot.state == SessionState::Running && snapshot.service_uri.is_some() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        task.await.unwrap();
        let arguments = network_arguments(
            "ext.dart.io.getHttpProfile",
            r#"{"isolateId":"isolates/1","updatedSince":42}"#,
        )
        .unwrap();
        let response = network_request_for_session(&session, arguments.clone())
            .await
            .unwrap();
        session.stop().await.unwrap();
        let body: serde_json::Value = serde_json::from_str(&response.json).unwrap();
        assert_eq!(body["type"], "HttpProfile");
        assert_eq!(body["received"], arguments);
        assert!(body.get("body").is_none());
        let requests = std::fs::read_to_string(sdk.path().join("requests.jsonl")).unwrap();
        let call: serde_json::Value = requests
            .lines()
            .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
            .find(|request| request["command"] == "callService")
            .unwrap();
        assert_eq!(call["arguments"], arguments);
    }
}
