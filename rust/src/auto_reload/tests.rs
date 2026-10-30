use super::*;

fn package(root: &Path, specification: &str) -> PathBuf {
    fs::create_dir_all(root.join("lib")).unwrap();
    fs::write(root.join("pubspec.yaml"), specification).unwrap();
    fs::write(root.join("lib/source.dart"), "const value = 1;\n").unwrap();
    fs::canonicalize(root).unwrap()
}

fn package_config(project: &Path, packages: &[(&str, &Path)]) -> PathBuf {
    fs::create_dir_all(project.join(".dart_tool")).unwrap();
    let config = project.join(".dart_tool/package_config.json");
    let packages: Vec<_> = packages
        .iter()
        .map(|(name, root)| {
            serde_json::json!({
                "name": name,
                "rootUri": Url::from_directory_path(root).unwrap().to_string(),
                "packageUri": "lib/",
                "languageVersion": "3.10"
            })
        })
        .collect();
    fs::write(
        &config,
        serde_json::to_vec(&serde_json::json!({"configVersion":2,"packages":packages})).unwrap(),
    )
    .unwrap();
    config
}

#[test]
fn automatic_reload_respects_debug_mode_explicit_capability_and_no_debug() {
    assert!(hot_reload_supported(RunMode::Debug, false, "{}"));
    assert!(!hot_reload_supported(
        RunMode::Debug,
        false,
        r#"{"supportsHotReload":false}"#,
    ));
    assert!(!hot_reload_supported(RunMode::Debug, true, "{}"));
    assert!(hot_reload_supported(
        RunMode::Debug,
        true,
        r#"{"supportsHotReload":true}"#,
    ));
    for mode in [RunMode::Profile, RunMode::Release] {
        assert!(!hot_reload_supported(
            mode,
            false,
            r#"{"supportsHotReload":true}"#,
        ));
    }
}

async fn wait_revision(monitor: &Monitor, predicate: impl Fn(&Revision) -> bool) -> Revision {
    wait_revision_with_timeout(monitor, Duration::from_secs(15), predicate).await
}

