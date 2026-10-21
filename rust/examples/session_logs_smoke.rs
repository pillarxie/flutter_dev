//! Real-device isolation check for two explicitly marked disposable projects.
//! Usage: cargo run --manifest-path rust/Cargo.toml --example session_logs_smoke -- SDK A B DEVICE
//! Each project needs .flutter-dev-log-isolation-owned and a main.dart which emits
//! '$marker stdout $counter\n$marker stdout multiline $counter' and
//! '$marker stderr $counter' and debugPrint('$marker debugPrint $counter') every second, with
//! marker = const String.fromEnvironment('FLUTTER_DEV_LOG_MARKER').
use anyhow::{bail, ensure, Context, Result};
use flutter_dev_core::api::core::*;
use std::{path::Path, time::Duration};

const MARKERS: [&str; 2] = ["flutter-dev-isolation-A", "flutter-dev-isolation-B"];

fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    ensure!(
        args.len() == 4,
        "Usage: session_logs_smoke SDK PROJECT_A PROJECT_B DEVICE_ID"
    );
    // Set the process-local environment before starting any Tokio threads. The
    // sample never reads or writes the user's real workbench settings.
    let settings = tempfile::tempdir()?;
    std::env::set_var(
        "FLUTTER_DEV_SETTINGS_PATH",
        settings.path().join("settings.json"),
    );
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(async {
        let result = tokio::select! {
            result = smoke(&args) => result,
            result = tokio::signal::ctrl_c() => {
                match result {
                    Ok(()) => Err(anyhow::anyhow!("Smoke interrupted")),
                    Err(error) => Err(anyhow::Error::new(error).context("Listen for interrupt")),
                }
            }
        };
        // This core belongs only to this executable, including partial launches.
        let cleanup = shutdown_core().await;
        match (result, cleanup) {
            (Err(error), Err(cleanup)) => {
                Err(error.context(format!("Cleanup also failed: {cleanup:#}")))
            }
            (Err(error), _) | (_, Err(error)) => Err(error),
            _ => Ok(()),
        }
    })
}

async fn smoke(args: &[String]) -> Result<()> {
    let projects = [
        tokio::fs::canonicalize(&args[1]).await?,
        tokio::fs::canonicalize(&args[2]).await?,
    ];
    ensure!(
        projects[0] != projects[1],
        "Two different disposable projects are required"
    );
    for project in &projects {
        ensure!(
            project.join(".flutter-dev-log-isolation-owned").is_file()
                && project.join("pubspec.yaml").is_file()
                && project.join("lib/main.dart").is_file(),
            "Project must be an explicitly marked disposable Flutter sample: {}",
            project.display()
        );
    }
    let sdk = resolve_sdk(None, Some(args[0].clone())).await?;
    let devices = list_devices(sdk.path.clone()).await?;
    let device = devices
        .iter()
        .find(|device| device.id == args[3])
        .with_context(|| format!("Device not available: {}", args[3]))?;
    println!(
        "Device {} platform={} platform_type={:?}",
        device.id, device.platform, device.platform_type
    );
    println!(
        "Launching disposable projects on {} with Flutter {}",
        args[3], sdk.flutter_version
    );
    let configurations: Vec<_> = projects
        .iter()
        .zip(MARKERS)
        .map(|(project, marker)| configuration(&sdk.path, project, &args[3], marker))
        .collect();
    let (first, second) = tokio::join!(
        start_session(configurations[0].clone()),
        start_session(configurations[1].clone()),
    );
    let ids = [first?.session_id, second?.session_id];
    ensure!(ids[0] != ids[1], "Core reused a session id");
    let mut cursors = [0, 0];
    observe(
        &ids,
        &mut cursors,
        Duration::from_secs(180),
        "initial launch",
    )
    .await?;
    // Restart one application at a time while its sibling continues printing.
    // Cursor-based reads ensure the check requires fresh post-restart output.
    for index in 0..2 {
        hot_restart(ids[index].clone()).await?;
        observe(
            &ids,
            &mut cursors,
            Duration::from_secs(45),
            &format!("restart {}", index + 1),
        )
        .await?;
    }
    println!("PASS: both sessions kept stdout/stderr isolated before and after both hot restarts");
    Ok(())
}

fn configuration(sdk: &str, project: &Path, device: &str, marker: &str) -> RunConfiguration {
    RunConfiguration {
        sdk_path: sdk.into(),
        project_path: project.to_string_lossy().into_owned(),
        device_id: device.into(),
        program: "lib/main.dart".into(),
        mode: RunMode::Debug,
        no_debug: false,
        attach_uri: None,
        env: vec![],
        tool_args: vec![],
        args: vec![],
        flavor: None,
        dart_defines: vec![format!("FLUTTER_DEV_LOG_MARKER={marker}")],
    }
}

