use crate::{log::LogBuffer, process::OwnedProcess, sdk::SdkInfo};
use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    path::Path,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::{broadcast, oneshot, watch, Mutex},
};

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum RunMode {
    Debug,
    Profile,
    Release,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EnvVar {
    pub name: String,
    pub value: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RunConfiguration {
    pub project_path: String,
    pub sdk_path: String,
    pub program: String,
    pub device_id: String,
    pub mode: RunMode,
    pub no_debug: bool,
    pub attach_uri: Option<String>,
    pub env: Vec<EnvVar>,
    pub tool_args: Vec<String>,
    pub args: Vec<String>,
    pub flavor: Option<String>,
    pub dart_defines: Vec<String>,
}

#[cfg(all(test, unix))]
pub(crate) mod tests {
    use super::*;
    use std::{fs, os::unix::fs::PermissionsExt};
    pub(crate) fn fake_sdk(slow: bool) -> tempfile::TempDir {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        fs::create_dir_all(root.join("bin")).unwrap();
        fs::write(
            root.join("pubspec.yaml"),
            "name: fixture\ndependencies:\n  flutter:\n    sdk: flutter\n",
        )
        .unwrap();
        fs::create_dir_all(root.join("lib")).unwrap();
        fs::write(root.join("lib/main.dart"), "void main() {}\n").unwrap();
        let script = format!(
            "#!/usr/bin/env python3\nSLOW = {}\n",
            if slow { "True" } else { "False" }
        ) + r#"
import json, os, sys, time, threading
root=os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
def record(value):
    with open(os.path.join(root,'requests.jsonl'),'a') as f: f.write(json.dumps(value)+'\n')
record({'invocation':sys.argv[1:],'pid':os.getpid()})
if '--version' in sys.argv:
    if SLOW: time.sleep(.15)
    print(json.dumps({'frameworkVersion':'3.fixture','dartSdkVersion':'3.fixture'}));sys.exit(0)
if 'daemon' in sys.argv:
    device={'id':'ready-device','name':'Emulator','platform':'android-x64','platformType':'android','emulator':True,'emulatorId':'fixture-emulator'}
    def added():
        time.sleep(.15)
        print(json.dumps([{'event':'device.added','params':device}]),flush=True)
    for line in sys.stdin:
        for request in json.loads(line):
            record(request);method=request['method'];result=None
            if method=='device.getDevices':result=[]
            if method=='emulator.getEmulators':result=[{'id':'fixture-emulator','name':'Fixture','platformType':'android'}]
            print(json.dumps([{'id':request['id'],'result':result}]),flush=True)
            if method=='emulator.launch':threading.Thread(target=added,daemon=True).start()
            if method=='daemon.shutdown':sys.exit(0)
    sys.exit(0)
seq=1;launch=None
def send(value):
    global seq
    value['seq']=seq;seq+=1
    body=json.dumps(value).encode();sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(body)).encode()+body);sys.stdout.buffer.flush()
def response(request,body=None,success=True,message=None):
    value={'type':'response','request_seq':request['seq'],'command':request['command'],'success':success,'body':body or {}}
    if message:value['message']=message
    send(value)
def event(name,body=None):send({'type':'event','event':name,'body':body or {}})
while True:
    length=None
    while True:
        line=sys.stdin.buffer.readline()
        if not line:sys.exit(0)
        if line.lower().startswith(b'content-length:'):length=int(line.split(b':')[1])
        if line==b'\r\n':break
    request=json.loads(sys.stdin.buffer.read(length));record(request);command=request['command']
    if command=='initialize':
        if os.environ.get('DELAY_INITIALIZE'):time.sleep(.2)
        response(request,{'supportsConfigurationDoneRequest':True})
    elif command in ('launch','attach'):
        launch=request;event('initialized')
    elif command=='configurationDone':
        response(request);response(launch);event('flutter.appStarted');event('dart.debuggerUris',{'vmServiceUri':'http://127.0.0.1:1234/token/'});event('thread',{'threadId':1,'reason':'started'})
        sys.stderr.write('adapter diagnostic\n');sys.stderr.flush();event('output',{'category':'stdout','output':'hello fixture\n'})
    elif command=='hotReload':
        if os.environ.get('DELAY_HOT_RELOAD'):time.sleep(1.2)
        response(request,success=False,message='fixture compile error')
    elif command=='ignore':pass
    elif command=='blockRead':response(request);time.sleep(60)
    elif command=='fixtureExit':response(request);event('exited',{'exitCode':1})
    elif command=='disconnect':response(request);event('terminated');sys.exit(0)
    else:response(request)
"#;
        fs::write(root.join("bin/flutter"), script).unwrap();
        fs::set_permissions(root.join("bin/flutter"), fs::Permissions::from_mode(0o755)).unwrap();
        directory
    }
    fn config(root: &Path, attach: bool) -> RunConfiguration {
        RunConfiguration {
            project_path: root.to_string_lossy().into_owned(),
            sdk_path: root.to_string_lossy().into_owned(),
            program: "lib/main.dart".into(),
            device_id: "ready-device".into(),
            mode: RunMode::Debug,
            no_debug: false,
            attach_uri: attach.then(|| "http://127.0.0.1:1234/token/".into()),
            env: vec![],
            tool_args: vec![],
            args: vec![],
            flavor: None,
            dart_defines: vec![],
        }
    }

    #[test]
    fn device_dart_output_and_unprefixed_continuations_are_not_session_owned() {
        let mut logs = LogBuffer::new(100, 4096);
        for category in ["stdout", "console"] {
            for output in [
                "flutter: foreign project",
                "foreign continuation without a prefix",
            ] {
                record_adapter_output(
                    &mut logs,
                    &json!({"category":category,"output":output}),
                    true,
                );
            }
        }
        assert!(logs.query(None, 100, None).entries.is_empty());
        record_adapter_output(
            &mut logs,
            &json!({"category":"stderr","output":"compiler diagnostic"}),
            true,
        );
        let page = logs.query(None, 100, None);
        assert_eq!(page.entries[0].text, "compiler diagnostic");
        assert_eq!(page.entries[0].category, "stderr");
        // Attach and Release retain their existing adapter output behavior.
        record_adapter_output(
            &mut logs,
            &json!({"category":"stdout","output":"flutter: original output"}),
            false,
        );
        assert_eq!(
            logs.query(None, 100, None).entries.last().unwrap().text,
            "flutter: original output"
        );
    }

    #[test]
    fn ios_ports_match_for_simulator_discovery_and_keep_dds_separate() {
        let mut args = vec![
            "--flavor".into(),
            "a b".into(),
            "--device-vmservice-port=0".into(),
        ];
        let port = ios_vm_service_arguments(&mut args).unwrap();
        assert_ne!(port.port(), 0);
        assert_eq!(&args[..2], ["--flavor", "a b"]);
        assert!(args.contains(&format!("--device-vmservice-port={}", port.port())));
        assert!(args.contains(&format!("--host-vmservice-port={}", port.port())));
        assert!(args.contains(&"--dds-port=0".into()));
        let mut conflicting = vec![
            "--device-vmservice-port".into(),
            "1234".into(),
            "--host-vmservice-port=1235".into(),
        ];
        assert!(ios_vm_service_arguments(&mut conflicting).is_err());
        let mut duplicate = vec![
            "--vm-service-port=1234".into(),
            "--host-vmservice-port=1234".into(),
        ];
        assert!(ios_vm_service_arguments(&mut duplicate).is_err());
        let mut missing = vec!["--device-vmservice-port".into()];
        assert!(ios_vm_service_arguments(&mut missing).is_err());
        let mut invalid = vec!["--dds-port=65536".into()];
        assert!(ios_vm_service_arguments(&mut invalid).is_err());
    }

    #[tokio::test]
    async fn ios_progress_keeps_startup_status_and_terminal_state_releases_port() {
        let sdk = fake_sdk(false);
        let (events, _) = broadcast::channel(100);
        let session = Session::new(
            "ios-progress".into(),
            config(sdk.path(), false),
            events,
            Ok(true),
        );
        let port = crate::vm_logs::ReservedVmPort::reserve(None).unwrap();
        let number = port.port();
        *session.vm_port.lock().await = Some(port);
        session
            .handle_event(
                json!({"event":"progressUpdate","body":{"message":"Running Xcode build…"}}),
            )
            .await;
        assert_eq!(
            session.logs.lock().await.query(None, 10, None).entries[0].text,
            "Running Xcode build…"
        );
        session
            .state(SessionState::Failed, Some("fixture startup failure".into()))
            .await;
        assert!(session.vm_port.lock().await.is_none());
        assert!(crate::vm_logs::ReservedVmPort::reserve(Some(number)).is_ok());
    }

    #[tokio::test]
    async fn device_discovery_failure_cannot_fall_back_to_mixed_device_logs() {
        let sdk = fake_sdk(false);
        let (events, _) = broadcast::channel(100);
        let session = Session::new(
            "device-discovery-error".into(),
            config(sdk.path(), false),
            events,
            Err(anyhow!("SDK device discovery failed")),
        );
        session.clone().run().await;
        assert_eq!(session.snapshot.lock().await.state, SessionState::Failed);
        assert!(session.peer.lock().await.is_none());
        let requests = fs::read_to_string(sdk.path().join("requests.jsonl")).unwrap();
        assert!(!requests.contains("debug-adapter"));
    }

    #[tokio::test]
    async fn vm_output_subscription_reuses_uri_and_cancels_on_stop() {
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::accept_async;

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let uri = format!("http://{}/token/", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let mut socket = accept_async(listener.accept().await.unwrap().0)
                .await
                .unwrap();
            for _ in 0..2 {
                let request: Value =
                    serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap())
                        .unwrap();
                socket
                    .send(
                        json!({"jsonrpc":"2.0","id":request["id"],"result":{"type":"Success"}})
                            .to_string()
                            .into(),
                    )
                    .await
                    .unwrap();
            }
            socket.send(json!({"method":"streamNotify","params":{"streamId":"Stdout","event":{"bytes":"b3duIHByb2plY3QK"}}}).to_string().into()).await.unwrap();
            // Cancelling the session must close its VM connection.
            tokio::time::timeout(Duration::from_secs(5), socket.next())
                .await
                .unwrap();
        });
        let sdk = fake_sdk(false);
        let (events, _) = broadcast::channel(100);
        let session = Session::new(
            "vm-output".into(),
            config(sdk.path(), false),
            events,
            Ok(true),
        );
        session.state(SessionState::Running, None).await;
        session.start_vm_output(&uri).await;
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if session.logs.lock().await.latest_id() > 0 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        let first_task = session.vm_output.lock().await.as_ref().unwrap().1.id();
        session.start_vm_output(&uri).await;
        assert_eq!(
            session.vm_output.lock().await.as_ref().unwrap().1.id(),
            first_task
        );
        assert_eq!(
            session.logs.lock().await.query(None, 100, None).entries[0].text,
            "own project"
        );
        session.stop().await.unwrap();
        assert!(session.vm_output.lock().await.is_none());
        server.await.unwrap();
        // Late URI events cannot reconnect an ended session.
        session.start_vm_output(&uri).await;
        assert!(session.vm_output.lock().await.is_none());
    }
    async fn wait_state(session: &Session, state: SessionState) {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if session.snapshot.lock().await.state == state {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn oversized_service_response_preserves_adapter_and_debug_requests() {
        let sdk = fake_sdk(false);
        let script_path = sdk.path().join("bin/flutter");
        let script = fs::read_to_string(&script_path).unwrap().replace(
            "elif command=='hotReload':",
            "elif command=='callService':send({'seq':0,'type':'response','body':{'type':'HttpProfileRequest','bytes':'x'*(17*1024*1024)},'command':'callService','request_seq':request['seq'],'success':True})\n    elif command=='hotReload':",
        );
        fs::write(script_path, script).unwrap();
        let (events, _) = broadcast::channel(100);
        let session = Session::new(
            "oversized-service-test".into(),
            config(sdk.path(), false),
            events,
            Ok(false),
        );
        let runner = session.clone();
        let task = tokio::spawn(async move { runner.run().await });
        wait_state(&session, SessionState::Running).await;
        task.await.unwrap();
        let error = session.request(
            "callService",
            json!({"method":"ext.dart.io.getHttpProfileRequest","params":{"id":"1","isolateId":"isolates/1"}}),
            Duration::from_secs(5),
        ).await.unwrap_err();
        assert!(error.to_string().contains("exceeds 16 MiB"));
        let response = session
            .request("threads", json!({}), Duration::from_secs(5))
            .await
            .unwrap();
        assert_eq!(response, json!({}));
        assert_eq!(session.snapshot.lock().await.state, SessionState::Running);
        session.stop().await.unwrap();
    }

    #[tokio::test]
    async fn configuration_handshake_and_attach_disconnect_preserve_target() {
        let sdk = fake_sdk(false);
        let (events, _) = broadcast::channel(100);
        let session = Session::new(
            "attach-test".into(),
            config(sdk.path(), true),
            events,
            Ok(false),
        );
        let runner = session.clone();
        let task = tokio::spawn(async move { runner.run().await });
        wait_state(&session, SessionState::Running).await;
        task.await.unwrap();
        assert_eq!(
            session.snapshot.lock().await.service_uri.as_deref(),
            Some("http://127.0.0.1:1234/token/")
        );
        assert!(session.hot_update(false).await.is_err());
        assert_eq!(session.snapshot.lock().await.state, SessionState::Running);
        let timeout = session
            .request("ignore", json!({}), Duration::from_millis(50))
            .await
            .unwrap_err();
        assert!(timeout.to_string().contains("timed out"));
        assert!(session
            .peer
            .lock()
            .await
            .as_ref()
            .unwrap()
            .pending
            .lock()
            .await
            .is_empty());
        session.stop().await.unwrap();
        assert_eq!(session.snapshot.lock().await.state, SessionState::Ended);
        let requests: Vec<Value> = fs::read_to_string(sdk.path().join("requests.jsonl"))
            .unwrap()
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect();
        let disconnect = requests
            .iter()
            .find(|v| v["command"] == "disconnect")
            .unwrap();
        assert_eq!(disconnect["arguments"]["terminateDebuggee"], false);
        assert_eq!(
            requests.iter().filter(|v| v["command"] == "attach").count(),
            1
        );
        assert!(session
            .logs
            .lock()
            .await
            .query(None, 100, None)
            .entries
            .iter()
            .any(|l| l.text.contains("hello fixture")));
    }
    #[tokio::test]
    async fn launch_stops_owned_target_and_cancelled_prepare_never_launches() {
        let sdk = fake_sdk(false);
        let (events, _) = broadcast::channel(100);
        let session = Session::new(
            "launch-test".into(),
            config(sdk.path(), false),
            events,
            Ok(false),
        );
        let runner = session.clone();
        let task = tokio::spawn(async move { runner.run().await });
        wait_state(&session, SessionState::Running).await;
        task.await.unwrap();
        session.stop().await.unwrap();
        let requests: Vec<Value> = fs::read_to_string(sdk.path().join("requests.jsonl"))
            .unwrap()
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect();
        assert_eq!(
            requests
                .iter()
                .find(|v| v["command"] == "disconnect")
                .unwrap()["arguments"]["terminateDebuggee"],
            true
        );
        let slow = fake_sdk(true);
        let (events, _) = broadcast::channel(100);
        let session = Session::new(
            "cancel-test".into(),
            config(slow.path(), false),
            events,
            Ok(false),
        );
        let runner = session.clone();
        let task = tokio::spawn(async move { runner.run().await });
        session.stop().await.unwrap();
        task.await.unwrap();
        assert_eq!(session.snapshot.lock().await.state, SessionState::Ended);
        let requests = fs::read_to_string(slow.path().join("requests.jsonl")).unwrap_or_default();
        assert!(!requests.contains("debug-adapter"));
    }
    #[tokio::test]
    async fn cancel_during_initialize_cannot_send_launch() {
        let sdk = fake_sdk(false);
        let (events, _) = broadcast::channel(100);
        let mut configuration = config(sdk.path(), false);
        configuration.env.push(EnvVar {
            name: "DELAY_INITIALIZE".into(),
            value: "1".into(),
        });
        let session = Session::new("cancel-initialize".into(), configuration, events, Ok(false));
        let runner = session.clone();
        let task = tokio::spawn(async move { runner.run().await });
        wait_state(&session, SessionState::Starting).await;
        session.stop().await.unwrap();
        task.await.unwrap();
        let requests: Vec<Value> = fs::read_to_string(sdk.path().join("requests.jsonl"))
            .unwrap()
            .lines()
            .map(|s| serde_json::from_str(s).unwrap())
            .collect();
        assert!(!requests.iter().any(|v| v["command"] == "launch"));
        assert_eq!(session.snapshot.lock().await.state, SessionState::Ended);
    }
    #[tokio::test]
    async fn nonzero_exit_and_blocked_writer_reclaim_adapter() {
        let sdk = fake_sdk(false);
        let (events, _) = broadcast::channel(100);
        let session = Session::new(
            "failed-exit".into(),
            config(sdk.path(), false),
            events,
            Ok(false),
        );
        let runner = session.clone();
        let task = tokio::spawn(async move { runner.run().await });
        wait_state(&session, SessionState::Running).await;
        task.await.unwrap();
        session
            .request("fixtureExit", json!({}), Duration::from_secs(1))
            .await
            .unwrap();
        wait_state(&session, SessionState::Failed).await;
        session.stop().await.unwrap();
        assert!(session.peer.lock().await.is_none());
        let sdk = fake_sdk(false);
        let sdk_info =
            crate::sdk::resolve_sdk(None, Some(sdk.path().to_string_lossy().into_owned()))
                .await
                .unwrap();
        let peer = ProtocolPeer::spawn(
            &sdk_info,
            &["debug-adapter".into()],
            None,
            &HashMap::new(),
            WireProtocol::Dap,
            None,
            false,
        )
        .unwrap();
        peer.request("blockRead", json!({}), Duration::from_secs(1))
            .await
            .unwrap();
        let start = std::time::Instant::now();
        let error = peer
            .request(
                "blocked",
                json!({"data":"x".repeat(512*1024)}),
                Duration::from_millis(50),
            )
            .await
            .unwrap_err();
        assert!(error.to_string().contains("write timed out"));
        assert!(start.elapsed() < Duration::from_secs(3));
        assert!(peer.pending.lock().await.is_empty());
        assert!(peer.is_closed());
    }
    #[tokio::test]
    async fn isolate_pause_state_waits_for_all_paused_isolates() {
        let sdk = fake_sdk(false);
        let (events, _) = broadcast::channel(100);
        let session = Session::new(
            "isolates".into(),
            config(sdk.path(), false),
            events,
            Ok(false),
        );
        session
            .handle_event(json!({"event":"stopped","body":{"threadId":1}}))
            .await;
        session
            .handle_event(json!({"event":"stopped","body":{"threadId":2}}))
            .await;
        session
            .handle_event(
                json!({"event":"continued","body":{"threadId":1,"allThreadsContinued":false}}),
            )
            .await;
        assert_eq!(session.snapshot.lock().await.state, SessionState::Paused);
        session
            .handle_event(
                json!({"event":"continued","body":{"threadId":2,"allThreadsContinued":false}}),
            )
            .await;
        assert_eq!(session.snapshot.lock().await.state, SessionState::Running);
    }
    #[tokio::test]
    async fn automatic_reload_busy_guard_does_not_attempt_or_consume_request() {
        let sdk = fake_sdk(false);
        let (events, _) = broadcast::channel(100);
        let session = Session::new(
            "auto-busy".into(),
            config(sdk.path(), false),
            events,
            Ok(false),
        );
        session.set_auto_reload(true);
        let runner = tokio::spawn(session.clone().run());
        wait_state(&session, SessionState::Running).await;
        let held = session.operation_lock.lock().await;
        assert!(session.try_automatic_hot_reload().await.is_none());
        drop(held);
        // A real DAP attempt, including compile failure, consumes one revision.
        assert!(session.try_automatic_hot_reload().await.unwrap().is_err());
        session.set_auto_reload(false);
        assert!(session.try_automatic_hot_reload().await.is_none());
        session.stop().await.unwrap();
        runner.await.unwrap();
    }

    #[tokio::test]
    async fn source_saved_during_reload_is_reloaded_after_current_request_finishes() {
        let sdk = fake_sdk(false);
        let mut configuration = config(sdk.path(), false);
        configuration.env.push(EnvVar {
            name: "DELAY_HOT_RELOAD".into(),
            value: "1".into(),
        });
        let (events, _) = broadcast::channel(100);
        let session = Session::new("auto-followup".into(), configuration, events, Ok(false));
        session.set_auto_reload(true);
        crate::auto_reload::start(session.clone());
        let runner = tokio::spawn(session.clone().run());
        wait_state(&session, SessionState::Running).await;
        tokio::time::timeout(Duration::from_secs(5), async {
            while session
                .logs
                .lock()
                .await
                .query(None, 100, Some("Automatic hot reload monitoring ready"))
                .entries
                .is_empty()
            {
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .unwrap();
        let held = session.operation_lock.lock().await;
        fs::write(
            sdk.path().join("lib/main.dart"),
            "void main() { print('one'); }",
        )
        .unwrap();
        tokio::time::sleep(Duration::from_millis(1200)).await;
        let count = || {
            fs::read_to_string(sdk.path().join("requests.jsonl"))
                .unwrap_or_default()
                .lines()
                .filter(|line| {
                    serde_json::from_str::<Value>(line).unwrap()["command"] == "hotReload"
                })
                .count()
        };
        assert_eq!(
            count(),
            0,
            "busy lock must preserve the pending source revision"
        );
        drop(held);
        tokio::time::timeout(Duration::from_secs(5), async {
            while count() < 1 {
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .unwrap();
        fs::write(
            sdk.path().join("lib/main.dart"),
            "void main() { print('saved during request'); }",
        )
        .unwrap();
        tokio::time::timeout(Duration::from_secs(6), async {
            while count() < 2 {
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .unwrap();
        tokio::time::sleep(Duration::from_millis(1800)).await;
        assert_eq!(
            count(),
            2,
            "compile failure must not retry the same revision forever"
        );
        session.stop().await.unwrap();
        runner.await.unwrap();
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum SessionState {
    Preparing,
    Starting,
    Running,
    Paused,
    Stopping,
    Ended,
    Failed,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DebugThread {
    pub id: i64,
    pub name: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SessionSnapshot {
    pub session_id: String,
    pub generation: u64,
    pub sequence: u64,
    pub state: SessionState,
    pub operation: Option<String>,
    pub project_path: String,
    pub sdk_path: String,
    pub device_id: String,
    pub mode: RunMode,
    pub no_debug: bool,
    pub attached: bool,
    pub service_uri: Option<String>,
    pub error: Option<String>,
    pub capabilities_json: String,
    pub threads: Vec<DebugThread>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum CoreEventKind {
    State,
    OutputAvailable,
    Debugger,
    DevicesChanged,
    ServiceUri,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CoreEvent {
    pub session_id: String,
    pub generation: u64,
    pub sequence: u64,
    pub kind: CoreEventKind,
    pub payload: String,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub enum DebugAction {
    Pause,
    Continue,
    Next,
    StepIn,
    StepOut,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SourceBreakpoint {
    pub line: i64,
    pub condition: Option<String>,
    pub hit_condition: Option<String>,
    pub log_message: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsonResponse {
    pub json: String,
}

#[derive(Clone, Copy)]
pub(crate) enum WireProtocol {
    Dap,
    Daemon,
}
/// One owner, continuously drained pipes, and bounded outstanding requests.
pub(crate) struct ProtocolPeer {
    protocol: WireProtocol,
    writer: Mutex<tokio::process::ChildStdin>,
    pending: Mutex<HashMap<u64, oneshot::Sender<Result<Value>>>>,
    serial: AtomicU64,
    process: Mutex<OwnedProcess>,
    pub(crate) events: broadcast::Sender<Value>,
    closed: watch::Sender<bool>,
}
impl ProtocolPeer {
    pub(crate) fn spawn(
        sdk: &SdkInfo,
        args: &[String],
        cwd: Option<&Path>,
        env: &HashMap<String, String>,
        protocol: WireProtocol,
        logs: Option<Arc<Mutex<LogBuffer>>>,
        isolate_dart_output: bool,
    ) -> Result<Arc<Self>> {
        let mut process =
            OwnedProcess::spawn(&crate::process::flutter_program(sdk), args, cwd, env)?;
        let stdin = process.stdin.take().context("missing SDK stdin")?;
        let mut stdout = process.stdout.take().context("missing SDK stdout")?;
        let mut stderr = process.stderr.take().context("missing SDK stderr")?;
        let (events, _) = broadcast::channel(1024);
        let (closed, _) = watch::channel(false);
        let peer = Arc::new(Self {
            protocol,
            writer: Mutex::new(stdin),
            pending: Mutex::new(HashMap::new()),
            serial: AtomicU64::new(1),
            process: Mutex::new(process),
            events,
            closed,
        });
        let reader = peer.clone();
        let output_logs = logs.clone();
        tokio::spawn(async move {
            let mut dap = crate::protocol::dap::DapDecoder::default();
            let mut daemon = crate::protocol::daemon::DaemonDecoder::default();
            let mut bytes = [0u8; 8192];
            let reason = loop {
                let count = match stdout.read(&mut bytes).await {
                    Ok(0) => break "SDK process stdout closed".to_owned(),
                    Ok(n) => n,
                    Err(e) => break e.to_string(),
                };
                let parsed = match protocol {
                    WireProtocol::Dap => dap.push(&bytes[..count]),
                    WireProtocol::Daemon => daemon.push(&bytes[..count]),
                };
                match parsed {
                    Err(e) => break format!("Invalid SDK protocol: {e}"),
                    Ok(messages) => {
                        for message in messages {
                            let id = match protocol {
                                WireProtocol::Dap if message["type"] == "response" => {
                                    message["request_seq"].as_u64()
                                }
                                WireProtocol::Daemon => message["id"].as_u64(),
                                _ => None,
                            };
                            if let Some(id) = id {
                                if let Some(sender) = reader.pending.lock().await.remove(&id) {
                                    let result = if message["success"] == false
                                        || message.get("error").is_some()
                                    {
                                        Err(anyhow!(
                                            "{}",
                                            message
                                                .get("message")
                                                .or(message.get("error"))
                                                .unwrap_or(&message)
                                        ))
                                    } else {
                                        Ok(match protocol {
                                            WireProtocol::Dap => message["body"].clone(),
                                            WireProtocol::Daemon => message["result"].clone(),
                                        })
                                    };
                                    let _ = sender.send(result);
                                }
                            } else {
                                if matches!(message["event"].as_str(), Some("output" | "dart.log"))
                                {
                                    if let Some(logs) = output_logs.as_ref() {
                                        let body = &message["body"];
                                        record_adapter_output(
                                            &mut *logs.lock().await,
                                            body,
                                            isolate_dart_output && message["event"] == "output",
                                        );
                                        continue;
                                    }
                                }
                                let _ = reader.events.send(message);
                            }
                        }
                    }
                }
            };
            reader.closed.send_replace(true);
            for (_, sender) in reader.pending.lock().await.drain() {
                let _ = sender.send(Err(anyhow!(reason.clone())));
            }
            let _ = reader.events.send(json!({"_fault": reason}));
            // Protocol faults/EOF also reclaim only this peer's process group.
            let _ = reader
                .process
                .lock()
                .await
                .terminate(Duration::from_secs(2))
                .await;
        });
        let stderr_peer = Arc::downgrade(&peer);
        tokio::spawn(async move {
            let mut bytes = [0u8; 8192];
            while let Ok(n) = stderr.read(&mut bytes).await {
                if n == 0 {
                    break;
                }
                if let Some(logs) = logs.as_ref() {
                    logs.lock()
                        .await
                        .push("stderr", &String::from_utf8_lossy(&bytes[..n]));
                } else if let Some(peer) = stderr_peer.upgrade() {
                    let _ = peer
                        .events
                        .send(json!({"_stderr":String::from_utf8_lossy(&bytes[..n])}));
                } else {
                    break;
                }
            }
        });
        Ok(peer)
    }
    async fn begin_request(
        &self,
        command: &str,
        arguments: Value,
        timeout: Duration,
    ) -> Result<(u64, oneshot::Receiver<Result<Value>>, tokio::time::Instant)> {
        if *self.closed.borrow() {
            bail!("SDK process is closed");
        }
        let deadline = tokio::time::Instant::now() + timeout;
        let id = self.serial.fetch_add(1, Ordering::Relaxed);
        let message = match self.protocol {
            WireProtocol::Dap => {
                json!({"seq":id,"type":"request","command":command,"arguments":arguments})
            }
            WireProtocol::Daemon => json!({"id":id,"method":command,"params":arguments}),
        };
        // Encode before registering so malformed/oversized requests leave no pending entry.
        let bytes = match self.protocol {
            WireProtocol::Dap => crate::protocol::dap::encode(&message),
            WireProtocol::Daemon => crate::protocol::daemon::encode(&message),
        }?;
        let (sender, receiver) = oneshot::channel();
        {
            let mut pending = self.pending.lock().await;
            if pending.len() >= 128 {
                bail!("Too many pending SDK requests");
            }
            pending.insert(id, sender);
        }
        // A blocked writer must not prevent cancellation or forced cleanup.
        let write_deadline = deadline.min(tokio::time::Instant::now() + Duration::from_secs(5));
        let write = tokio::time::timeout_at(write_deadline, async {
            self.writer.lock().await.write_all(&bytes).await
        })
        .await;
        let error = match write {
            Ok(Ok(())) => None,
            Ok(Err(e)) => Some(anyhow!(e)),
            Err(_) => Some(anyhow!("SDK request {command} write timed out")),
        };
        if let Some(error) = error {
            self.pending.lock().await.remove(&id);
            self.closed.send_replace(true);
            let _ = self.events.send(json!({"_fault":error.to_string()}));
            // A partial frame cannot be reused; close this owned peer immediately.
            let _ = self
                .process
                .lock()
                .await
                .terminate(Duration::from_secs(2))
                .await;
            return Err(error);
        }
        Ok((id, receiver, deadline))
    }
    async fn finish_request(
        &self,
        command: &str,
        ticket: (u64, oneshot::Receiver<Result<Value>>, tokio::time::Instant),
    ) -> Result<Value> {
        let (id, receiver, deadline) = ticket;
        let result = tokio::time::timeout_at(deadline, receiver).await;
        self.pending.lock().await.remove(&id);
        result
            .map_err(|_| anyhow!("SDK request {command} timed out"))?
            .map_err(|_| anyhow!("SDK request {command} cancelled"))?
    }
    pub(crate) async fn request(
        &self,
        command: &str,
        arguments: Value,
        timeout: Duration,
    ) -> Result<Value> {
        let ticket = self.begin_request(command, arguments, timeout).await?;
        self.finish_request(command, ticket).await
    }
    pub(crate) async fn terminate(&self) -> Result<()> {
        self.closed.send_replace(true);
        self.process
            .lock()
            .await
            .terminate(Duration::from_secs(3))
            .await
    }
    pub(crate) fn is_closed(&self) -> bool {
        *self.closed.borrow()
    }
}

fn record_adapter_output(logs: &mut LogBuffer, body: &Value, isolate_dart_output: bool) {
    let category = body["category"].as_str().unwrap_or("stdout");
    let text = body["output"]
        .as_str()
        .or(body["message"].as_str())
        .unwrap_or("");
    if isolate_dart_output {
        // iOS device logs are filtered by executable name (usually Runner),
        // not by process. Their Dart output may belong to another application.
        // Multiline continuation lines have no ownership or prefix. The SDK
        // labels stdout as console before appStarted, so both are unsafe.
        // Tool errors use stderr; startup status comes from DAP progress.
        if category != "stdout" && category != "console" {
            logs.push(category, text);
        }
    } else {
        logs.push(category, text);
    }
}

fn ios_vm_service_arguments(args: &mut Vec<String>) -> Result<crate::vm_logs::ReservedVmPort> {
    let mut retained = Vec::with_capacity(args.len() + 3);
    let mut device_port = None;
    let mut host_port = None;
    let mut dds_port = None;
    let mut index = 0;
    while index < args.len() {
        let (name, inline) = args[index]
            .split_once('=')
            .map_or((args[index].as_str(), None), |(name, value)| {
                (name, Some(value))
            });
        let destination = match name {
            "--device-vmservice-port" => &mut device_port,
            "--host-vmservice-port" | "--vm-service-port" => &mut host_port,
            "--dds-port" => &mut dds_port,
            _ => {
                retained.push(args[index].clone());
                index += 1;
                continue;
            }
        };
        if destination.is_some() {
            bail!("Duplicate iOS VM service port option: {name}");
        }
        let value = if let Some(value) = inline {
            value
        } else {
            index += 1;
            args.get(index)
                .context("Missing iOS VM service port value")?
        };
        *destination = Some(
            value
                .parse::<u16>()
                .context("Invalid iOS VM service port")?,
        );
        index += 1;
    }
    let requested = device_port.filter(|port| *port != 0);
    let host = host_port.filter(|port| *port != 0);
    if requested.is_some() && host.is_some() && requested != host {
        bail!("iOS log isolation requires matching device and host VM service ports");
    }
    let port = crate::vm_logs::ReservedVmPort::reserve(requested.or(host))?;
    if dds_port == Some(port.port()) {
        bail!("DDS and the iOS VM service must use different ports");
    }
    retained.extend([
        format!("--device-vmservice-port={}", port.port()),
        format!("--host-vmservice-port={}", port.port()),
        // An explicit DDS port keeps Flutter from repurposing the simulator's
        // host VM port for DDS and starting its VM on a random port instead.
        format!("--dds-port={}", dds_port.unwrap_or(0)),
    ]);
    *args = retained;
    Ok(port)
}

pub(crate) struct Session {
    pub(crate) snapshot: Mutex<SessionSnapshot>,
    config: RunConfiguration,
    pub(crate) logs: Arc<Mutex<LogBuffer>>,
    peer: Mutex<Option<Arc<ProtocolPeer>>>,
    events: broadcast::Sender<CoreEvent>,
    initialized: watch::Sender<bool>,
    state_changed: watch::Sender<SessionState>,
    paused_threads: Mutex<HashSet<i64>>,
    operation_lock: Mutex<()>,
    pub(crate) auto_reload: watch::Sender<bool>,
    vm_output: Mutex<Option<(String, tokio::task::JoinHandle<()>)>>,
    isolate_device_logs: bool,
    device_setup_error: Option<String>,
    vm_port: Mutex<Option<crate::vm_logs::ReservedVmPort>>,
}
impl Session {
    pub(crate) fn new(
        id: String,
        config: RunConfiguration,
        events: broadcast::Sender<CoreEvent>,
        isolate_device_logs: Result<bool>,
    ) -> Arc<Self> {
        let (isolate_device_logs, device_setup_error) = match isolate_device_logs {
            Ok(enabled) => (enabled, None),
            Err(error) => (false, Some(error.to_string())),
        };
        let snapshot = SessionSnapshot {
            session_id: id,
            generation: 1,
            sequence: 0,
            state: SessionState::Preparing,
            operation: None,
            project_path: config.project_path.clone(),
            sdk_path: config.sdk_path.clone(),
            device_id: config.device_id.clone(),
            mode: config.mode,
            no_debug: config.no_debug,
            attached: config.attach_uri.is_some(),
            service_uri: None,
            error: None,
            capabilities_json: "{}".into(),
            threads: vec![],
        };
        let (initialized, _) = watch::channel(false);
        let (state_changed, _) = watch::channel(SessionState::Preparing);
        Arc::new(Self {
            snapshot: Mutex::new(snapshot),
            device_setup_error,
            isolate_device_logs: isolate_device_logs
                && config.mode != RunMode::Release
                && config.attach_uri.is_none(),
            config,
            logs: Arc::new(Mutex::new(LogBuffer::new(10000, 4 * 1024 * 1024))),
            peer: Mutex::new(None),
            events,
            initialized,
            state_changed,
            paused_threads: Mutex::new(HashSet::new()),
            operation_lock: Mutex::new(()),
            auto_reload: watch::channel(false).0,
            vm_output: Mutex::new(None),
            vm_port: Mutex::new(None),
        })
    }
    pub(crate) fn set_auto_reload(&self, enabled: bool) {
        self.auto_reload.send_if_modified(|current| {
            if *current == enabled {
                return false;
            }
            *current = enabled;
            true
        });
    }
    pub(crate) fn subscribe_state(&self) -> watch::Receiver<SessionState> {
        self.state_changed.subscribe()
    }
    pub(crate) async fn emit(&self, kind: CoreEventKind, payload: Option<String>) {
        let mut snapshot = self.snapshot.lock().await;
        snapshot.sequence += 1;
        let payload =
            payload.unwrap_or_else(|| serde_json::to_string(&*snapshot).unwrap_or_default());
        let _ = self.events.send(CoreEvent {
            session_id: snapshot.session_id.clone(),
            generation: snapshot.generation,
            sequence: snapshot.sequence,
            kind,
            payload,
        });
    }
    async fn state(&self, state: SessionState, error: Option<String>) {
        {
            let mut snapshot = self.snapshot.lock().await;
            if matches!(snapshot.state, SessionState::Ended | SessionState::Failed)
                || (snapshot.state == SessionState::Stopping
                    && !matches!(state, SessionState::Ended | SessionState::Failed))
            {
                return;
            }
            snapshot.state = state;
            self.state_changed.send_replace(state);
            snapshot.error = error;
            if matches!(state, SessionState::Ended | SessionState::Failed) {
                snapshot.operation = None;
                snapshot.service_uri = None;
            }
        }
        if matches!(
            state,
            SessionState::Stopping | SessionState::Ended | SessionState::Failed
        ) {
            if let Some((_, task)) = self.vm_output.lock().await.take() {
                task.abort();
                let _ = task.await;
            }
        }
        if matches!(state, SessionState::Ended | SessionState::Failed) {
            self.vm_port.lock().await.take();
        }
        self.emit(CoreEventKind::State, None).await;
    }
    pub(crate) async fn run(self: Arc<Self>) {
        if let Err(e) = self.start().await {
            self.state(SessionState::Failed, Some(e.to_string())).await;
            if let Some(peer) = self.peer.lock().await.as_ref() {
                let _ = peer.terminate().await;
            }
        }
    }
    async fn start(self: &Arc<Self>) -> Result<()> {
        let mut preparing = self.state_changed.subscribe();
        let cancelled = async {
            while *preparing.borrow_and_update() == SessionState::Preparing {
                if preparing.changed().await.is_err() {
                    break;
                }
            }
        };
        // Dropping SDK resolution also drops its owned version-probe process.
        let sdk = tokio::select! {
            result=crate::sdk::resolve_sdk(Some(self.config.project_path.clone()),Some(self.config.sdk_path.clone()))=>result?,
            _=cancelled=>return Ok(()),
        };
        self.snapshot.lock().await.sdk_path = sdk.path.clone();
        if let Some(reason) = &sdk.fallback_reason {
            self.logs.lock().await.push(
                "warning",
                &format!(
                    "Project SDK unavailable; using global SDK {}: {reason}",
                    sdk.path
                ),
            );
        }
        self.emit(CoreEventKind::State, None).await;
        if let Some(error) = &self.device_setup_error {
            bail!("{error}");
        }
        let cwd = Path::new(&self.config.project_path);
        if !cwd.join("pubspec.yaml").is_file() {
            bail!("Select a Flutter package containing pubspec.yaml");
        }
        let mut pubspec_file = tokio::fs::File::open(cwd.join("pubspec.yaml")).await?;
        let mut content = vec![];
        (&mut pubspec_file)
            .take(1024 * 1024 + 1)
            .read_to_end(&mut content)
            .await?;
        if content.len() > 1024 * 1024 {
            bail!("pubspec.yaml exceeds 1 MiB");
        }
        let pubspec: serde_yaml::Value =
            serde_yaml::from_slice(&content).context("Invalid pubspec.yaml")?;
        if pubspec
            .get("dependencies")
            .and_then(|v| v.get("flutter"))
            .and_then(|v| v.get("sdk"))
            .and_then(serde_yaml::Value::as_str)
            != Some("flutter")
        {
            bail!("Selected package does not declare a Flutter SDK dependency");
        }
        if self.config.attach_uri.is_none() && !cwd.join(&self.config.program).is_file() {
            bail!("Application entry does not exist: {}", self.config.program);
        }
        if self.config.attach_uri.is_some() && self.config.mode == RunMode::Release {
            bail!("Release applications do not support attach");
        }
        let mut tool_args = vec!["-d".into(), self.config.device_id.clone()];
        tool_args.push(
            match self.config.mode {
                RunMode::Debug => "--debug",
                RunMode::Profile => "--profile",
                RunMode::Release => "--release",
            }
            .into(),
        );
        if let Some(flavor) = &self.config.flavor {
            tool_args.extend(["--flavor".into(), flavor.clone()]);
        }
        for value in &self.config.dart_defines {
            tool_args.push(format!("--dart-define={value}"));
        }
        tool_args.extend(self.config.tool_args.clone());
        let env = self
            .config
            .env
            .iter()
            .map(|e| (e.name.clone(), e.value.clone()))
            .collect();
        // Installing the peer and checking cancellation share the same lock as stop.
        let peer = {
            let mut slot = self.peer.lock().await;
            if self.snapshot.lock().await.state != SessionState::Preparing {
                return Ok(());
            }
            if self.isolate_device_logs {
                *self.vm_port.lock().await = Some(ios_vm_service_arguments(&mut tool_args)?);
            }
            let peer = ProtocolPeer::spawn(
                &sdk,
                &["debug-adapter".into()],
                Some(cwd),
                &env,
                WireProtocol::Dap,
                Some(self.logs.clone()),
                self.isolate_device_logs,
            )?;
            *slot = Some(peer.clone());
            peer
        };
        let mut receiver = peer.events.subscribe();
        self.state(SessionState::Starting, None).await;
        let session = self.clone();
        tokio::spawn(async move {
            loop {
                match receiver.recv().await {
                    Ok(value) => {
                        session.handle_event(value).await;
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        session
                            .state(
                                SessionState::Failed,
                                Some("Debugger event stream overflowed".into()),
                            )
                            .await;
                        let _ = peer.terminate().await;
                        break;
                    }
                    Err(_) => break,
                }
                if matches!(
                    session.snapshot.lock().await.state,
                    SessionState::Ended | SessionState::Failed
                ) {
                    let _ = peer.terminate().await;
                    break;
                }
            }
        });
        let capabilities=self.request("initialize",json!({"clientID":"flutter-dev","adapterID":"dart","pathFormat":"path","linesStartAt1":true,"columnsStartAt1":true,"supportsRunInTerminalRequest":false,"supportsProgressReporting":true}),Duration::from_secs(30)).await?;
        self.snapshot.lock().await.capabilities_json = capabilities.to_string();
        let mut arguments = json!({"cwd":self.config.project_path,"program":self.config.program,"noDebug":self.config.no_debug || self.config.mode != RunMode::Debug,"args":self.config.args,"env":env,"toolArgs":tool_args});
        let command = if let Some(uri) = &self.config.attach_uri {
            arguments["vmServiceUri"] = json!(uri);
            "attach"
        } else {
            "launch"
        };
        // Launch may not complete until configurationDone; keep both sides live.
        let (launch_peer, ticket) = {
            let slot = self.peer.lock().await;
            if self.snapshot.lock().await.state != SessionState::Starting {
                return Ok(());
            }
            let peer = slot
                .as_ref()
                .context("Session stopped before launch")?
                .clone();
            let ticket = peer
                .begin_request(command, arguments, Duration::from_secs(180))
                .await?;
            (peer, ticket)
        };
        let launch = launch_peer.finish_request(command, ticket);
        let configure = async {
            let mut initialized = self.initialized.subscribe();
            tokio::time::timeout(Duration::from_secs(30), async {
                while !*initialized.borrow_and_update() {
                    initialized
                        .changed()
                        .await
                        .map_err(|_| anyhow!("Initialization event closed"))?;
                }
                Ok::<_, anyhow::Error>(())
            })
            .await
            .context("Adapter initialized event timed out")??;
            self.request("configurationDone", json!({}), Duration::from_secs(30))
                .await?;
            Ok::<_, anyhow::Error>(())
        };
        tokio::try_join!(launch, configure)?;
        let mut state = self.state_changed.subscribe();
        tokio::time::timeout(Duration::from_secs(180), async {
            while matches!(
                *state.borrow_and_update(),
                SessionState::Preparing | SessionState::Starting
            ) {
                state
                    .changed()
                    .await
                    .context("Session readiness channel closed")?;
            }
            Ok::<_, anyhow::Error>(())
        })
        .await
        .context("Application did not become ready within 180 seconds")??;
        // Actual appStarted/stopped events, not launch acceptance, set Running.
        self.emit(CoreEventKind::State, None).await;
        Ok(())
    }
    async fn handle_event(&self, value: Value) {
        if let Some(reason) = value["_fault"].as_str() {
            if self.snapshot.lock().await.state == SessionState::Stopping {
                self.state(SessionState::Ended, None).await;
            } else {
                self.state(SessionState::Failed, Some(reason.into())).await;
            }
            return;
        }
        if let Some(text) = value["_stderr"].as_str() {
            self.logs.lock().await.push("stderr", text);
            return;
        }
        let body = &value["body"];
        match value["event"].as_str().unwrap_or("") {
            "initialized" => {
                self.initialized.send_replace(true);
            }
            "output" => {
                record_adapter_output(&mut *self.logs.lock().await, body, self.isolate_device_logs);
            }
            "progressStart" | "progressUpdate" if self.isolate_device_logs => {
                if let Some(message) = body["message"].as_str() {
                    self.logs.lock().await.push("console", message);
                }
            }
            "flutter.appStarted" => {
                self.state(SessionState::Running, None).await;
            }
            "stopped" => {
                if let Some(id) = body["threadId"].as_i64() {
                    self.paused_threads.lock().await.insert(id);
                }
                self.state(SessionState::Paused, None).await;
                self.emit(CoreEventKind::Debugger, Some(value.to_string()))
                    .await;
            }
            "continued" => {
                let mut paused = self.paused_threads.lock().await;
                if body["allThreadsContinued"] == true {
                    paused.clear();
                } else if let Some(id) = body["threadId"].as_i64() {
                    paused.remove(&id);
                }
                let state = if paused.is_empty() {
                    SessionState::Running
                } else {
                    SessionState::Paused
                };
                drop(paused);
                self.state(state, None).await;
            }
            "thread" => {
                if let Some(id) = body["threadId"].as_i64() {
                    let mut snapshot = self.snapshot.lock().await;
                    if body["reason"] == "exited" {
                        snapshot.threads.retain(|t| t.id != id);
                    } else if !snapshot.threads.iter().any(|t| t.id == id) {
                        snapshot.threads.push(DebugThread {
                            id,
                            name: format!("Isolate {id}"),
                        });
                    }
                    drop(snapshot);
                    self.emit(CoreEventKind::State, None).await;
                }
            }
            "dart.debuggerUris" => {
                let uri = body["vmServiceUri"]
                    .as_str()
                    .or(body["vmServiceWsUri"].as_str());
                if let Some(uri) = uri {
                    self.snapshot.lock().await.service_uri = Some(uri.into());
                    self.start_vm_output(uri).await;
                    self.emit(CoreEventKind::ServiceUri, None).await;
                }
            }
            "terminated" => {
                self.state(SessionState::Ended, None).await;
                if let Some(peer) = self.peer.lock().await.as_ref() {
                    let _ = peer.terminate().await;
                }
            }
            "exited" => {
                if body["exitCode"].as_i64().unwrap_or(0) != 0 {
                    self.state(
                        SessionState::Failed,
                        Some(format!("Application exited with code {}", body["exitCode"])),
                    )
                    .await;
                }
            }
            _ => {
                self.emit(CoreEventKind::Debugger, Some(value.to_string()))
                    .await;
            }
        }
    }

    async fn start_vm_output(&self, uri: &str) {
        // Attach adapters already subscribe to the target VM's output streams.
        if self.config.attach_uri.is_some() || !self.isolate_device_logs {
            return;
        }
        let mut slot = self.vm_output.lock().await;
        if slot.as_ref().is_some_and(|(current, _)| current == uri) {
            return;
        }
        if matches!(
            self.snapshot.lock().await.state,
            SessionState::Stopping | SessionState::Ended | SessionState::Failed
        ) {
            return;
        }
        if let Some((_, task)) = slot.take() {
            task.abort();
            let _ = task.await;
        }
        let address = uri.to_owned();
        let logs = self.logs.clone();
        let (ready, _) = watch::channel(false);
        let task = tokio::spawn(async move {
            let result = crate::vm_logs::collect(&address, logs.clone(), ready).await;
            let reason = result
                .err()
                .map(|error| error.to_string())
                .unwrap_or_else(|| "VM log connection closed".into());
            logs.lock().await.push(
                "warning",
                &format!("Dart output stream unavailable: {reason}. Device Dart logs remain hidden to prevent output from other applications."),
            );
        });
        *slot = Some((uri.to_owned(), task));
    }
    pub(crate) async fn request(
        &self,
        command: &str,
        args: Value,
        timeout: Duration,
    ) -> Result<Value> {
        let peer = self
            .peer
            .lock()
            .await
            .clone()
            .context("Session adapter is not available")?;
        peer.request(command, args, timeout).await
    }
    pub(crate) async fn stop(&self) -> Result<()> {
        let mut slot = self.peer.lock().await;
        if matches!(
            self.snapshot.lock().await.state,
            SessionState::Ended | SessionState::Failed
        ) {
            let peer = slot.take();
            drop(slot);
            if let Some(peer) = peer {
                peer.terminate().await?;
            }
            return Ok(());
        }
        self.state(SessionState::Stopping, None).await;
        let peer = slot.take();
        drop(slot);
        let mut result = Ok(());
        if let Some(peer) = peer {
            let _ = peer
                .request(
                    "disconnect",
                    json!({"terminateDebuggee":self.config.attach_uri.is_none()}),
                    Duration::from_secs(5),
                )
                .await;
            result = peer.terminate().await;
        }
        match &result {
            Ok(()) => self.state(SessionState::Ended, None).await,
            Err(e) => self.state(SessionState::Failed, Some(e.to_string())).await,
        };
        result
    }
    pub(crate) async fn hot_update(&self, restart: bool) -> Result<()> {
        let _operation = self
            .operation_lock
            .try_lock()
            .map_err(|_| anyhow!("A hot update is already in progress"))?;
        {
            let mut snapshot = self.snapshot.lock().await;
            if snapshot.mode != RunMode::Debug
                || !matches!(snapshot.state, SessionState::Running | SessionState::Paused)
            {
                bail!("Hot update requires a running Debug session");
            }
            snapshot.operation = Some(if restart { "hotRestart" } else { "hotReload" }.into());
        }
        self.hot_update_request(restart, false).await
    }
    /// None means no request was attempted: preserve the source version for retry.
    pub(crate) async fn try_automatic_hot_reload(&self) -> Option<Result<()>> {
        let _operation = self.operation_lock.try_lock().ok()?;
        {
            let mut snapshot = self.snapshot.lock().await;
            if !*self.auto_reload.borrow()
                || !matches!(snapshot.state, SessionState::Running | SessionState::Paused)
                || !crate::auto_reload::hot_reload_supported(
                    snapshot.mode,
                    snapshot.no_debug,
                    &snapshot.capabilities_json,
                )
            {
                return None;
            }
            snapshot.operation = Some("hotReload".into());
        }
        Some(self.hot_update_request(false, true).await)
    }
    async fn hot_update_request(&self, restart: bool, automatic: bool) -> Result<()> {
        if automatic {
            self.logs
                .lock()
                .await
                .push("system", "Dart files saved; automatic hot reload");
        }
        self.emit(CoreEventKind::State, None).await;
        let result = self
            .request(
                if restart { "hotRestart" } else { "hotReload" },
                json!({"reason": if automatic { "save" } else { "manual" }}),
                Duration::from_secs(90),
            )
            .await;
        self.snapshot.lock().await.operation = None;
        if let Err(error) = &result {
            self.logs.lock().await.push("error", &error.to_string());
        }
        self.emit(CoreEventKind::State, None).await;
        result.map(|_| ())
    }
    pub(crate) async fn device_disconnected(&self) {
        self.state(
            SessionState::Failed,
            Some("Selected device disconnected".into()),
        )
        .await;
        if let Some(peer) = self.peer.lock().await.as_ref() {
            let _ = peer
                .request(
                    "disconnect",
                    json!({"terminateDebuggee":self.config.attach_uri.is_none()}),
                    Duration::from_secs(3),
                )
                .await;
            let _ = peer.terminate().await;
        }
    }
    pub(crate) async fn recovery_events(&self) -> Vec<CoreEvent> {
        let mut snapshot = self.snapshot.lock().await;
        let mut events = vec![];
        for kind in [CoreEventKind::State, CoreEventKind::OutputAvailable] {
            snapshot.sequence += 1;
            events.push(CoreEvent {
                session_id: snapshot.session_id.clone(),
                generation: snapshot.generation,
                sequence: snapshot.sequence,
                kind,
                payload: serde_json::to_string(&*snapshot).unwrap_or_default(),
            });
        }
        events
    }
}