async fn wait_revision_with_timeout(
    monitor: &Monitor,
    timeout: Duration,
    predicate: impl Fn(&Revision) -> bool,
) -> Revision {
    tokio::time::timeout(timeout, async {
        loop {
            let revision = monitor.revisions.borrow().clone();
            if predicate(&revision) {
                return revision;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .unwrap_or_else(|_| {
        let revision = monitor.revisions.borrow();
        panic!(
            "monitor condition timed out: ready={}, version={}, error={:?}",
            revision.ready, revision.version, revision.error
        )
    })
}

#[test]
fn resolved_local_dependencies_follow_transitive_and_overrides_but_exclude_hosted_cache() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path();
    let transitive = package(&root.join("传递 package"), "name: transitive\n");
    let direct = package(
        &root.join("direct"),
        "name: direct\ndependencies:\n  transitive:\n    path: ../传递 package\n",
    );
    let unused = package(&root.join("old"), "name: overridden\n");
    let replacement = package(&root.join("replacement"), "name: overridden\n");
    let hosted = package(&root.join("custom-cache/hosted"), "name: hosted\n");
    let project = package(
        &root.join("app"),
        "name: app\ndependencies:\n  direct:\n    path: ../direct\n  overridden:\n    path: ../old\n  hosted: any\ndependency_overrides:\n  overridden:\n    path: ../replacement\n",
    );
    package_config(
        &project,
        &[
            ("app", &project),
            ("direct", &direct),
            ("transitive", &transitive),
            ("overridden", &replacement),
            ("hosted", &hosted),
        ],
    );
    fs::write(
        project.join("pubspec.lock"),
        "packages:\n  direct:\n    source: path\n  transitive:\n    source: path\n  overridden:\n    source: path\n  hosted:\n    source: hosted\n",
    )
    .unwrap();
    let sources = discover(&project).unwrap();
    assert!(sources.roots.contains(&project));
    for local in [&direct, &transitive, &replacement] {
        assert!(sources.roots.contains(&local.join("lib")), "{local:?}");
    }
    assert!(!sources.roots.iter().any(|p| p.starts_with(&unused)));
    assert!(!sources.roots.iter().any(|p| p.starts_with(&hosted)));
    assert!(sources.configuration_dirs.contains(&direct));
}

#[test]
fn workspace_ancestor_config_discovers_members_and_deduplicates_nested_roots() {
    let directory = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(directory.path()).unwrap();
    fs::write(
        root.join("pubspec.yaml"),
        "name: workspace\nworkspace:\n  - apps/app\n  - packages/shared\n",
    )
    .unwrap();
    let project = package(&root.join("apps/app"), "name: app\nresolution: workspace\n");
    let shared = package(
        &root.join("packages/shared"),
        "name: shared\nresolution: workspace\n",
    );
    let config = package_config(&root, &[("app", &project), ("shared", &shared)]);
    let sources = discover(&project).unwrap();
    assert_eq!(sources.resolved_config.as_deref(), Some(config.as_path()));
    assert!(sources.roots.contains(&project));
    assert!(sources.roots.contains(&shared.join("lib")));
    assert!(!sources.roots.contains(&project.join("lib")));
    assert!(sources.configuration_dirs.contains(&root));
}

#[test]
fn bounded_scan_ignores_caches_and_content_verification_catches_preserved_metadata() {
    let directory = tempfile::tempdir().unwrap();
    let project = package(directory.path(), "name: fixture\n");
    for name in ["build", ".dart_tool", ".git", "node_modules"] {
        fs::create_dir_all(project.join(name)).unwrap();
        fs::write(project.join(name).join("ignored.dart"), "ignored").unwrap();
    }
    let sources = Sources {
        roots: BTreeSet::from([project.clone()]),
        configuration_dirs: BTreeSet::new(),
        resolved_config: None,
    };
    let (first, _) = scan(&sources, None, false).unwrap();
    assert_eq!(first.len(), 1);
    let source = project.join("lib/source.dart");
    let modified = fs::metadata(&source).unwrap().modified().unwrap();
    fs::write(&source, "const value = 2;\n").unwrap();
    fs::File::options()
        .write(true)
        .open(&source)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(modified))
        .unwrap();
    let (unverified, _) = scan(&sources, Some(&first), false).unwrap();
    assert_eq!(first, unverified);
    let (verified, _) = scan(&sources, Some(&first), true).unwrap();
    assert_ne!(first, verified);
}

#[tokio::test]
async fn monitor_is_shared_by_canonical_project_and_released_after_last_owner() {
    let directory = tempfile::tempdir().unwrap();
    let project = package(directory.path(), "name: fixture\n");
    let first = Monitor::subscribe(&project).unwrap();
    let second = Monitor::subscribe(&project.join("lib/..")).unwrap();
    assert!(Arc::ptr_eq(&first, &second));
    let baseline = wait_revision(&first, |revision| revision.ready).await;
    assert_eq!(baseline.version, 0, "initial snapshot must not reload");
    let weak = Arc::downgrade(&first);
    drop(first);
    assert!(weak.upgrade().is_some());
    drop(second);
    assert!(weak.upgrade().is_none());
    let replacement = Monitor::subscribe(&project).unwrap();
    assert_eq!(replacement.revisions.borrow().version, 0);
    wait_revision(&replacement, |revision| revision.ready).await;
}

#[cfg(unix)]
#[tokio::test]
async fn native_atomic_replace_create_rename_delete_and_periodic_scan_deduplicate() {
    let directory = tempfile::tempdir().unwrap();
    let project = package(directory.path(), "name: fixture\n");
    let monitor = Monitor::subscribe(&project).unwrap();
    wait_revision(&monitor, |revision| revision.ready).await;
    let source = project.join("lib/source.dart");
    let temporary = project.join("lib/.save");
    fs::write(&temporary, "const value = 22;\n").unwrap();
    fs::rename(&temporary, &source).unwrap();
    wait_revision_with_timeout(&monitor, Duration::from_secs(4), |revision| {
        revision.version == 1
    })
    .await;
    let created = project.join("lib/created.dart");
    fs::write(&created, "const created = true;\n").unwrap();
    wait_revision_with_timeout(&monitor, Duration::from_secs(4), |revision| {
        revision.version == 2
    })
    .await;
    let renamed = project.join("lib/renamed.dart");
    fs::rename(&created, &renamed).unwrap();
    wait_revision_with_timeout(&monitor, Duration::from_secs(4), |revision| {
        revision.version == 3
    })
    .await;
    fs::remove_file(&renamed).unwrap();
    wait_revision_with_timeout(&monitor, Duration::from_secs(4), |revision| {
        revision.version == 4
    })
    .await;
    fs::write(project.join("README.md"), "ordinary document").unwrap();
    tokio::time::sleep(POLL + Duration::from_millis(500)).await;
    assert_eq!(monitor.revisions.borrow().version, 4);
}

#[tokio::test]
async fn missed_events_are_recovered_by_polling_and_watcher_failure_rescans_without_losing_baseline(
) {
    let directory = tempfile::tempdir().unwrap();
    let project = package(directory.path(), "name: fixture\n");
    let monitor = Monitor::subscribe(&project).unwrap();
    wait_revision(&monitor, |revision| revision.ready).await;
    monitor
        .signals
        .suppress_events
        .store(true, Ordering::Release);
    let source = project.join("lib/source.dart");
    fs::write(&source, "const value = 12;\n").unwrap();
    tokio::time::sleep(Duration::from_millis(1200)).await;
    assert_eq!(monitor.revisions.borrow().version, 0);
    wait_revision_with_timeout(&monitor, POLL + Duration::from_secs(2), |revision| {
        revision.version == 1
    })
    .await;

    // An error wakes the fallback immediately. The existing snapshot must still
    // identify this edit; replacing it with a fresh baseline would lose it.
    fs::write(&source, "const value = 123;\n").unwrap();
    monitor.signals.pending.fetch_or(FAILED, Ordering::Release);
    monitor.signals.wake.notify_one();
    wait_revision_with_timeout(&monitor, Duration::from_secs(3), |revision| {
        revision.version == 2
    })
    .await;
    tokio::time::sleep(Duration::from_millis(900)).await;
    assert_eq!(monitor.revisions.borrow().version, 2);
}

#[cfg(unix)]
#[tokio::test]
async fn malformed_and_missing_config_keep_previous_external_dependency_roots() {
    let directory = tempfile::tempdir().unwrap();
    let dependency = package(&directory.path().join("dependency"), "name: dependency\n");
    let project = package(
        &directory.path().join("app"),
        "name: app\ndependencies:\n  dependency:\n    path: ../dependency\n",
    );
    let config = package_config(&project, &[("app", &project), ("dependency", &dependency)]);
    let monitor = Monitor::subscribe(&project).unwrap();
    wait_revision(&monitor, |revision| revision.ready).await;
    fs::write(&config, "{").unwrap();
    wait_revision(&monitor, |revision| revision.error.is_some()).await;
    fs::write(dependency.join("lib/source.dart"), "const value = 12;\n").unwrap();
    wait_revision(&monitor, |revision| revision.version == 1).await;
    fs::remove_file(&config).unwrap();
    fs::write(dependency.join("lib/source.dart"), "const value = 123;\n").unwrap();
    wait_revision(&monitor, |revision| revision.version == 2).await;
    package_config(&project, &[("app", &project), ("dependency", &dependency)]);
    wait_revision(&monitor, |revision| revision.error.is_none()).await;
    assert_eq!(monitor.revisions.borrow().version, 2);
}

#[cfg(unix)]
#[tokio::test]
async fn compile_error_is_consumed_once_new_save_retries_and_disable_stop_release() {
    use crate::session::{tests::fake_sdk, RunConfiguration};
    let root = fake_sdk(false);
    let config = RunConfiguration {
        project_path: root.path().to_string_lossy().into_owned(),
        sdk_path: root.path().to_string_lossy().into_owned(),
        program: "lib/main.dart".into(),
        device_id: "ready-device".into(),
        mode: RunMode::Debug,
        no_debug: false,
        attach_uri: None,
        env: vec![],
        tool_args: vec![],
        args: vec![],
        flavor: None,
        dart_defines: vec![],
    };
    let (events, _) = tokio::sync::broadcast::channel(32);
    let session = Session::new("auto-reload-regression".into(), config, events, Ok(false));
    session.set_auto_reload(true);
    start(session.clone());
    let runner = tokio::spawn(session.clone().run());
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let ready = session
                .logs
                .lock()
                .await
                .query(None, 1000, Some("monitoring ready"))
                .entries
                .len();
            if ready > 0 && session.snapshot.lock().await.state == SessionState::Running {
                break;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .unwrap();
    let count = || {
        fs::read_to_string(root.path().join("requests.jsonl"))
            .unwrap_or_default()
            .lines()
            .filter(|line| {
                serde_json::from_str::<serde_json::Value>(line).unwrap()["command"] == "hotReload"
            })
            .count()
    };
    let source = root.path().join("lib/main.dart");
    fs::write(&source, "void main() { print('first save'); }\n").unwrap();
    let first_reload = tokio::time::timeout(Duration::from_secs(6), async {
        while count() == 0 {
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await;
    if first_reload.is_err() {
        let logs = session.logs.lock().await.query(None, 1000, None);
        let requests = fs::read_to_string(root.path().join("requests.jsonl")).unwrap_or_default();
        session.stop().await.unwrap();
        runner.await.unwrap();
        panic!("first native reload timed out; logs={logs:?}; requests={requests}");
    }
    tokio::time::sleep(Duration::from_millis(1600)).await;
    assert_eq!(
        count(),
        1,
        "compile failure must not loop without a new save"
    );
    fs::write(&source, "void main() { print('second save'); }\n").unwrap();
    session.set_auto_reload(true); // unrelated preference save keeps pending work
    tokio::time::timeout(Duration::from_secs(6), async {
        while count() < 2 {
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .unwrap();
    assert_eq!(count(), 2);
    session.set_auto_reload(false);
    fs::write(&source, "void main() { print('disabled'); }\n").unwrap();
    tokio::time::sleep(Duration::from_millis(1600)).await;
    assert_eq!(count(), 2);
    session.stop().await.unwrap();
    let weak = Arc::downgrade(&session);
    drop(session);
    runner.await.unwrap();
    tokio::time::timeout(Duration::from_secs(3), async {
        while weak.upgrade().is_some() {
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .unwrap();
}
