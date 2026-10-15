//! Real SDK smoke check. Optional second argument launches a disposable sample.
use anyhow::{bail, Context, Result};
use flutter_dev_core::api::core::*;
use serde_json::Value;
use std::time::Duration;

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let result = smoke(&args).await;
    shutdown_core().await?;
    result
}

async fn smoke(args: &[String]) -> Result<()> {
    let sdk = resolve_sdk(None, args.first().cloned()).await?;
    println!(
        "SDK {} / Dart {} ({})",
        sdk.flutter_version, sdk.dart_version, sdk.source
    );
    let devices = list_devices(sdk.path.clone()).await?;
    println!(
        "Devices: {}",
        devices
            .iter()
            .map(|d| format!("{} ({})", d.id, d.platform))
            .collect::<Vec<_>>()
            .join(", ")
    );
    let emulators = list_emulators(sdk.path.clone()).await?;
    println!("Available emulators: {}", emulators.len());
    let Some(project) = args.get(1) else {
        return Ok(());
    };
    let packages = discover_projects(project.clone()).await?;
    let package = packages.first().context("No Flutter sample package")?;
    let target = devices
        .iter()
        .find(|d| d.id == "macos" || d.id == "windows" || d.id == "linux")
        .context("No desktop target")?;
    let session = start_session(RunConfiguration {
        project_path: package.path.clone(),
        sdk_path: sdk.path,
        program: package.entrypoint.clone(),
        device_id: target.id.clone(),
        mode: RunMode::Debug,
        no_debug: false,
        attach_uri: None,
        env: vec![],
        tool_args: vec![],
        args: vec![],
        flavor: None,
        dart_defines: vec![],
    })
    .await?;
    tokio::time::timeout(Duration::from_secs(180), async {
        loop {
            let snapshot = session_snapshots()
                .await?
                .into_iter()
                .find(|s| s.session_id == session.session_id)
                .context("Session missing")?;
            if snapshot.state == SessionState::Running {
                break;
            }
            if matches!(snapshot.state, SessionState::Failed | SessionState::Ended) {
                let logs = read_logs(session.session_id.clone(), 0, 100, String::new()).await?;
                for entry in logs.entries {
                    println!("{}: {}", entry.category, entry.text);
                }
                bail!("Launch ended: {:?}", snapshot.error);
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        Ok::<_, anyhow::Error>(())
    })
    .await
    .context("Application did not become Running")??;
    let threads: Value = serde_json::from_str(&threads(session.session_id.clone()).await?.json)?;
    println!("DAP threads: {}", threads);
    if args.get(2).is_some_and(|arg| arg == "--network") {
        network_smoke(&session.session_id).await?;
    } else if let Some(line) = args.get(2) {
        let path = std::path::Path::new(&package.path).join(&package.entrypoint);
        let response = set_breakpoints(
            session.session_id.clone(),
            path.to_string_lossy().into_owned(),
            vec![SourceBreakpoint {
                line: line.parse()?,
                condition: None,
                hit_condition: None,
                log_message: None,
            }],
        )
        .await?;
        println!("Breakpoints: {}", response.json);
        let paused = wait_paused(&session.session_id, 0).await?;
        let thread_id = paused.threads.first().context("No paused isolate")?.id;
        let frames: Value = serde_json::from_str(
            &stack_trace(session.session_id.clone(), thread_id, 0, 20)
                .await?
                .json,
        )?;
        let frame_id = frames["stackFrames"][0]["id"]
            .as_i64()
            .context("No stack frame")?;
        let scopes: Value =
            serde_json::from_str(&scopes(session.session_id.clone(), frame_id).await?.json)?;
        if let Some(reference) = scopes["scopes"][0]["variablesReference"].as_i64() {
            let variables = variables(session.session_id.clone(), reference, 0, 20).await?;
            println!("Variables: {}", variables.json);
        }
        let evaluation: Value = serde_json::from_str(
            &evaluate(session.session_id.clone(), "1 + 1".into(), Some(frame_id))
                .await?
                .json,
        )?;
        if evaluation["result"] != "2" {
            bail!("Unexpected evaluation: {evaluation}");
        }
        debug_action(session.session_id.clone(), DebugAction::Next, thread_id).await?;
        wait_paused(&session.session_id, paused.sequence).await?;
        set_breakpoints(
            session.session_id.clone(),
            path.to_string_lossy().into_owned(),
            vec![],
        )
        .await?;
        debug_action(session.session_id.clone(), DebugAction::Continue, thread_id).await?;
        println!("Breakpoint / stack / variables / evaluate / step / continue: passed");
    }
    hot_reload(session.session_id.clone()).await?;
    println!("Hot reload: passed");
    hot_restart(session.session_id.clone()).await?;
    println!("Hot restart: passed");
    stop_session(session.session_id.clone()).await?;
    let snapshot = session_snapshots()
        .await?
        .into_iter()
        .find(|s| s.session_id == session.session_id)
        .context("Session missing")?;
    if snapshot.state != SessionState::Ended {
        bail!("Stop did not converge to Ended");
    }
    println!("Launch / stop: passed");
    Ok(())
}

// The disposable sample must periodically POST an encoded form to a local
// server with this path. This checks actual SDK data, rather than mock RPCs.
async fn network_smoke(session_id: &str) -> Result<()> {
    async fn rpc(session_id: &str, method: &str, params: Value) -> Result<Value> {
        let response =
            network_request(session_id.into(), method.into(), params.to_string()).await?;
        Ok(serde_json::from_str(&response.json)?)
    }
    let vm = rpc(session_id, "getVM", serde_json::json!({})).await?;
    let isolates = vm["isolates"].as_array().context("Missing VM isolates")?;
    let mut supported = vec![];
    for isolate in isolates {
        let id = isolate["id"].as_str().context("Missing isolate ID")?;
        let info = rpc(
            session_id,
            "getIsolate",
            serde_json::json!({"isolateId":id}),
        )
        .await?;
        if info["extensionRPCs"]
            .as_array()
            .is_some_and(|rpcs| rpcs.iter().any(|rpc| rpc == "ext.dart.io.getHttpProfile"))
        {
            rpc(
                session_id,
                "ext.dart.io.httpEnableTimelineLogging",
                serde_json::json!({"isolateId":id,"enabled":true}),
            )
            .await?;
            supported.push(id.to_owned());
        }
    }
    if supported.is_empty() {
        bail!("No HTTP profiling isolate");
    }
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            for isolate_id in &supported {
                let profile = rpc(
                    session_id,
                    "ext.dart.io.getHttpProfile",
                    serde_json::json!({"isolateId":isolate_id}),
                )
                .await?;
                for request in profile["requests"]
                    .as_array()
                    .context("Missing HTTP requests")?
                {
                    if !request["uri"]
                        .as_str()
                        .is_some_and(|uri| uri.contains("flutter-dev-network-smoke"))
                        || request["response"]["endTime"].is_null()
                    {
                        continue;
                    }
                    let detail = rpc(
                        session_id,
                        "ext.dart.io.getHttpProfileRequest",
                        serde_json::json!({"isolateId":isolate_id,"id":request["id"]}),
                    )
                    .await?;
                    if !detail["uri"].as_str().is_some_and(|uri| {
                        uri.contains("query=%E4%B8%AD%E6%96%87")
                            && uri.contains("filter=%7B%22page%22%3A1%7D")
                    }) {
                        bail!("Encoded query was not preserved");
                    }
                    let body: Vec<u8> = detail["requestBody"]
                        .as_array()
                        .context("Missing captured request body")?
                        .iter()
                        .map(|value| {
                            value
                                .as_u64()
                                .context("Invalid body byte")
                                .and_then(|byte| u8::try_from(byte).context("Invalid body byte"))
                        })
                        .collect::<Result<_>>()?;
                    let text = String::from_utf8(body)?;
                    if !text.contains("name=%E5%BC%A0%E4%B8%89") || !text.contains("data=%7B%22") {
                        bail!("Encoded form was not preserved: {text}");
                    }
                    if detail["response"]["statusCode"] != 200 {
                        bail!("Unexpected network smoke response");
                    }
                    println!(
                        "Network getVM / profiling / encoded query / form body / response: passed"
                    );
                    return Ok::<_, anyhow::Error>(());
                }
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    })
    .await
    .context("No completed network smoke request")?
}

async fn wait_paused(session_id: &str, after_sequence: u64) -> Result<SessionSnapshot> {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let snapshot = session_snapshots()
                .await?
                .into_iter()
                .find(|s| s.session_id == session_id)
                .context("Session missing")?;
            if snapshot.state == SessionState::Paused && snapshot.sequence > after_sequence {
                return Ok(snapshot);
            }
            if matches!(snapshot.state, SessionState::Failed | SessionState::Ended) {
                bail!("Session ended before pause");
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .context("Breakpoint/step did not pause")?
}
