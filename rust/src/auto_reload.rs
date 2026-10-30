//! Project-owned source monitors; sessions independently consume source revisions.
use crate::session::{RunMode, Session, SessionState};
use anyhow::{Context, Result};
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    hash::Hasher,
    io::Read,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU8, Ordering},
        Arc, Mutex, OnceLock, Weak,
    },
    time::{Duration, SystemTime},
};
use tokio::sync::{watch, Notify};
use tokio::time::Instant;
use url::Url;

const DEBOUNCE: Duration = Duration::from_millis(600);
const POLL: Duration = Duration::from_secs(8);
const FALLBACK_POLL: Duration = Duration::from_secs(2);
type Fingerprint = BTreeMap<PathBuf, (u64, SystemTime, u64)>;

fn ignored(path: &Path) -> bool {
    path.components().any(|part| {
        matches!(
            part.as_os_str().to_str(),
            Some(
                "build"
                    | ".dart_tool"
                    | ".git"
                    | "Pods"
                    | ".symlinks"
                    | "node_modules"
                    | ".idea"
                    | ".vscode"
                    | ".pub-cache"
            )
        )
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Sources {
    roots: BTreeSet<PathBuf>,
    configuration_dirs: BTreeSet<PathBuf>,
    resolved_config: Option<PathBuf>,
}

fn bounded_read(path: &Path) -> Result<Vec<u8>> {
    let file = fs::File::open(path).with_context(|| format!("Read {}", path.display()))?;
    let mut bytes = Vec::new();
    file.take(2 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
    anyhow::ensure!(
        bytes.len() <= 2 * 1024 * 1024,
        "Auto reload configuration exceeds 2 MiB: {}",
        path.display()
    );
    Ok(bytes)
}
fn yaml(path: &Path) -> Result<serde_yaml::Value> {
    serde_yaml::from_slice(&bounded_read(path)?)
        .with_context(|| format!("Parse {}", path.display()))
}

/// Package config supplies the actual roots after pub resolution. Pubspec and
/// lockfile supply provenance, so hosted/Git cache packages never become roots.
fn discover(project: &Path) -> Result<Sources> {
    let ancestors: Vec<_> = project.ancestors().take(33).collect();
    let mut configuration_dirs =
        BTreeSet::from([project.to_path_buf(), project.join(".dart_tool")]);
    let config = ancestors
        .iter()
        .map(|p| p.join(".dart_tool/package_config.json"))
        .find(|p| p.is_file());
    let mut resolved = BTreeMap::new();
    if let Some(config) = &config {
        let parsed: serde_json::Value = serde_json::from_slice(&bounded_read(config)?)
            .with_context(|| format!("Parse {}", config.display()))?;
        let packages = parsed["packages"]
            .as_array()
            .context("Invalid package_config packages")?;
        anyhow::ensure!(
            packages.len() <= 2000,
            "Auto reload exceeds 2000 resolved packages"
        );
        let base = Url::from_file_path(config)
            .map_err(|_| anyhow::anyhow!("Invalid package config path"))?;
        for package in packages {
            let name = package["name"].as_str().context("Invalid package name")?;
            let uri = package["rootUri"]
                .as_str()
                .context("Invalid package rootUri")?;
            let root = base
                .join(uri)?
                .to_file_path()
                .map_err(|_| anyhow::anyhow!("Package root is not a file URI"))?;
            resolved.insert(
                name.to_owned(),
                fs::canonicalize(&root).with_context(|| format!("Resolve {}", root.display()))?,
            );
        }
        configuration_dirs.insert(config.parent().unwrap().to_path_buf());
    }
    let mut local_names = BTreeSet::new();
    let mut provenance = BTreeMap::new();
    let mut candidates = vec![project.to_path_buf()];
    // Workspace resolution keeps config/lock at its root. Do not inspect
    // unrelated parent projects above the selected resolution scope.
    let scope_root = config
        .as_ref()
        .and_then(|path| path.parent())
        .and_then(Path::parent)
        .unwrap_or(project);
    for ancestor in ancestors
        .iter()
        .take_while(|path| path.starts_with(scope_root))
    {
        let lock = ancestor.join("pubspec.lock");
        if lock.is_file() {
            configuration_dirs.insert(ancestor.to_path_buf());
            let parsed = yaml(&lock)?;
            if let Some(packages) = parsed["packages"].as_mapping() {
                for (name, package) in packages {
                    if let (Some(name), Some(source)) = (name.as_str(), package["source"].as_str())
                    {
                        provenance
                            .entry(name.to_owned())
                            .or_insert_with(|| source.to_owned());
                    }
                    if package["source"].as_str() == Some("path") {
                        if let Some(name) = name.as_str() {
                            local_names.insert(name.to_owned());
                        }
                    }
                }
            }
        }
        let spec = ancestor.join("pubspec.yaml");
        if spec.is_file() {
            configuration_dirs.insert(ancestor.to_path_buf());
            let parsed = yaml(&spec)?;
            if parsed["workspace"].is_sequence() {
                candidates.push(ancestor.to_path_buf());
                // All resolved members are local even when not a dependency of
                // the selected member; resolution: workspace identifies them.
                for root in resolved.values().filter(|root| root.starts_with(ancestor)) {
                    let member = root.join("pubspec.yaml");
                    if member.is_file()
                        && yaml(&member)?["resolution"].as_str() == Some("workspace")
                    {
                        candidates.push(root.clone());
                    }
                }
            }
        }
    }
    for name in local_names {
        if provenance.get(&name).is_some_and(|source| source == "path") {
            if let Some(root) = resolved.get(&name) {
                candidates.push(root.clone());
            }
        }
    }
    let mut seen = BTreeSet::new();
    let mut roots = BTreeSet::from([project.to_path_buf()]);
    while let Some(root) = candidates.pop() {
        anyhow::ensure!(seen.len() < 512, "Auto reload exceeds 512 local packages");
        let root = fs::canonicalize(&root)
            .with_context(|| format!("Resolve local package {}", root.display()))?;
        if !seen.insert(root.clone()) {
            continue;
        }
        configuration_dirs.insert(root.clone());
        configuration_dirs.insert(root.join(".dart_tool"));
        if root != project {
            let lib = root.join("lib");
            if lib.is_dir() {
                roots.insert(lib);
            }
        }
        let spec = root.join("pubspec.yaml");
        if !spec.is_file() {
            continue;
        }
        let parsed = yaml(&spec)?;
        for section in ["dependencies", "dev_dependencies", "dependency_overrides"] {
            if let Some(dependencies) = parsed[section].as_mapping() {
                for (name, value) in dependencies {
                    if let Some(path) = value["path"].as_str() {
                        // Overrides and workspace resolution may redirect a
                        // declared path. The resolved package always wins.
                        if let Some(actual) = local_target(
                            name.as_str(),
                            &root.join(path),
                            &resolved,
                            &provenance,
                            config.is_some(),
                        )? {
                            candidates.push(actual);
                        }
                    }
                }
            }
        }
        let overrides = root.join("pubspec_overrides.yaml");
        if overrides.is_file() {
            let parsed = yaml(&overrides)?;
            if let Some(dependencies) = parsed["dependency_overrides"].as_mapping() {
                for (name, value) in dependencies {
                    if let Some(path) = value["path"].as_str() {
                        if let Some(actual) = local_target(
                            name.as_str(),
                            &root.join(path),
                            &resolved,
                            &provenance,
                            config.is_some(),
                        )? {
                            candidates.push(actual);
                        }
                    }
                }
            }
        }
    }
    let all_roots = roots.clone();
    roots.retain(|root| {
        !all_roots
            .iter()
            .any(|other| other != root && root.starts_with(other))
    });
    Ok(Sources {
        roots,
        configuration_dirs,
        resolved_config: config,
    })
}

fn local_target(
    name: Option<&str>,
    declared: &Path,
    resolved: &BTreeMap<String, PathBuf>,
    provenance: &BTreeMap<String, String>,
    has_config: bool,
) -> Result<Option<PathBuf>> {
    if let Some(actual) = name.and_then(|name| resolved.get(name)) {
        if let Some(source) = name.and_then(|name| provenance.get(name)) {
            return Ok((source == "path").then(|| actual.clone()));
        }
        // No lockfile: only use a resolved package matching the local declaration.
        return Ok(
            (fs::canonicalize(declared).ok().as_ref() == Some(actual)).then(|| actual.clone())
        );
    }
    Ok((!has_config).then(|| declared.to_path_buf()))
}

fn scan(
    sources: &Sources,
    previous: Option<&Fingerprint>,
    verify_content: bool,
) -> Result<(Fingerprint, BTreeSet<PathBuf>)> {
    let mut bytes_read = 0;
    let mut files = BTreeMap::new();
    let mut directories: BTreeSet<_> = sources
        .configuration_dirs
        .iter()
        .filter(|p| p.is_dir())
        .cloned()
        .collect();
    let mut folders: Vec<_> = sources.roots.iter().map(|root| (root.clone(), 0)).collect();
    let mut visited = 0;
    while let Some((folder, depth)) = folders.pop() {
        anyhow::ensure!(
            depth <= 32,
            "Auto reload source tree exceeds 32 directory levels"
        );
        directories.insert(folder.clone());
        for entry in fs::read_dir(&folder).with_context(|| format!("Scan {}", folder.display()))? {
            let entry = entry?;
            visited += 1;
            anyhow::ensure!(
                visited <= 20000,
                "Auto reload source tree exceeds 20000 entries"
            );
            let kind = entry.file_type()?;
            if kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                if !ignored(Path::new(&entry.file_name())) {
                    folders.push((entry.path(), depth + 1));
                }
            } else if kind.is_file()
                && entry
                    .path()
                    .extension()
                    .is_some_and(|value| value == "dart")
            {
                anyhow::ensure!(files.len() < 10000, "Auto reload exceeds 10000 Dart files");
                let metadata = entry.metadata()?;
                let path = entry.path();
                let modified = metadata.modified()?;
                let prior = previous.and_then(|files| files.get(&path));
                let digest = if !verify_content
                    && prior.is_some_and(|prior| prior.0 == metadata.len() && prior.1 == modified)
                {
                    prior.unwrap().2
                } else {
                    let mut file = fs::File::open(&path)?;
                    let mut digest = std::collections::hash_map::DefaultHasher::new();
                    let mut chunk = [0u8; 16384];
                    loop {
                        let size = file.read(&mut chunk)?;
                        if size == 0 {
                            break;
                        }
                        bytes_read += size;
                        anyhow::ensure!(
                            bytes_read <= 64 * 1024 * 1024,
                            "Auto reload source content exceeds 64 MiB per scan"
                        );
                        digest.write(&chunk[..size]);
                    }
                    digest.finish()
                };
                files.insert(path, (metadata.len(), modified, digest));
            }
        }
    }
    Ok((files, directories))
}

#[derive(Clone, Default)]
struct Revision {
    version: u64,
    changed_at: Option<Instant>,
    ready: bool,
    error: Option<String>,
}

struct Monitor {
    #[cfg(test)]
    signals: Arc<Signals>,
    revisions: watch::Sender<Revision>,
    _stop: watch::Sender<()>,
}
static MONITORS: OnceLock<Mutex<BTreeMap<PathBuf, Weak<Monitor>>>> = OnceLock::new();

impl Monitor {
    fn subscribe(project: &Path) -> Result<Arc<Self>> {
        let project = fs::canonicalize(project).context("Resolve automatic hot reload project")?;
        let mut monitors = MONITORS.get_or_init(Default::default).lock().unwrap();
        monitors.retain(|_, monitor| monitor.strong_count() > 0);
        if let Some(monitor) = monitors.get(&project).and_then(Weak::upgrade) {
            return Ok(monitor);
        }
        let (revisions, _) = watch::channel(Revision::default());
        let (stop, stopped) = watch::channel(());
        let signals = Arc::new(Signals::default());
        let monitor = Arc::new(Self {
            #[cfg(test)]
            signals: signals.clone(),
            revisions: revisions.clone(),
            _stop: stop,
        });
        monitors.insert(project.clone(), Arc::downgrade(&monitor));
        tokio::spawn(run_monitor(project, revisions, stopped, signals));
        Ok(monitor)
    }
}

const DIRTY: u8 = 1;
const SOURCE: u8 = 2;
const FAILED: u8 = 4;
const REWATCH: u8 = 8;

#[derive(Default)]
struct Signals {
    #[cfg(test)]
    suppress_events: std::sync::atomic::AtomicBool,
    pending: AtomicU8,
    wake: Notify,
    roots: Mutex<BTreeSet<PathBuf>>,
    configuration_dirs: Mutex<BTreeSet<PathBuf>>,
}
fn create_watcher(signals: Arc<Signals>) -> notify::Result<RecommendedWatcher> {
    RecommendedWatcher::new(
        move |event: notify::Result<notify::Event>| match event {
            Ok(event) if !matches!(event.kind, EventKind::Access(_)) => {
                #[cfg(test)]
                if signals.suppress_events.load(Ordering::Acquire) {
                    return;
                }
                let configuration_dirs = signals.configuration_dirs.lock().unwrap();
                let configuration = event.paths.iter().any(|p| {
                    matches!(
                        p.file_name().and_then(|v| v.to_str()),
                        Some(
                            "package_config.json"
                                | "pubspec.yaml"
                                | "pubspec.lock"
                                | "pubspec_overrides.yaml"
                                | ".dart_tool"
                        )
                    ) && p
                        .parent()
                        .is_some_and(|parent| configuration_dirs.contains(parent))
                });
                let roots = signals.roots.lock().unwrap();
                let belongs = |p: &Path| {
                    roots.iter().any(|root| {
                        p.strip_prefix(root)
                            .is_ok_and(|relative| !ignored(relative))
                    })
                };
                let source = event
                    .paths
                    .iter()
                    .any(|p| belongs(p) && p.extension().is_some_and(|v| v == "dart"));
                let directory = event.paths.iter().any(|p| {
                    belongs(p)
                        && (p.is_dir()
                            || matches!(
                                event.kind,
                                EventKind::Remove(notify::event::RemoveKind::Folder)
                                    | EventKind::Create(notify::event::CreateKind::Folder)
                            ))
                });
                if configuration || source || directory || event.need_rescan() {
                    let mut flags = DIRTY;
                    if source || directory || event.need_rescan() {
                        flags |= SOURCE;
                    }
                    if directory {
                        flags |= REWATCH;
                    }
                    signals.pending.fetch_or(flags, Ordering::Release);
                    signals.wake.notify_one();
                }
            }
            Err(_) => {
                signals.pending.fetch_or(FAILED, Ordering::Release);
                signals.wake.notify_one();
            }
            _ => {}
        },
        notify::Config::default().with_follow_symlinks(false),
    )
}

async fn run_monitor(
    project: PathBuf,
    revisions: watch::Sender<Revision>,
    mut stopped: watch::Receiver<()>,
    signals: Arc<Signals>,
) {
    let mut watcher = None;
    let mut watched = BTreeSet::new();
    let mut sources = Sources {
        roots: BTreeSet::from([project.clone()]),
        configuration_dirs: BTreeSet::from([project.clone()]),
        resolved_config: None,
    };
    *signals.roots.lock().unwrap() = sources.roots.clone();
    *signals.configuration_dirs.lock().unwrap() = sources.configuration_dirs.clone();
    let mut baseline: Option<Fingerprint> = None;
    let mut revision = Revision::default();
    let mut last_event = None;
    let mut source_hint = false;
    let mut next_poll = Instant::now();
    let mut retry_after = None;
    let mut tick = tokio::time::interval(Duration::from_millis(150));
    loop {
        tokio::select! {
            result = stopped.changed() => { if result.is_err() { break; } },
            _ = signals.wake.notified() => {},
            _ = tick.tick() => {},
        }
        let pending = signals.pending.swap(0, Ordering::AcqRel);
        if pending & FAILED != 0 {
            watcher = None;
            watched.clear();
            revision.error = Some("Automatic hot reload file watcher failed; using polling".into());
            revisions.send_replace(revision.clone());
            next_poll = Instant::now();
        }
        if pending & REWATCH != 0 {
            // A deleted/recreated directory can have the same path but a new
            // inode. Reinstall directory watches after this sparse operation.
            watcher = None;
            watched.clear();
        }
        if pending & DIRTY != 0 {
            last_event = Some(Instant::now());
            source_hint |= pending & SOURCE != 0;
        }
        let now = Instant::now();
        if retry_after.is_some_and(|retry| now < retry) {
            continue;
        }
        let event_due = last_event.is_some_and(|last| now.duration_since(last) >= DEBOUNCE);
        if !event_due && now < next_poll {
            continue;
        }
        // A poll falling in a save burst waits for the same debounce window.
        if last_event.is_some() && !event_due {
            continue;
        }
        let root = project.clone();
        let old_sources = sources.clone();
        let previous = baseline.clone();
        let verify_content = source_hint;
        let result = tokio::task::spawn_blocking(move || {
            let discovered = discover(&root).and_then(|next| {
                anyhow::ensure!(
                    old_sources.resolved_config.is_none() || next.resolved_config.is_some(),
                    "Previously resolved package_config is temporarily unavailable"
                );
                Ok(next)
            });
            let selected = discovered.as_ref().unwrap_or(&old_sources);
            let scanned = scan(selected, previous.as_ref(), verify_content);
            (discovered, scanned)
        })
        .await;
        let mut problem = None;
        match result {
            Ok((discovered, scanned)) => {
                match discovered {
                    Ok(next) => sources = next,
                    Err(error) => {
                        problem = Some(format!(
                            "Automatic hot reload dependency discovery failed: {error:#}"
                        ))
                    }
                }
                match scanned {
                    Ok((current, directories)) => {
                        let changed = baseline
                            .as_ref()
                            .is_some_and(|previous| previous != &current);
                        // Content digests on native saves cover preserved metadata;
                        // the same baseline also deduplicates delayed native events.
                        if changed {
                            revision.version = revision.version.saturating_add(1);
                            revision.changed_at = Some(last_event.unwrap_or(now));
                        }
                        *signals.roots.lock().unwrap() = sources.roots.clone();
                        *signals.configuration_dirs.lock().unwrap() =
                            sources.configuration_dirs.clone();
                        baseline = Some(current);
                        revision.ready = true;
                        last_event = None;
                        source_hint = false;
                        if watcher.is_none() {
                            match create_watcher(signals.clone()) { Ok(created) => watcher = Some(created), Err(error) => problem = Some(format!("Automatic hot reload file watcher unavailable; using polling: {error}")) }
                        }
                        if let Some(active) = watcher.as_mut() {
                            let mut failed = false;
                            for path in watched.difference(&directories) {
                                let _ = active.unwatch(path);
                            }
                            for path in directories.difference(&watched) {
                                if let Err(error) = active.watch(path, RecursiveMode::NonRecursive)
                                {
                                    problem = Some(format!("Automatic hot reload cannot watch {}; using polling: {error}", path.display()));
                                    failed = true;
                                    break;
                                }
                            }
                            if failed {
                                watcher = None;
                                watched.clear();
                            } else {
                                watched = directories;
                            }
                        }
                    }
                    Err(error) => {
                        problem = Some(format!("Automatic hot reload scan failed: {error:#}"));
                    }
                }
            }
            Err(error) => {
                problem = Some(format!("Automatic hot reload scan task failed: {error}"));
            }
        }
        retry_after = problem.as_ref().map(|_| Instant::now() + FALLBACK_POLL);
        revision.error = problem;
        revisions.send_replace(revision.clone());
        next_poll = Instant::now()
            + if watcher.is_some() && revision.error.is_none() {
                POLL
            } else {
                FALLBACK_POLL
            };
    }
}

pub(crate) fn hot_reload_supported(mode: RunMode, no_debug: bool, capabilities: &str) -> bool {
    let capabilities: serde_json::Value = serde_json::from_str(capabilities).unwrap_or_default();
    let advertised = capabilities["supportsHotReload"].as_bool();
    mode == RunMode::Debug && advertised != Some(false) && (!no_debug || advertised == Some(true))
}

pub(crate) fn start(session: Arc<Session>) {
    tokio::spawn(async move {
        let mut enabled = session.auto_reload.subscribe();
        let mut state = session.subscribe_state();
        let mut monitor: Option<Arc<Monitor>> = None;
        let mut updates = None;
        let mut consumed = 0;
        let mut subscribed_at = Instant::now();
        let mut reported_error = None;
        let mut reported_ready = false;
        let mut tick = tokio::time::interval(Duration::from_millis(150));
        loop {
            tokio::select! {
                _ = tick.tick() => {},
                result = enabled.changed() => {
                    if result.is_err() { break; }
                    monitor = None; updates = None; reported_ready = false; reported_error = None;
                },
                result = state.changed() => { if result.is_err() { break; } },
                _ = async { if let Some(updates) = &mut updates { let _ = watch::Receiver::<Revision>::changed(updates).await; } else { std::future::pending::<()>().await; } } => {},
            }
            let snapshot = session.snapshot.lock().await.clone();
            if matches!(
                snapshot.state,
                SessionState::Stopping | SessionState::Ended | SessionState::Failed
            ) {
                break;
            }
            if !*enabled.borrow()
                || !hot_reload_supported(
                    snapshot.mode,
                    snapshot.no_debug,
                    &snapshot.capabilities_json,
                )
            {
                monitor = None;
                updates = None;
                reported_ready = false;
                continue;
            }
            if monitor.is_none() {
                match Monitor::subscribe(Path::new(&snapshot.project_path)) {
                    Ok(next) => {
                        consumed = next.revisions.borrow().version;
                        subscribed_at = Instant::now();
                        updates = Some(next.revisions.subscribe());
                        monitor = Some(next);
                    }
                    Err(error) => {
                        let error = format!("Automatic hot reload monitor failed: {error:#}");
                        if reported_error.as_ref() != Some(&error) {
                            session.logs.lock().await.push("error", &error);
                            reported_error = Some(error);
                        }
                        continue;
                    }
                }
            }
            let revision = monitor.as_ref().unwrap().revisions.borrow().clone();
            if revision.error != reported_error {
                if let Some(error) = &revision.error {
                    session.logs.lock().await.push("error", error);
                }
                reported_error = revision.error.clone();
            }
            if revision.ready && !reported_ready {
                session
                    .logs
                    .lock()
                    .await
                    .push("system", "Automatic hot reload monitoring ready");
                reported_ready = true;
            }
            if revision.changed_at.is_some_and(|last| last < subscribed_at) {
                consumed = revision.version;
            }
            if revision.version > consumed
                && revision
                    .changed_at
                    .is_some_and(|last| Instant::now().duration_since(last) >= DEBOUNCE)
            {
                // Capture before awaiting: source changes during DAP remain a
                // newer revision. Busy/disabled sessions do not consume work.
                if session.try_automatic_hot_reload().await.is_some() {
                    consumed = revision.version;
                }
            }
        }
    });
}

#[cfg(test)]
mod tests;