async fn observe(
    ids: &[String; 2],
    cursors: &mut [u64; 2],
    timeout: Duration,
    phase: &str,
) -> Result<()> {
    let mut seen = [[false; 4]; 2];
    let mut states = [None, None];
    let mut service_uris = [None, None];
    let mut identities = [false; 2];
    let deadline = tokio::time::Instant::now() + timeout;
    let mut ready_since = None;
    let mut first_pass = true;
    loop {
        let snapshots = session_snapshots().await?;
        for (index, id) in ids.iter().enumerate() {
            let snapshot = snapshots
                .iter()
                .find(|session| session.session_id == *id)
                .context("Session disappeared")?;
            if states[index] != Some(snapshot.state) {
                println!("{phase} session {id}: {:?}", snapshot.state);
                states[index] = Some(snapshot.state);
            }
            if snapshot.service_uri != service_uris[index] {
                println!(
                    "{phase} session {id}: service_uri={:?}",
                    snapshot.service_uri
                );
                service_uris[index] = snapshot.service_uri.clone();
            }
            if snapshot.service_uri.is_some()
                && snapshot.state == SessionState::Running
                && !identities[index]
            {
                match network_request(id.clone(), "getVM".into(), "{}".into()).await {
                    Ok(response) => {
                        let vm: serde_json::Value = serde_json::from_str(&response.json)?;
                        println!(
                            "{phase} session {id}: VM pid={} name={} isolates={}",
                            vm["pid"], vm["name"], vm["isolates"]
                        );
                        identities[index] = true;
                    }
                    Err(error) => println!("{phase} session {id}: getVM unavailable: {error:#}"),
                }
            }
            if matches!(snapshot.state, SessionState::Ended | SessionState::Failed) {
                bail!("{phase}: session {id} ended early: {:?}", snapshot.error);
            }
        }
        if service_uris.iter().all(Option::is_some) {
            ensure!(
                service_uris[0] != service_uris[1],
                "{phase}: both independent applications resolved to the same VM service URI"
            );
        }
        for index in 0..2 {
            // Drain full pages so a burst cannot hide a foreign marker behind a
            // successful first page of output.
            loop {
                let page =
                    read_logs(ids[index].clone(), cursors[index], 1000, String::new()).await?;
                let full = page.entries.len() == 1000;
                for entry in page.entries {
                    cursors[index] = cursors[index].max(entry.id);
                    if matches!(entry.category.as_str(), "warning" | "error") {
                        println!(
                            "{phase} session {} {}: {}",
                            ids[index], entry.category, entry.text
                        );
                    }
                    ensure!(
                        !entry.text.contains(MARKERS[1 - index]),
                        "{phase}: session {} contains foreign output in {}: {}",
                        ids[index],
                        entry.category,
                        entry.text
                    );
                    for (stream, name) in ["stdout", "stderr"].iter().enumerate() {
                        if let Some((_, output)) = entry
                            .text
                            .split_once(&format!("{} {name} ", MARKERS[index]))
                        {
                            if *name != "stdout" || !output.starts_with("multiline ") {
                                seen[index][stream] = true;
                            }
                            ensure!(
                                entry.category == *name,
                                "{phase}: {name} marker has category {}",
                                entry.category
                            );
                        }
                    }
                    if entry
                        .text
                        .contains(&format!("{} stdout multiline ", MARKERS[index]))
                    {
                        seen[index][2] = true;
                    }
                    if entry
                        .text
                        .contains(&format!("{} debugPrint ", MARKERS[index]))
                    {
                        seen[index][3] = true;
                        ensure!(
                            entry.category == "stdout",
                            "{phase}: debugPrint marker has category {}",
                            entry.category
                        );
                    }
                }
                if !full {
                    break;
                }
            }
        }
        if first_pass {
            // Existing backlog still gets checked for cross-session content,
            // but it cannot satisfy this phase's fresh-output requirement.
            seen = [[false; 4]; 2];
            first_pass = false;
        }
        let now = tokio::time::Instant::now();
        if seen.iter().flatten().all(|seen| *seen) {
            let start = ready_since.get_or_insert(now);
            // Keep both applications emitting together for ten seconds rather
            // than accepting the first clean line as isolation evidence.
            if now.duration_since(*start) >= Duration::from_secs(10) {
                println!(
                    "PASS {phase}: fresh stdout/stderr from both sessions; no foreign markers"
                );
                return Ok(());
            }
        }
        ensure!(
            now < deadline,
            "{phase}: timed out waiting for both output streams; seen={seen:?}"
        );
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}
