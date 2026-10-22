import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/presentation/workbench_models.dart';
import '../../core/presentation/workbench_select.dart';
import '../build/build_dialog.dart';
import '../build/build_tasks_dialog.dart';
import '../debugger/debugger_panel.dart';
import '../devtools/devtools_panel.dart';
import '../logs/log_panel.dart';
import '../settings/settings_page.dart';
import '../testing/test_panel.dart';
import 'run_profile_controls.dart';

class Workbench extends StatefulWidget {
  const Workbench({
    super.key,
    required this.bridge,
    required this.themeMode,
    required this.onThemeChanged,
  });
  final WorkbenchBridge bridge;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  @override
  State<Workbench> createState() => _WorkbenchState();
}

// Each project keeps its own unsubmitted form. Running sessions remain owned by
// the bridge; the last submitted config is only used by the quick-run button.
class _ProjectDraft {
  _ProjectDraft(Project project)
    : entrypoint = TextEditingController(text: project.entrypoint);
  final sdkPath = TextEditingController();
  final TextEditingController entrypoint;
  final flavor = TextEditingController();
  final defines = TextEditingController();
  final environment = TextEditingController();
  final toolArgs = TextEditingController();
  final attachUri = TextEditingController();
  Sdk? sdk;
  List<Device> devices = [];
  List<Emulator> emulators = [];
  String? deviceId, platform;
  String mode = 'debug';
  bool noDebug = false;
  bool advancedExpanded = false;
  int deviceRequest = 0;
  int sdkRequest = 0;
  ProjectGitInfo? git;
  String? gitError;
  bool gitLoading = false;
  int gitRequest = 0;
  RunConfig? lastConfig;
  RunProfile? lastProfile;
  String? selectedProfileId;
  bool autoReload = false, touched = false;
  void dispose() {
    for (final controller in [
      sdkPath,
      entrypoint,
      flavor,
      defines,
      environment,
      toolArgs,
      attachUri,
    ]) {
      controller.dispose();
    }
  }
}

class _WorkbenchState extends State<Workbench> {
  final _builds = ValueNotifier<List<BuildSnapshot>>([]);
  Timer? _buildRefresh;
  Future<void>? _buildRead;
  int _buildRevision = 0;
  final _pendingBuilds = <Future<BuildSnapshot>>{};
  final _pendingSessionStarts = <Future<Session>>{};
  bool _closing = false;
  final _sessions = ValueNotifier<List<Session>>([]);
  final _selected = ValueNotifier<Session?>(null);
  final _accepted = <String, (int, int)>{};
  final _drafts = <String, _ProjectDraft>{};
  final _collapsed = <String>{};
  StreamSubscription<WorkbenchEvent>? _subscription;
  late final AppLifecycleListener _lifecycle;
  final List<Project> _projects = [];
  Project? _project;
  Project? _pendingSdkProject;
  String? _error, _busy;
  Project? _errorProject;
  int _tab = 0;
  int _viewRevision = 0;
  int _gitRevision = 0;
  bool _settingsOpen = false;
  Timer? _deviceRefresh;
  bool _workspaceLoaded = false, _workspaceReading = false;
  bool _workspaceDirty = false, _workspaceSaving = false;
  int _workspaceRevision = 0, _workspaceSelectionRevision = 0;
  String? _workspaceError;
  late Future<void> _workspaceLoad;
  Future<void> _workspaceSave = Future<void>.value();
  WorkspacePreferences _preferences = const WorkspacePreferences();
  Future<void> _preferenceSave = Future<void>.value();
  Timer? _preferenceTimer;
  int _preferenceRevision = 0;
  bool _preferenceDirty = false, _restoringDraft = false;
  String? _preferenceError;
  final _searchFocus = FocusNode();
  _ProjectDraft? get _draft =>
      _project == null ? null : _drafts[_project!.path];

  @override
  void initState() {
    super.initState();
    _subscription = widget.bridge.events.listen(
      _event,
      onError: (Object e) {
        if (mounted) setState(() => _error = '$e');
      },
    );
    _lifecycle = AppLifecycleListener(onExitRequested: _exit);
    _workspaceLoad = _readWorkspace();
    unawaited(_refreshBuilds().catchError((Object _) {}));
    _perform('读取会话', () async {
      await _workspaceLoad;
      final sessions = await widget.bridge.listSessions();
      if (!mounted) return;
      for (final session in sessions) {
        _upsert(session);
      }
    });
  }

  Future<AppExitResponse> _exit() async {
    List<TestRunSnapshot> tests;
    try {
      tests = await widget.bridge.listTestRuns();
    } catch (error) {
      if (mounted) setState(() => _error = '读取后台测试失败，退出已取消：$error');
      return AppExitResponse.cancel;
    }
    if (!mounted) return AppExitResponse.cancel;
    if (_sessions.value.any((s) => s.active) ||
        tests.any((run) => run.active) ||
        _builds.value.any((build) => build.active) ||
        _pendingSessionStarts.isNotEmpty ||
        _pendingBuilds.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('退出 Flutter Dev？'),
          content: const Text('退出将停止后台构建、测试和本应用启动的会话，并清理子进程。附加会话将解除连接。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续工作'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('停止任务并退出'),
            ),
          ],
        ),
      );
      if (confirmed != true) return AppExitResponse.cancel;
    }
    try {
      setState(() => _closing = true);
      // A dismissed window may still be awaiting the native start response.
      // Let those requests register before shutting down their owned processes.
      await Future.wait([
        for (final pending in _pendingBuilds.toList())
          pending.then<void>((_) {}, onError: (Object _) {}),
        for (final pending in _pendingSessionStarts.toList())
          pending.then<void>((_) {}, onError: (Object _) {}),
      ]);
      await _workspaceLoad;
      await _workspaceSave;
      if (_workspaceDirty) {
        if (!_workspaceLoaded) {
          if (mounted) {
            setState(() => _workspaceError = '项目列表尚未读取成功，当前导入项目还未保存。请重试读取后退出。');
          }
          return AppExitResponse.cancel;
        }
        _queueWorkspaceSave();
      }
      await _workspaceSave;
      if (_workspaceDirty) return AppExitResponse.cancel;
      _preferenceTimer?.cancel();
      if (_preferenceDirty) _queuePreferenceSave();
      await _preferenceSave;
      if (_preferenceDirty) return AppExitResponse.cancel;
      await widget.bridge.shutdown();
      return AppExitResponse.exit;
    } catch (e) {
      if (mounted) setState(() => _error = '退出清理失败：$e');
      return AppExitResponse.cancel;
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  Future<BuildSnapshot> _startBackgroundBuild(BuildConfig config) async {
    if (_closing) throw StateError('应用正在退出，请稍后重试');
    final pending = widget.bridge.startBuild(config);
    _pendingBuilds.add(pending);
    try {
      final snapshot = await pending;
      _buildStarted(snapshot);
      return snapshot;
    } finally {
      _pendingBuilds.remove(pending);
    }
  }

  Future<void> _refreshBuilds() {
    return _buildRead ??= _loadBuilds().whenComplete(() => _buildRead = null);
  }

  Future<void> _loadBuilds() async {
    final revision = _buildRevision;
    try {
      final builds = await widget.bridge.listBuilds();
      if (mounted && revision == _buildRevision) _builds.value = builds;
    } finally {
      if (mounted && _builds.value.any((build) => build.active)) {
        _scheduleBuildRefresh();
      }
    }
  }

  void _scheduleBuildRefresh() {
    _buildRefresh?.cancel();
    _buildRefresh = Timer(const Duration(seconds: 1), () {
      if (mounted) unawaited(_refreshBuilds().catchError((Object _) {}));
    });
  }

  void _buildStarted(BuildSnapshot snapshot) {
    if (!mounted) return;
    _buildRevision++;
    _builds.value = [
      snapshot,
      ..._builds.value.where((build) => build.id != snapshot.id),
    ];
    _scheduleBuildRefresh();
  }

  Future<void> _openBuildTasks() async {
    await showDialog<void>(
      context: context,
      builder: (_) => BuildTasksDialog(
        bridge: widget.bridge,
        builds: _builds,
        onRefresh: _refreshBuilds,
      ),
    );
    if (mounted) unawaited(_refreshBuilds().catchError((Object _) {}));
  }

  Future<void> _readWorkspace() async {
    final selectionRevision = _workspaceSelectionRevision;
    if (mounted) setState(() => _workspaceReading = true);
    try {
      final settings = await widget.bridge.getAppSettings();
      if (!mounted) return;
      setState(() {
        _preferences = settings.workspacePreferences;
        // Merge rather than replace: imports made while the read was pending
        // remain in memory, and saved paths are retained even if unavailable.
        _addProjects(settings.projects);
        for (final project in _projects) {
          final draft = _drafts[project.path]!;
          _restoreProjectPreferences(project, draft);
        }
        if (selectionRevision == 0 &&
            selectionRevision == _workspaceSelectionRevision) {
          _project =
              _projects
                  .where(
                    (project) => project.path == settings.selectedProjectPath,
                  )
                  .firstOrNull ??
              _project ??
              _projects.firstOrNull;
          if (!_settingsOpen && _selected.value == null && _project != null) {
            _pendingSdkProject = _drafts[_project!.path]!.sdk == null
                ? _project
                : null;
          }
        }
        _workspaceLoaded = true;
        _workspaceError = null;
      });
      if (_workspaceDirty) _queueWorkspaceSave();
      if (_preferenceDirty) _queuePreferenceSave();
      _resolvePendingSdk();
    } catch (e) {
      if (mounted) setState(() => _workspaceError = '读取项目列表失败：$e');
    } finally {
      if (mounted) setState(() => _workspaceReading = false);
    }
  }

  void _workspaceChanged() {
    _workspaceRevision++;
    _workspaceDirty = true;
    if (_workspaceLoaded) _queueWorkspaceSave();
  }

  void _queueWorkspaceSave() {
    if (!_workspaceLoaded || !_workspaceDirty) return;
    final revision = _workspaceRevision;
    final projects = List<Project>.unmodifiable(_projects);
    final selectedProjectPath = _project?.path;
    if (mounted) setState(() => _workspaceSaving = true);
    _workspaceSave = _workspaceSave.then((_) async {
      try {
        await widget.bridge.setWorkspaceProjects(projects, selectedProjectPath);
        // Persistence returns the whole config. Only this snapshot's success
        // matters here; SDK/theme responses never overwrite the visible list.
        if (revision == _workspaceRevision) {
          _workspaceDirty = false;
          if (mounted) setState(() => _workspaceError = null);
        }
      } catch (e) {
        if (mounted && revision == _workspaceRevision) {
          setState(() => _workspaceError = '项目列表保存失败：$e。当前窗口中的项目仍然保留。');
        }
      } finally {
        if (mounted && revision == _workspaceRevision) {
          setState(() => _workspaceSaving = false);
        }
      }
    });
  }

  void _retryWorkspace() {
    if (_workspaceLoaded) {
      if (!_workspaceSaving) _queueWorkspaceSave();
    } else if (!_workspaceReading) {
      _workspaceLoad = _readWorkspace();
    }
  }

  void _event(WorkbenchEvent event) {
    if (!mounted) return;
    if (event.sessionId != null) {
      final previous = _accepted[event.sessionId];
      if (previous != null &&
          (event.generation < previous.$1 ||
              (event.generation == previous.$1 &&
                  event.sequence <= previous.$2))) {
        return;
      }
      _accepted[event.sessionId!] = (event.generation, event.sequence);
    }
    if (event.session case final session?) _upsert(session);
    if (event.kind == 'devices') {
      _deviceRefresh?.cancel();
      _deviceRefresh = Timer(const Duration(milliseconds: 150), () {
        final project = _project;
        final draft = _draft;
        if (!_settingsOpen &&
            _busy == null &&
            project != null &&
            draft?.sdk != null) {
          _perform('刷新设备', () => _refreshDevices(project, draft!));
        }
      });
    }
  }

  void _addProjects(List<Project> projects) {
    for (final project in projects) {
      if (_projects.any((p) => p.path == project.path)) continue;
      _projects.add(project);
      _drafts[project.path] = _ProjectDraft(project);
      final draft = _drafts[project.path]!;
      _restoreProjectPreferences(project, draft);
      for (final controller in [
        draft.sdkPath,
        draft.entrypoint,
        draft.flavor,
        draft.defines,
        draft.environment,
        draft.toolArgs,
        draft.attachUri,
      ]) {
        controller.addListener(() => _draftChanged(draft));
      }
      unawaited(
        Future<void>.microtask(() {
          // Selecting an imported project starts its read immediately. Do not
          // launch a second Git process when this queued initial read runs.
          if (mounted && !draft.gitLoading) return _refreshGit(project);
        }),
      );
    }
  }

  void _restoreProjectPreferences(Project project, _ProjectDraft draft) {
    final saved = _preferences.projectStates
        .where((s) => s.projectPath == project.path)
        .firstOrNull;
    if (saved == null) return;
    draft.selectedProfileId = saved.selectedProfileId;
    draft.autoReload = saved.autoReload;
    draft.lastProfile = saved.lastRun;
    draft.lastConfig = saved.lastRun == null
        ? null
        : _profileConfig(saved.lastRun!);
    if (!draft.touched && saved.draft != null) {
      _applyProfile(draft, saved.draft!);
    }
  }

  void _applyProfile(_ProjectDraft draft, RunProfile profile) {
    _restoringDraft = true;
    try {
      draft.sdkPath.text = profile.sdkPath ?? '';
      draft.entrypoint.text = profile.entrypoint;
      draft.flavor.text = profile.flavor ?? '';
      draft.defines.text = profile.dartDefines.join('\n');
      draft.environment.text =
          profile.environmentText ??
          profile.environment.entries
              .map((e) => '${e.key}=${e.value}')
              .join('\n');
      draft.toolArgs.text =
          profile.toolArgsText ??
          (profile.toolArgs.isEmpty ? '' : jsonEncode(profile.toolArgs));
      draft.attachUri.text = profile.attachUri ?? '';
      draft.deviceId = profile.deviceId;
      draft.platform = profile.platform;
      draft.mode = profile.mode;
      draft.noDebug = profile.noDebug;
      draft.sdkRequest++;
      draft.deviceRequest++;
      draft.sdk = null;
      draft.devices = [];
      draft.emulators = [];
    } finally {
      _restoringDraft = false;
    }
  }

  RunConfig _profileConfig(RunProfile p, {String? sdkPath}) => RunConfig(
    sdkPath: sdkPath ?? p.sdkPath ?? '',
    projectPath: p.projectPath,
    deviceId: p.deviceId ?? '',
    entrypoint: p.entrypoint,
    mode: p.mode,
    flavor: p.flavor,
    attachUri: p.attachUri,
    dartDefines: p.dartDefines,
    env: p.environment,
    toolArgs: p.toolArgs,
    noDebug: p.noDebug,
    sdkPreference: p.sdkPath ?? '',
  );

  RunProfile _captureProfile(
    Project project,
    _ProjectDraft draft, {
    String id = 'draft',
    String name = '当前草稿',
    bool validate = false,
  }) {
    final env = <String, String>{};
    List<String> args = [];
    try {
      for (final line
          in draft.environment.text
              .split('\n')
              .where((s) => s.trim().isNotEmpty)) {
        final equals = line.indexOf('=');
        if (equals <= 0) throw const FormatException('环境变量应为每行 KEY=VALUE');
        env[line.substring(0, equals).trim()] = line.substring(equals + 1);
      }
      if (draft.toolArgs.text.trim().isNotEmpty) {
        final decoded = jsonDecode(draft.toolArgs.text);
        if (decoded is! List || decoded.any((v) => v is! String)) {
          throw const FormatException('工具参数应为 JSON 字符串数组');
        }
        args = decoded.cast<String>();
      }
    } on FormatException {
      if (validate) rethrow;
    }
    return RunProfile(
      id: id,
      name: name,
      projectPath: project.path,
      sdkPath: draft.sdkPath.text.trim().isEmpty
          ? null
          : draft.sdkPath.text.trim(),
      deviceId: draft.deviceId,
      platform: draft.platform,
      entrypoint: draft.entrypoint.text.trim(),
      mode: draft.mode,
      flavor: draft.flavor.text.trim().isEmpty
          ? null
          : draft.flavor.text.trim(),
      dartDefines: draft.defines.text
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      environment: env,
      toolArgs: args,
      noDebug: draft.noDebug,
      attachUri: draft.attachUri.text.trim().isEmpty
          ? null
          : draft.attachUri.text.trim(),
      environmentText: draft.environment.text,
      toolArgsText: draft.toolArgs.text,
    );
  }

  void _draftChanged(_ProjectDraft draft) {
    if (_restoringDraft) return;
    draft.touched = true;
    _preferenceDirty = true;
    _preferenceRevision++;
    _preferenceTimer?.cancel();
    _preferenceTimer = Timer(
      const Duration(milliseconds: 400),
      _queuePreferenceSave,
    );
  }

  WorkspacePreferences _preferenceSnapshot() => WorkspacePreferences(
    runProfiles: List.unmodifiable(_preferences.runProfiles),
    editorExecutable: _preferences.editorExecutable,
    editorArguments: List.unmodifiable(_preferences.editorArguments),
    projectStates: [
      ..._preferences.projectStates.where(
        (s) => !_drafts.containsKey(s.projectPath),
      ),
      for (final project in _projects)
        ProjectRunState(
          projectPath: project.path,
          draft: _captureProfile(project, _drafts[project.path]!),
          lastRun: _drafts[project.path]!.lastProfile,
          selectedProfileId: _drafts[project.path]!.selectedProfileId,
          autoReload: _drafts[project.path]!.autoReload,
        ),
    ],
  );

  Future<bool> _queuePreferenceSave() {
    if (!_workspaceLoaded || !_preferenceDirty) {
      return Future.value(!_preferenceDirty);
    }
    final completion = Completer<bool>();
    final revision = _preferenceRevision;
    final snapshot = _preferenceSnapshot();
    _preferences = snapshot;
    _preferenceSave = _preferenceSave.then((_) async {
      try {
        await widget.bridge.setWorkspacePreferences(snapshot);
        if (revision == _preferenceRevision) {
          _preferenceDirty = false;
          if (mounted) setState(() => _preferenceError = null);
        }
        completion.complete(true);
      } catch (error) {
        if (mounted && revision == _preferenceRevision) {
          setState(() => _preferenceError = '运行配置保存失败：$error');
        }
        completion.complete(false);
      }
    });
    return completion.future;
  }

  Future<void> _saveEditor(String executable, List<String> arguments) async {
    if (!_workspaceLoaded) throw StateError('请先重新读取工作台设置');
    _preferences = WorkspacePreferences(
      runProfiles: _preferences.runProfiles,
      projectStates: _preferences.projectStates,
      editorExecutable: executable,
      editorArguments: arguments,
    );
    _preferenceDirty = true;
    _preferenceRevision++;
    if (!await _queuePreferenceSave()) {
      throw StateError(_preferenceError ?? '设置尚未保存');
    }
  }

  Future<void> _selectProfile(
    Project project,
    _ProjectDraft draft,
    String id,
  ) async {
    if (id.isNotEmpty) {
      final profile = _preferences.runProfiles
          .where((p) => p.projectPath == project.path && p.id == id)
          .firstOrNull;
      if (profile == null) return;
      setState(() => _applyProfile(draft, profile));
    }
    setState(() => draft.selectedProfileId = id.isEmpty ? null : id);
    _draftChanged(draft);
    _pendingSdkProject = draft.sdk == null ? project : null;
    _resolvePendingSdk();
  }

  Future<void> _manageProfile(
    Project project,
    _ProjectDraft draft,
    String action,
  ) async {
    try {
      final current = _preferences.runProfiles
          .where(
            (p) =>
                p.id == draft.selectedProfileId &&
                p.projectPath == project.path,
          )
          .firstOrNull;
      if (action != 'save-as' && current == null) return;
      if (action == 'delete') {
        setState(() {
          _preferences = WorkspacePreferences(
            runProfiles: _preferences.runProfiles
                .where((p) => p != current)
                .toList(),
            projectStates: _preferences.projectStates,
            editorExecutable: _preferences.editorExecutable,
            editorArguments: _preferences.editorArguments,
          );
          draft.selectedProfileId = null;
        });
      } else {
        var name = current?.name ?? '';
        if (action == 'save-as' || action == 'rename') {
          final result = await showDialog<String>(
            context: context,
            builder: (_) => RunProfileNameDialog(
              initialName: action == 'rename' ? name : '新运行配置',
              title: action == 'rename' ? '重命名运行配置' : '保存运行配置',
            ),
          );
          if (!mounted || result == null) return;
          name = result;
        }
        final id = action == 'save-as'
            ? 'profile-${DateTime.now().microsecondsSinceEpoch}'
            : current!.id;
        final profile = action == 'rename'
            ? RunProfile(
                id: id,
                name: name,
                projectPath: current!.projectPath,
                sdkPath: current.sdkPath,
                deviceId: current.deviceId,
                platform: current.platform,
                entrypoint: current.entrypoint,
                mode: current.mode,
                flavor: current.flavor,
                dartDefines: current.dartDefines,
                environment: current.environment,
                toolArgs: current.toolArgs,
                attachUri: current.attachUri,
                noDebug: current.noDebug,
                environmentText: current.environmentText,
                toolArgsText: current.toolArgsText,
              )
            : _captureProfile(
                project,
                draft,
                id: id,
                name: name,
                validate: true,
              );
        setState(() {
          _preferences = WorkspacePreferences(
            runProfiles: [
              ..._preferences.runProfiles.where(
                (p) => !(p.projectPath == project.path && p.id == id),
              ),
              profile,
            ],
            projectStates: _preferences.projectStates,
            editorExecutable: _preferences.editorExecutable,
            editorArguments: _preferences.editorArguments,
          );
          draft.selectedProfileId = id;
        });
      }
      _draftChanged(draft);
      _preferenceTimer?.cancel();
      _queuePreferenceSave();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _refreshGit(Project project) async {
    if (!mounted) return;
    final draft = _drafts[project.path]!;
    final request = ++_gitRevision;
    draft.gitRequest = request;
    setState(() {
      draft.gitLoading = true;
      draft.gitError = null;
    });
    try {
      final info = await widget.bridge.projectGitInfo(project.path);
      if (!mounted || request != draft.gitRequest) return;
      setState(() {
        draft.git = info;
        if (info != null) {
          for (final sibling in _drafts.values) {
            if (identical(sibling, draft) ||
                sibling.git?.repositoryRoot != info.repositoryRoot ||
                sibling.gitRequest > request) {
              continue;
            }
            sibling.gitRequest = request;
            sibling.git = info;
            sibling.gitLoading = false;
            sibling.gitError = null;
          }
        }
      });
    } catch (error) {
      if (mounted && request == draft.gitRequest) {
        setState(() => draft.gitError = '读取 Git 分支失败：$error');
      }
    } finally {
      if (mounted && request == draft.gitRequest) {
        setState(() => draft.gitLoading = false);
      }
    }
  }

  Future<void> _switchBranch(Project project, String branch) async {
    final draft = _drafts[project.path]!;
    final git = draft.git;
    if (_busy != null ||
        draft.gitLoading ||
        git == null ||
        branch == git.currentBranch) {
      return;
    }
    final related = _projects
        .where(
          (p) => _drafts[p.path]!.git?.repositoryRoot == git.repositoryRoot,
        )
        .toList();
    // Invalidate reads already in flight for every known project in this
    // checkout. A late pre-switch result must not restore the old branch.
    setState(() {
      for (final item in related) {
        final state = _drafts[item.path]!;
        state.gitRequest = ++_gitRevision;
        state.gitLoading = true;
        state.gitError = null;
      }
    });
    await _perform('切换分支', () async {
      try {
        final info = await widget.bridge.switchProjectBranch(
          project.path,
          branch,
        );
        if (!mounted) return;
        for (final item in _projects) {
          if (!related.contains(item) &&
              _drafts[item.path]!.git?.repositoryRoot == info.repositoryRoot) {
            related.add(item);
          }
        }
        setState(() {
          for (final item in related) {
            final state = _drafts[item.path]!;
            state.gitRequest = ++_gitRevision;
            state.git = info;
            state.sdkRequest++;
            state.deviceRequest++;
            state.sdk = null;
            state.devices = [];
            state.emulators = [];
            state.deviceId = null;
          }
        });
        if (!_settingsOpen &&
            _selected.value == null &&
            related.any((p) => p.path == _project?.path)) {
          _pendingSdkProject = _project;
        }
        // A sibling package's initial detection may still be pending. Restart
        // those reads too, so it discovers the new HEAD of this checkout.
        for (final item in _projects) {
          if (_drafts[item.path]!.git == null) unawaited(_refreshGit(item));
        }
      } catch (error) {
        if (mounted) setState(() => draft.gitError = '切换 Git 分支失败：$error');
      } finally {
        if (mounted) {
          setState(() {
            for (final item in related) {
              _drafts[item.path]!.gitLoading = false;
            }
          });
        }
      }
    });
  }

  void _upsert(Session session) {
    final current = _sessions.value
        .where((s) => s.id == session.id)
        .firstOrNull;
    if (current != null &&
        (current.generation > session.generation ||
            (current.generation == session.generation &&
                current.sequence >= session.sequence))) {
      return;
    }
    if (!_projects.any((p) => p.path == session.projectPath)) {
      setState(
        () => _addProjects([
          Project(
            name: session.projectPath.split(RegExp(r'[/\\]')).last,
            path: session.projectPath,
          ),
        ]),
      );
      _workspaceChanged();
    }
    _sessions.value = current == null
        ? [..._sessions.value, session]
        : _sessions.value.map((s) => s.id == session.id ? session : s).toList();
    // A background snapshot must never replace a project configuration view.
    if (_selected.value?.id == session.id) _selected.value = session;
  }

  Future<void> _perform(
    String label,
    Future<void> Function() action, {
    Project? errorProject,
  }) async {
    if (!mounted) return;
    setState(() {
      _busy = label;
      _error = null;
      _errorProject = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$label失败：$e';
          _errorProject = errorProject;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = null);
        _resolvePendingSdk();
      }
    }
  }

  Future<void> _addProject() async {
    final projects = await showDialog<List<Project>>(
      context: context,
      builder: (_) => _AddProjectDialog(bridge: widget.bridge),
    );
    if (!mounted || projects == null || projects.isEmpty) return;
    setState(() => _addProjects(projects));
    _selectProject(_projects.firstWhere((p) => p.path == projects.first.path));
  }

  void _selectProject(Project project) {
    _workspaceSelectionRevision++;
    _viewRevision++;
    setState(() {
      _settingsOpen = false;
      _project = project;
    });
    _selected.value = null;
    _workspaceChanged();
    final draft = _drafts[project.path]!;
    if (!draft.gitLoading && _busy != '切换分支') {
      unawaited(_refreshGit(project));
    }
    _pendingSdkProject = draft.sdk == null ? project : null;
    _resolvePendingSdk();
  }

  void _resolvePendingSdk() {
    final project = _pendingSdkProject;
    if (_closing || _busy != null || project == null) return;
    _pendingSdkProject = null;
    final draft = _drafts[project.path]!;
    if (draft.sdk == null) {
      _perform('解析 SDK', () => _resolveSdk(project, draft));
    }
  }

  void _selectSession(Session session) {
    _workspaceSelectionRevision++;
    _pendingSdkProject = null;
    _viewRevision++;
    setState(() {
      _settingsOpen = false;
      _project = _projects.firstWhere((p) => p.path == session.projectPath);
    });
    _selected.value = session;
    _workspaceChanged();
  }

  void _openSettings() {
    _viewRevision++;
    _pendingSdkProject = null;
    setState(() => _settingsOpen = true);
    _selected.value = null;
  }

  void _settingsSaved(AppSettings settings) {
    if (!mounted) return;
    if (!_workspaceLoaded && !_workspaceReading) {
      // A successful settings repair may make a previously unreadable config
      // available again. Re-read it before persisting the imported projects.
      _workspaceLoad = _readWorkspace();
    }
    setState(() {
      for (final draft in _drafts.values) {
        draft.sdkRequest++;
        draft.deviceRequest++;
        draft.sdk = null;
        draft.devices = [];
        draft.emulators = [];
        draft.deviceId = null;
      }
    });
    if (!_settingsOpen && _selected.value == null && _project != null) {
      _pendingSdkProject = _project;
      _resolvePendingSdk();
    }
  }

  Future<void> _resolveSdk(Project project, _ProjectDraft draft) async {
    final explicit = draft.sdkPath.text.trim();
    final request = ++draft.sdkRequest;
    setState(() {
      draft.sdk = null;
      draft.devices = [];
      draft.emulators = [];
    });
    final sdk = await widget.bridge.resolveSdk(
      project.path,
      explicit.isEmpty ? null : explicit,
    );
    if (!mounted ||
        request != draft.sdkRequest ||
        explicit != draft.sdkPath.text.trim()) {
      return;
    }
    setState(() => draft.sdk = sdk);
    await _refreshDevices(project, draft);
  }

  String _platformOf(Device device) => device.platform.startsWith('web')
      ? 'web'
      : device.platform.startsWith('darwin')
      ? 'macos'
      : device.platform.split('-').first;

  bool _compatible(Project project, _ProjectDraft draft, Device device) {
    final platform = _platformOf(device);
    return (project.platforms.isEmpty ||
            project.platforms.contains(platform)) &&
        (draft.platform == null || draft.platform == platform);
  }

  void _pickAvailableDevice(Project project, _ProjectDraft draft) {
    if (!draft.devices.any(
      (d) =>
          d.id == draft.deviceId &&
          d.available &&
          _compatible(project, draft, d),
    )) {
      draft.deviceId = draft.devices
          .where((d) => d.available && _compatible(project, draft, d))
          .firstOrNull
          ?.id;
    }
  }

  Future<void> _refreshDevices(Project project, _ProjectDraft draft) async {
    final sdk = draft.sdk;
    if (sdk == null) return;
    final request = ++draft.deviceRequest;
    final result = await Future.wait([
      widget.bridge.listDevices(sdk.path),
      widget.bridge.listEmulators(sdk.path),
    ]);
    if (!mounted || draft.sdk != sdk || request != draft.deviceRequest) return;
    setState(() {
      draft.devices = result[0].cast<Device>();
      draft.emulators = result[1].cast<Emulator>();
      _pickAvailableDevice(project, draft);
    });
  }

  RunConfig _readConfig(Project project, _ProjectDraft draft) {
    final profile = _captureProfile(project, draft, validate: true);
    return _profileConfig(profile, sdkPath: draft.sdk!.path);
  }

  Future<void> _start(
    Project project,
    _ProjectDraft draft, {
    bool quick = false,
  }) {
    if (_closing) return Future<void>.value();
    final revision = _viewRevision;
    return _perform('启动会话', () async {
      final submitted = quick ? draft.lastConfig! : _readConfig(project, draft);
      final preference = quick
          ? submitted.sdkPreference ?? submitted.sdkPath
          : draft.sdkPath.text.trim();
      final sdk = await widget.bridge.resolveSdk(
        project.path,
        preference.isEmpty ? null : preference,
      );
      if (!mounted) return;
      final config = RunConfig(
        sdkPath: sdk.path,
        projectPath: submitted.projectPath,
        deviceId: submitted.deviceId,
        entrypoint: submitted.entrypoint,
        mode: submitted.mode,
        flavor: submitted.flavor,
        attachUri: submitted.attachUri,
        dartDefines: submitted.dartDefines,
        env: submitted.env,
        toolArgs: submitted.toolArgs,
        noDebug: submitted.noDebug,
        sdkPreference: preference,
      );
      draft.lastConfig = config;
      draft.lastProfile = RunProfile(
        id: 'last-run',
        name: '上次启动',
        projectPath: config.projectPath,
        sdkPath: preference.isEmpty ? null : preference,
        deviceId: config.deviceId,
        entrypoint: config.entrypoint,
        mode: config.mode,
        flavor: config.flavor,
        dartDefines: config.dartDefines,
        environment: config.env,
        toolArgs: config.toolArgs,
        attachUri: config.attachUri,
        noDebug: config.noDebug,
        platform: draft.platform,
      );
      _draftChanged(draft);
      _preferenceTimer?.cancel();
      if (!await _queuePreferenceSave()) {
        throw StateError(_preferenceError ?? '运行配置尚未保存');
      }
      if (!mounted || _closing) return;
      final pending = widget.bridge.startSession(config);
      _pendingSessionStarts.add(pending);
      late Session session;
      try {
        session = await pending;
      } finally {
        _pendingSessionStarts.remove(pending);
      }
      if (!mounted) return;
      _upsert(session);
      if (_viewRevision == revision) {
        _collapsed.remove(project.path);
        _selectSession(_sessions.value.firstWhere((s) => s.id == session.id));
      }
    }, errorProject: project);
  }

  Future<void> _pause(Session session) =>
      _perform(session.state == 'paused' ? '继续会话' : '暂停会话', () async {
        final response = await widget.bridge.debuggerRequest(
          session.id,
          'threads',
          {},
        );
        final threads = (response['threads'] as List? ?? [])
            .whereType<Map>()
            .toList();
        final thread =
            threads
                .where((t) => '${t['name']}'.toLowerCase() == 'main')
                .firstOrNull ??
            threads.firstOrNull;
        if (thread?['id'] is! int) throw const FormatException('调试适配器没有返回有效线程');
        final current = _sessions.value
            .where((s) => s.id == session.id)
            .firstOrNull;
        if (current == null ||
            current.generation != session.generation ||
            current.state != session.state ||
            current.operation != null) {
          return;
        }
        await widget.bridge.debuggerRequest(
          session.id,
          session.state == 'paused' ? 'continue' : 'pause',
          {'threadId': thread!['id']},
        );
      });

  @override
  void dispose() {
    _subscription?.cancel();
    _deviceRefresh?.cancel();
    _buildRefresh?.cancel();
    _preferenceTimer?.cancel();
    _searchFocus.dispose();
    _lifecycle.dispose();
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    _sessions.dispose();
    _builds.dispose();
    _selected.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: _shortcuts,
    child: Focus(
      autofocus: true,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Row(
                    children: [
                      SizedBox(
                        width: constraints.maxWidth < 760 ? 180 : 248,
                        child: _sidebar(),
                      ),
                      Expanded(
                        child: ValueListenableBuilder<Session?>(
                          valueListenable: _selected,
                          builder: (context, session, _) => Column(
                            children: [
                              _workspaceHeader(session),
                              if (_busy != null)
                                const LinearProgressIndicator(minHeight: 2),
                              if (_error != null) _errorBanner(),
                              if (_workspaceError != null)
                                _workspaceErrorBanner(),
                              if (_preferenceError != null)
                                Material(
                                  color: _colors.errorContainer,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: Text(
                                            _preferenceError!,
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: _queuePreferenceSave,
                                        child: const Text('重试保存'),
                                      ),
                                    ],
                                  ),
                                ),
                              Expanded(
                                child: _settingsOpen
                                    ? SettingsPage(
                                        bridge: widget.bridge,
                                        themeMode: widget.themeMode,
                                        onThemeChanged: widget.onThemeChanged,
                                        onSaved: _settingsSaved,
                                        onEditorSaved: _saveEditor,
                                      )
                                    : session == null
                                    ? _configuration()
                                    : Column(
                                        key: const ValueKey(
                                          'session-workspace',
                                        ),
                                        children: [
                                          _tabs(),
                                          Expanded(child: _panel(session)),
                                        ],
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _status(),
            ],
          ),
        ),
      ),
    ),
  );

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.f5): () {
      final session = _selected.value;
      if (session?.state == 'paused' &&
          _busy == null &&
          session!.capabilities['debugger'] == true) {
        unawaited(_pause(session));
      } else if (session == null &&
          !_settingsOpen &&
          _project != null &&
          _draft != null &&
          _canRun(_project!, _draft!)) {
        unawaited(_start(_project!, _draft!));
      }
    },
    const SingleActivator(LogicalKeyboardKey.f5, shift: true): () {
      final session = _selected.value;
      if (session?.canStop == true && _busy == null) {
        unawaited(
          _perform('停止会话', () => widget.bridge.stopSession(session!.id)),
        );
      }
    },
    for (final meta in [false, true]) ...{
      SingleActivator(
        LogicalKeyboardKey.keyR,
        meta: meta,
        control: !meta,
      ): () =>
          _shortcutReload(false),
      SingleActivator(
        LogicalKeyboardKey.keyR,
        meta: meta,
        control: !meta,
        shift: true,
      ): () =>
          _shortcutReload(true),
      SingleActivator(LogicalKeyboardKey.keyF, meta: meta, control: !meta): () {
        if (_searchFocus.context != null) _searchFocus.requestFocus();
      },
      SingleActivator(
        LogicalKeyboardKey.arrowDown,
        meta: meta,
        control: !meta,
        alt: true,
      ): () =>
          _cycleProject(1),
      SingleActivator(
        LogicalKeyboardKey.arrowUp,
        meta: meta,
        control: !meta,
        alt: true,
      ): () =>
          _cycleProject(-1),
    },
    const SingleActivator(LogicalKeyboardKey.tab, control: true): () =>
        _cycleSession(1),
    const SingleActivator(
      LogicalKeyboardKey.tab,
      control: true,
      shift: true,
    ): () =>
        _cycleSession(-1),
    for (final entry in [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
    ].indexed)
      for (final meta in [false, true])
        SingleActivator(entry.$2, meta: meta, control: !meta): () {
          if (_selected.value != null) setState(() => _tab = entry.$1);
        },
  };

  void _shortcutReload(bool restart) {
    final session = _selected.value;
    final capability = restart ? 'supportsHotRestart' : 'supportsHotReload';
    if (_closing ||
        _busy != null ||
        session?.canReload != true ||
        session!.capabilities[capability] != true) {
      return;
    }
    unawaited(
      _perform(
        restart ? '热重启' : '热重载',
        () => restart
            ? widget.bridge.restart(session.id)
            : widget.bridge.reload(session.id),
      ),
    );
  }

  void _cycleProject(int delta) {
    if (_projects.isEmpty) return;
    final index = _projects.indexWhere((p) => p.path == _project?.path);
    _selectProject(_projects[(index + delta) % _projects.length]);
  }

  void _cycleSession(int delta) {
    if (_sessions.value.isEmpty) return;
    final index = _sessions.value.indexWhere(
      (s) => s.id == _selected.value?.id,
    );
    _selectSession(_sessions.value[(index + delta) % _sessions.value.length]);
  }

  Future<void> _openTests(Project project, _ProjectDraft draft) =>
      showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: SizedBox(
            width: 1000,
            height: MediaQuery.sizeOf(context).height * .85,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${project.name} · 测试',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭测试面板',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: TestPanel(
                    bridge: widget.bridge,
                    project: project,
                    sdkPreference: draft.sdkPath.text.trim().isEmpty
                        ? null
                        : draft.sdkPath.text.trim(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  void _showShortcuts() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('快捷键'),
      content: const SingleChildScrollView(
        child: Text(
          'F5  启动 / 继续\nShift + F5  停止会话\n⌘ / Ctrl + R  热重载\n⌘ / Ctrl + Shift + R  热重启\n⌘ / Ctrl + F  搜索当前日志 / 网络\n⌘ / Ctrl + Alt + ↑ / ↓  切换项目\nCtrl + Tab / Ctrl + Shift + Tab  切换会话\n⌘ / Ctrl + 1–4  切换会话页签',
          style: TextStyle(fontSize: 13, height: 2),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  ColorScheme get _colors => Theme.of(context).colorScheme;

  Widget _sidebar() => Container(
    key: const ValueKey('project-sidebar'),
    decoration: BoxDecoration(
      color: _colors.surfaceContainerLow,
      border: Border(right: BorderSide(color: _colors.outlineVariant)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 26, 12, 24),
          child: Row(
            children: [
              Image.asset(
                'assets/branding/app-icon-128.png',
                width: 32,
                height: 32,
                semanticLabel: 'Flutter Dev',
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Flutter Dev',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            key: const ValueKey('add-project'),
            onPressed: _addProject,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
            icon: const Icon(Icons.add, size: 20),
            label: const Text('新增项目'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 16, 12),
          child: Text(
            '项目',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: _colors.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<List<Session>>(
            valueListenable: _sessions,
            builder: (context, sessions, _) => ValueListenableBuilder<Session?>(
              valueListenable: _selected,
              builder: (context, selected, _) => _projects.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        '添加 Flutter 项目，\n开始新的运行会话。',
                        style: TextStyle(
                          color: _colors.onSurfaceVariant,
                          height: 1.7,
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final project in _projects) ...[
                          _projectRow(project, selected),
                          if (!_collapsed.contains(project.path)) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(30, 12, 12, 7),
                              child: Text(
                                '历史会话',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                            for (final session
                                in sessions
                                    .where((s) => s.projectPath == project.path)
                                    .toList()
                                    .reversed)
                              _sessionRow(session, selected),
                            if (!sessions.any(
                              (s) => s.projectPath == project.path,
                            ))
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  30,
                                  5,
                                  12,
                                  14,
                                ),
                                child: Text(
                                  '暂无会话',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                          const SizedBox(height: 14),
                        ],
                      ],
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: ValueListenableBuilder<List<BuildSnapshot>>(
            valueListenable: _builds,
            builder: (context, builds, _) {
              final active = builds.where((build) => build.active).length;
              return TextButton(
                key: const ValueKey('build-tasks'),
                onPressed: _openBuildTasks,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 13,
                  ),
                  foregroundColor: _colors.onSurfaceVariant,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.inventory_2_outlined, size: 19),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('构建任务', style: TextStyle(fontSize: 13)),
                    ),
                    if (active > 0)
                      Text(
                        '$active',
                        key: const ValueKey('active-build-count'),
                        style: TextStyle(color: _colors.primary, fontSize: 12),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Material(
            color: _settingsOpen
                ? _colors.primary.withValues(alpha: 0.09)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              key: const ValueKey('app-settings'),
              onTap: _openSettings,
              borderRadius: BorderRadius.circular(9),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.settings_outlined,
                      size: 19,
                      color: _colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    const Text('应用设置', style: TextStyle(fontSize: 13)),
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: _colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: _colors.outlineVariant),
            ),
            child: Row(
              children: [
                _themeButton(
                  ThemeMode.light,
                  Icons.light_mode_outlined,
                  '浅色',
                  'theme-light',
                ),
                _themeButton(
                  ThemeMode.dark,
                  Icons.dark_mode_outlined,
                  '深色',
                  'theme-dark',
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _themeButton(ThemeMode mode, IconData icon, String label, String key) {
    final selected = widget.themeMode == mode;
    return Expanded(
      child: Tooltip(
        message: label,
        child: Material(
          color: selected ? _colors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            key: ValueKey(key),
            borderRadius: BorderRadius.circular(8),
            onTap: () => widget.onThemeChanged(mode),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Icon(
                icon,
                size: 19,
                color: selected ? _colors.primary : _colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _projectRow(Project project, Session? selected) {
    final draft = _drafts[project.path]!;
    final highlighted = !_settingsOpen && _project?.path == project.path;
    return Material(
      color: highlighted
          ? _colors.primary.withValues(alpha: 0.09)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: Row(
        children: [
          IconButton(
            key: ValueKey('expand-${project.path}'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 30, height: 44),
            padding: EdgeInsets.zero,
            tooltip: _collapsed.contains(project.path) ? '展开会话' : '收起会话',
            onPressed: () => setState(() {
              if (!_collapsed.add(project.path)) {
                _collapsed.remove(project.path);
              }
            }),
            icon: Icon(
              _collapsed.contains(project.path)
                  ? Icons.chevron_right
                  : Icons.expand_more,
              size: 17,
            ),
          ),
          Expanded(
            child: InkWell(
              key: ValueKey('project-${project.path}'),
              onTap: () => _selectProject(project),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 13),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: project.path,
                      child: Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (draft.git case final git?) ...[
                      const SizedBox(height: 4),
                      Tooltip(
                        message: git.label,
                        child: Row(
                          children: [
                            Icon(
                              Icons.account_tree_outlined,
                              size: 12,
                              color: _colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                git.label,
                                key: ValueKey('project-branch-${project.path}'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            key: ValueKey('quick-run-${project.path}'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 34, height: 44),
            padding: EdgeInsets.zero,
            tooltip: draft.lastConfig == null ? '请先从启动配置运行一次' : '按上次配置启动新会话',
            onPressed: draft.lastConfig != null && _busy == null
                ? () => _start(project, draft, quick: true)
                : null,
            icon: Icon(
              Icons.play_arrow_rounded,
              size: 22,
              color: draft.lastConfig != null ? _colors.primary : null,
            ),
          ),
        ],
      ),
    );
  }

  String _sessionDevice(Session session) {
    final draft = _drafts[session.projectPath];
    return draft?.devices
            .where((d) => d.id == session.deviceId)
            .firstOrNull
            ?.name ??
        session.deviceId;
  }

  Widget _sessionRow(Session session, Session? selected) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 2, 4, 2),
    child: Material(
      color: selected?.id == session.id
          ? _colors.primary.withValues(alpha: 0.09)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: ValueKey('session-${session.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => _selectSession(session),
        child: Tooltip(
          message: '${session.id} · ${stateLabel(session.state)}',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 7,
                  color: session.state == 'failed'
                      ? _colors.error
                      : session.active
                      ? _colors.primary
                      : _colors.outline,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_sessionDevice(session)} · ${session.mode}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: selected?.id == session.id
                              ? _colors.onSurface
                              : _colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        stateLabel(session.state),
                        style: TextStyle(
                          fontSize: 10,
                          color: _colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _workspaceHeader(Session? session) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 760;
      final project = _project;
      final draft = _draft;
      final stackActions =
          constraints.maxWidth < 520 && !_settingsOpen && session == null;
      return Container(
        key: const ValueKey('workspace-header'),
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 18 : 28,
          vertical: 24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _settingsOpen ? '应用设置' : _project?.name ?? '工作台',
                        key: const ValueKey('workspace-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 22 : 27,
                          letterSpacing: -0.6,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_settingsOpen || session != null) ...[
                        const SizedBox(height: 7),
                        Text(
                          _settingsOpen
                              ? '个性化工作台与开发环境'
                              : '${_sessionDevice(session!)} · ${session.mode}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: _colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!_settingsOpen && session != null) ...[
                  const SizedBox(width: 12),
                  _sessionActions(session, compact: compact),
                ],
                if (!_settingsOpen &&
                    session == null &&
                    project != null &&
                    draft != null &&
                    !stackActions) ...[
                  const SizedBox(width: 12),
                  _projectActions(project, draft),
                ],
              ],
            ),
            if (!_settingsOpen &&
                session == null &&
                project != null &&
                draft != null &&
                (draft.git != null ||
                    draft.gitLoading ||
                    draft.gitError != null)) ...[
              const SizedBox(height: 4),
              _gitControls(project, draft),
            ],
            if (stackActions && project != null && draft != null) ...[
              const SizedBox(height: 10),
              _projectActions(project, draft),
            ],
          ],
        ),
      );
    },
  );

  Widget _projectActions(Project project, _ProjectDraft draft) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      FilledButton.icon(
        key: const ValueKey('run-project'),
        onPressed: _canRun(project, draft)
            ? () => _start(project, draft)
            : null,
        icon: const Icon(Icons.play_arrow_rounded, size: 20),
        label: const Text('启动会话'),
      ),
      const SizedBox(width: 8),
      OutlinedButton.icon(
        key: const ValueKey('build-project'),
        onPressed: _busy == null && !_closing
            ? () => showDialog<void>(
                context: context,
                builder: (_) => BuildDialog(
                  bridge: widget.bridge,
                  project: project,
                  startBuild: _startBackgroundBuild,
                  sdkPreference: draft.sdkPath.text.trim().isEmpty
                      ? null
                      : draft.sdkPath.text.trim(),
                ),
              )
            : null,
        icon: const Icon(Icons.inventory_2_outlined, size: 18),
        label: const Text('构建'),
      ),
      IconButton(
        key: const ValueKey('test-project'),
        tooltip: '运行项目测试',
        onPressed: _closing ? null : () => _openTests(project, draft),
        icon: const Icon(Icons.science_outlined, size: 19),
      ),
    ],
  );

  Widget _sessionActions(Session session, {required bool compact}) {
    final idle = !_closing && _busy == null && session.operation == null;
    final canPause =
        idle &&
        session.mode == 'debug' &&
        session.capabilities['debugger'] == true &&
        const ['running', 'paused'].contains(session.state);
    return Row(
      key: const ValueKey('session-actions'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _actionIcon(
          'session-pause',
          session.state == 'paused' ? '继续' : '暂停',
          session.state == 'paused' ? Icons.play_arrow : Icons.pause_rounded,
          canPause ? () => _pause(session) : null,
          compact: compact,
        ),
        _actionIcon(
          'session-restart',
          '热重启',
          Icons.restart_alt,
          idle &&
                  session.canReload &&
                  session.capabilities['supportsHotRestart'] == true
              ? () => _perform('热重启', () => widget.bridge.restart(session.id))
              : null,
          compact: compact,
        ),
        _actionIcon(
          'session-reload',
          '热重载',
          Icons.refresh_rounded,
          idle &&
                  session.canReload &&
                  session.capabilities['supportsHotReload'] == true
              ? () => _perform('热重载', () => widget.bridge.reload(session.id))
              : null,
          compact: compact,
          accent: true,
        ),
        _actionIcon(
          'session-stop',
          '停止',
          Icons.stop_rounded,
          _busy == null && session.canStop
              ? () => _perform(
                  '停止会话',
                  () => widget.bridge.stopSession(session.id),
                )
              : null,
          compact: compact,
        ),
      ],
    );
  }

  Widget _actionIcon(
    String key,
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    required bool compact,
    bool accent = false,
  }) => Padding(
    padding: EdgeInsets.only(left: compact ? 2 : 8),
    child: IconButton(
      key: ValueKey(key),
      tooltip: label,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        foregroundColor: accent ? _colors.primary : _colors.onSurfaceVariant,
        side: BorderSide(
          color: accent && onPressed != null
              ? _colors.primary.withValues(alpha: 0.5)
              : _colors.outlineVariant,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
      icon: compact
          ? Icon(icon, size: 19)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 19),
                const SizedBox(width: 7),
                Text(label, style: const TextStyle(fontSize: 13)),
              ],
            ),
      padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 13, vertical: 10),
      constraints: BoxConstraints.tightFor(
        width: compact ? 32 : 98,
        height: 38,
      ),
    ),
  );

  Widget _workspaceErrorBanner() => Material(
    key: const ValueKey('workspace-persistence-error'),
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(_workspaceError!, style: const TextStyle(fontSize: 12)),
          ),
          TextButton(
            key: ValueKey(
              _workspaceLoaded
                  ? 'workspace-projects-retry-save'
                  : 'workspace-projects-retry-load',
            ),
            onPressed: _workspaceReading || _workspaceSaving
                ? null
                : _retryWorkspace,
            child: Text(
              _workspaceReading || _workspaceSaving
                  ? '处理中…'
                  : _workspaceLoaded
                  ? '重试保存'
                  : '重试读取',
            ),
          ),
        ],
      ),
    ),
  );

  Widget _errorBanner() => Material(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_error!, style: const TextStyle(fontSize: 12)),
                if (_errorProject != null)
                  TextButton(
                    onPressed: () => _selectProject(_errorProject!),
                    child: const Text('调整启动配置'),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _error = null),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    ),
  );

  String _sdkSourceLabel(String source) => switch (source) {
    'global' => '全局默认 SDK',
    'globalFallback' => '全局默认 SDK（自动回退）',
    'explicit' => '项目指定 SDK',
    'fvm' => 'FVM 项目 SDK',
    'auto' => '环境自动发现',
    'vscode' => '项目设置 SDK',
    _ => source,
  };

  Widget _configuration() {
    final project = _project;
    final draft = _draft;
    if (project == null || draft == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.layers_outlined, size: 46, color: _colors.outline),
              const SizedBox(height: 20),
              const Text(
                '开始新的工作',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Text(
                '从左侧新增或选择一个项目\n配置设备后启动会话',
                textAlign: TextAlign.center,
                style: TextStyle(color: _colors.onSurfaceVariant, height: 1.8),
              ),
            ],
          ),
        ),
      );
    }
    final platforms = <String>{
      ...project.platforms,
      ...draft.devices.map(_platformOf),
    }.toList();
    final devices = draft.devices
        .where((d) => _compatible(project, draft, d))
        .toList();
    Widget field(
      String key,
      TextEditingController controller,
      String label, {
      int lines = 1,
      String? hint,
      ValueChanged<String>? onChanged,
    }) => TextField(
      key: ValueKey(key),
      controller: controller,
      onChanged: onChanged,
      maxLines: lines,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
    return SingleChildScrollView(
      key: const ValueKey('project-config'),
      padding: const EdgeInsets.fromLTRB(28, 6, 28, 32),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                project.path,
                style: TextStyle(fontSize: 12, color: _colors.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              RunProfileControls(
                profiles: _preferences.runProfiles
                    .where((p) => p.projectPath == project.path)
                    .toList(),
                selectedId: draft.selectedProfileId,
                enabled: _workspaceLoaded && !_closing && _busy == null,
                onSelected: (id) => _selectProfile(project, draft, id),
                onSaveAs: () => _manageProfile(project, draft, 'save-as'),
                onAction: (action) => _manageProfile(project, draft, action),
                autoReload: draft.autoReload,
                onAutoReload: (value) {
                  setState(() => draft.autoReload = value);
                  _draftChanged(draft);
                },
              ),
              const SizedBox(height: 12),
              if (draft.git != null && draft.git!.headCommit == null) ...[
                Text(
                  '仓库尚无提交，创建首次提交后可切换分支。',
                  style: TextStyle(
                    fontSize: 12,
                    color: _colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (draft.gitError case final error?) ...[
                Text(
                  error,
                  key: ValueKey('git-error-${project.path}'),
                  style: TextStyle(fontSize: 12, color: _colors.error),
                ),
                const SizedBox(height: 12),
              ],
              _configSection('运行目标', '选择平台、设备与运行模式。', [
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        key: ValueKey(
                          'platform-field-${project.path}-${draft.platform}',
                        ),
                        child: WorkbenchSelect<String>(
                          key: const ValueKey('platform-select'),
                          label: '平台',
                          value: draft.platform ?? '',
                          options: [
                            const WorkbenchOption(
                              value: '',
                              label: '全部平台',
                              icon: Icons.apps_outlined,
                            ),
                            ...platforms.map(
                              (p) => WorkbenchOption(
                                value: p,
                                label: p,
                                icon: _platformIcon(p),
                              ),
                            ),
                          ],
                          onChanged: (p) => setState(() {
                            draft.platform = p == '' ? null : p;
                            _pickAvailableDevice(project, draft);
                            _draftChanged(draft);
                          }),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: SizedBox(
                        key: ValueKey('mode-field-${project.path}'),
                        child: WorkbenchSelect<String>(
                          key: const ValueKey('mode-select'),
                          label: '运行模式',
                          value: draft.mode,
                          options: const [
                            WorkbenchOption(
                              value: 'debug',
                              label: 'debug',
                              detail: '断点与热重载',
                              icon: Icons.bug_report_outlined,
                            ),
                            WorkbenchOption(
                              value: 'profile',
                              label: 'profile',
                              detail: '性能分析',
                              icon: Icons.speed_outlined,
                            ),
                            WorkbenchOption(
                              value: 'release',
                              label: 'release',
                              detail: '发布模式',
                              icon: Icons.rocket_launch_outlined,
                            ),
                          ],
                          onChanged: (mode) => setState(() {
                            draft.mode = mode;
                            _draftChanged(draft);
                          }),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _deviceControls(project, draft, devices),
                const SizedBox(height: 20),
                field('entrypoint', draft.entrypoint, '入口（相对应用包）'),
              ]),
              const SizedBox(height: 20),
              Material(
                color: _colors.surfaceContainer,
                borderRadius: BorderRadius.circular(11),
                child: InkWell(
                  key: const ValueKey('advanced-settings'),
                  borderRadius: BorderRadius.circular(11),
                  onTap: () => setState(
                    () => draft.advancedExpanded = !draft.advancedExpanded,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          draft.advancedExpanded
                              ? Icons.expand_more
                              : Icons.chevron_right,
                          size: 20,
                          color: _colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            '高级设置',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (draft.advancedExpanded) ...[
                const SizedBox(height: 16),
                _configSection('Flutter SDK', '自动发现项目 SDK，异常时使用全局默认配置。', [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 480;
                      return Row(
                        children: [
                          Expanded(
                            child: field(
                              'sdk-path',
                              draft.sdkPath,
                              '项目 SDK 路径（可选，自动发现）',
                              onChanged: (_) => setState(() {
                                draft.sdkRequest++;
                                draft.sdk = null;
                                draft.devices = [];
                                draft.emulators = [];
                                draft.deviceId = null;
                              }),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Tooltip(
                            message: '检查 SDK',
                            child: OutlinedButton(
                              key: const ValueKey('resolve-sdk'),
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.standard,
                                minimumSize: const Size(42, 46),
                                padding: EdgeInsets.symmetric(
                                  horizontal: compact ? 12 : 14,
                                ),
                              ),
                              onPressed: _busy == null
                                  ? () => _perform(
                                      '解析 SDK',
                                      () => _resolveSdk(project, draft),
                                    )
                                  : null,
                              child: compact
                                  ? const Icon(Icons.search, size: 19)
                                  : const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.search, size: 18),
                                        SizedBox(width: 6),
                                        Text('检查 SDK'),
                                      ],
                                    ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  if (draft.sdk != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Flutter ${draft.sdk!.flutterVersion} · ${_sdkSourceLabel(draft.sdk!.source)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: _colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      draft.sdk!.path,
                      style: TextStyle(
                        fontSize: 11,
                        color: _colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (draft.sdk?.fallbackReason case final reason?)
                    Padding(
                      key: const ValueKey('sdk-fallback-notice'),
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        '项目 SDK 异常，已自动使用全局默认 SDK。\n$reason',
                        style: TextStyle(
                          fontSize: 12,
                          color: _colors.onSurfaceVariant,
                          height: 1.6,
                        ),
                      ),
                    ),
                ]),
                const SizedBox(height: 20),
                _configSection('启动选项', '为当前项目配置参数和运行环境。', [
                  field('flavor', draft.flavor, 'Flavor（可选）'),
                  const SizedBox(height: 16),
                  field(
                    'dart-defines',
                    draft.defines,
                    'dart-define（每行 KEY=VALUE）',
                    lines: 3,
                  ),
                  const SizedBox(height: 16),
                  field(
                    'environment',
                    draft.environment,
                    '环境变量（每行 KEY=VALUE）',
                    lines: 3,
                  ),
                  const SizedBox(height: 16),
                  field(
                    'tool-args',
                    draft.toolArgs,
                    '工具参数（JSON 数组）',
                    lines: 2,
                    hint: '["--verbose"]',
                  ),
                  const SizedBox(height: 16),
                  field(
                    'attach-uri',
                    draft.attachUri,
                    '附加已有应用 · VM Service URI',
                  ),
                  SwitchListTile(
                    key: const ValueKey('no-debug'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('运行而不调试'),
                    value: draft.noDebug,
                    onChanged: (v) => setState(() {
                      draft.noDebug = v;
                      _draftChanged(draft);
                    }),
                  ),
                ]),
              ],
              const SizedBox(height: 20),
              Text(
                '左侧项目的运行按钮会复用上一次提交的启动配置。',
                style: TextStyle(fontSize: 11, color: _colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gitControls(Project project, _ProjectDraft draft) {
    final git = draft.git;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: git == null
                ? Text(
                    draft.gitLoading ? '正在识别 Git 仓库…' : 'Git 分支读取失败',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: _colors.onSurfaceVariant,
                    ),
                  )
                : WorkbenchSelect<String>(
                    key: ValueKey('git-branch-select-${project.path}'),
                    compact: true,
                    label: '当前分支',
                    value: git.currentBranch,
                    hint: git.label,
                    options: [
                      for (final branch in git.branches)
                        WorkbenchOption(
                          value: branch,
                          label: branch,
                          icon: Icons.account_tree_outlined,
                        ),
                    ],
                    onChanged: _busy == null && !draft.gitLoading
                        ? (branch) => _switchBranch(project, branch)
                        : null,
                  ),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: ValueKey('git-refresh-${project.path}'),
            tooltip: '刷新 Git 分支',
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onPressed: _busy == null && !draft.gitLoading
                ? () => _refreshGit(project)
                : null,
            icon: draft.gitLoading
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Icon(Icons.refresh, size: 15),
          ),
        ],
      ),
    );
  }

  bool _canRun(Project project, _ProjectDraft draft) =>
      !_closing &&
      _busy == null &&
      draft.sdk != null &&
      draft.devices.any(
        (device) =>
            _compatible(project, draft, device) &&
            device.id == draft.deviceId &&
            device.available,
      );

  IconData _platformIcon(String platform) => switch (platform.toLowerCase()) {
    'ios' => Icons.phone_iphone_outlined,
    'android' => Icons.android_outlined,
    'web' => Icons.language_outlined,
    'macos' => Icons.desktop_mac_outlined,
    'windows' => Icons.desktop_windows_outlined,
    'linux' => Icons.computer_outlined,
    _ => Icons.devices_outlined,
  };

  Widget _deviceControls(
    Project project,
    _ProjectDraft draft,
    List<Device> devices,
  ) => LayoutBuilder(
    key: const ValueKey('device-controls'),
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 620;
      final compact = constraints.maxWidth < 260;
      final enabled = draft.sdk != null && _busy == null;
      final emulatorEnabled = enabled && draft.emulators.isNotEmpty;
      final device = SizedBox(
        key: ValueKey('device-field-${project.path}-${draft.deviceId}'),
        child: WorkbenchSelect<String>(
          key: const ValueKey('device-select'),
          label: '设备',
          value: draft.deviceId,
          menuWidth: 360,
          options: devices
              .map(
                (d) => WorkbenchOption(
                  value: d.id,
                  label:
                      '${d.name} · ${d.platform}${d.available ? '' : '（不可用）'}',
                  detail: d.isEmulator ? '模拟器' : null,
                  icon: _platformIcon(_platformOf(d)),
                  enabled: d.available,
                ),
              )
              .toList(),
          onChanged: (id) => setState(() {
            draft.deviceId = id;
            _draftChanged(draft);
          }),
        ),
      );
      final actions = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: '刷新设备',
            child: OutlinedButton(
              key: const ValueKey('refresh-devices'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.standard,
                minimumSize: const Size(42, 46),
                padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 14),
              ),
              onPressed: enabled
                  ? () =>
                        _perform('刷新设备', () => _refreshDevices(project, draft))
                  : null,
              child: compact
                  ? const Icon(Icons.refresh, size: 18)
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh, size: 18),
                        SizedBox(width: 6),
                        Text('刷新设备'),
                      ],
                    ),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<Emulator>(
            key: const ValueKey('launch-emulator'),
            tooltip: '启动模拟器',
            enabled: emulatorEnabled,
            position: PopupMenuPosition.under,
            offset: const Offset(0, 8),
            menuPadding: const EdgeInsets.all(6),
            itemBuilder: (_) => draft.emulators
                .map(
                  (e) => PopupMenuItem(
                    value: e,
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('${e.name} · ${e.platform}'),
                  ),
                )
                .toList(),
            onSelected: (emulator) {
              final sdk = draft.sdk;
              if (sdk == null || _busy != null) return;
              _perform('启动模拟器', () async {
                await widget.bridge.launchEmulator(sdk.path, emulator.id);
                await _refreshDevices(project, draft);
              });
            },
            child: Container(
              constraints: const BoxConstraints(minHeight: 46),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: emulatorEnabled
                      ? _colors.outline
                      : _colors.outlineVariant,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.devices_outlined,
                    size: 18,
                    color: emulatorEnabled
                        ? _colors.onSurfaceVariant
                        : _colors.onSurface.withValues(alpha: 0.38),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '启动模拟器',
                    style: TextStyle(
                      fontSize: 13,
                      color: emulatorEnabled
                          ? _colors.onSurfaceVariant
                          : _colors.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
      if (wide) {
        return Row(
          children: [
            Expanded(child: device),
            const SizedBox(width: 12),
            actions,
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [device, const SizedBox(height: 10), actions],
      );
    },
  );

  Widget _configSection(
    String title,
    String description,
    List<Widget> children,
  ) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: _colors.surfaceContainer,
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: _colors.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 5),
        Text(
          description,
          style: TextStyle(
            fontSize: 12,
            color: _colors.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        ...children,
      ],
    ),
  );

  Widget _tabs() => Container(
    width: double.infinity,
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: _colors.outlineVariant)),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          for (final entry in const ['日志', '源码与调试', 'DevTools', '测试'].indexed)
            InkWell(
              onTap: () => setState(() => _tab = entry.$1),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 13, 12, 14),
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      width: 2,
                      color: _tab == entry.$1
                          ? _colors.primary
                          : Colors.transparent,
                    ),
                  ),
                ),
                child: Text(
                  entry.$2,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: _tab == entry.$1
                        ? FontWeight.w500
                        : FontWeight.w400,
                    color: _tab == entry.$1
                        ? _colors.primary
                        : _colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _panel(Session session) {
    if (_tab == 0) {
      return LogPanel(
        key: ValueKey('logs-${session.id}-${session.generation}'),
        searchFocus: _searchFocus,
        bridge: widget.bridge,
        session: session,
      );
    }
    if (_tab == 1) {
      return DebuggerPanel(
        key: ValueKey('debugger-${session.id}-${session.generation}'),
        bridge: widget.bridge,
        session: session,
      );
    }
    if (_tab == 2) {
      return DevToolsPanel(
        key: ValueKey('devtools-${session.id}-${session.generation}'),
        searchFocus: _searchFocus,
        bridge: widget.bridge,
        session: session,
      );
    }
    final project = _projects
        .where((p) => p.path == session.projectPath)
        .firstOrNull;
    if (project == null) return const Center(child: Text('请先选择项目'));
    return TestPanel(
      key: ValueKey('tests-${project.path}'),
      bridge: widget.bridge,
      project: project,
      sdkPreference: _drafts[project.path]?.sdkPath.text.trim(),
    );
  }

  Widget _status() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
    decoration: BoxDecoration(
      color: _colors.surface,
      border: Border(top: BorderSide(color: _colors.outlineVariant)),
    ),
    child: Row(
      children: [
        Icon(Icons.circle, size: 7, color: _colors.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _draft?.sdk == null
                ? '尚未解析项目 SDK'
                : 'Flutter ${_draft!.sdk!.flutterVersion} · ${_draft!.sdk!.path}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: _colors.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          key: const ValueKey('workbench-shortcuts'),
          tooltip: '快捷键',
          onPressed: _showShortcuts,
          icon: const Icon(Icons.keyboard_outlined, size: 18),
          constraints: const BoxConstraints.tightFor(width: 28, height: 24),
          padding: EdgeInsets.zero,
        ),
        ValueListenableBuilder<Session?>(
          valueListenable: _selected,
          builder: (context, session, _) => Text(
            _busy ?? (session == null ? '就绪' : stateLabel(session.state)),
            style: TextStyle(fontSize: 11, color: _colors.onSurfaceVariant),
          ),
        ),
      ],
    ),
  );
}

class _AddProjectDialog extends StatefulWidget {
  const _AddProjectDialog({required this.bridge});
  final WorkbenchBridge bridge;
  @override
  State<_AddProjectDialog> createState() => _AddProjectDialogState();
}

class _AddProjectDialogState extends State<_AddProjectDialog> {
  ColorScheme get _colors => Theme.of(context).colorScheme;
  final _path = TextEditingController();
  List<Project> _projects = [];
  final _checked = <String>{};
  String? _error;
  String? _discoveredRoot;
  bool _busy = false;
  Future<void> _discover() async {
    final root = _path.text.trim();
    setState(() {
      _busy = true;
      _error = null;
      _projects = [];
      _checked.clear();
      _discoveredRoot = null;
    });
    try {
      if (root.isEmpty) throw const FormatException('请输入项目或仓库路径');
      final projects = await widget.bridge.discoverProjects(root);
      if (projects.isEmpty) {
        throw const FormatException('未找到 Flutter 应用包，请选择包含 pubspec.yaml 的目录');
      }
      if (!mounted || root != _path.text.trim()) return;
      setState(() {
        _projects = projects;
        _checked.addAll(projects.map((p) => p.path));
        _discoveredRoot = root;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新增项目'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '选择 Flutter 项目或包含多个应用包的仓库目录。',
              style: TextStyle(fontSize: 13, color: _colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('add-project-path'),
              controller: _path,
              enabled: !_busy,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _discover(),
              decoration: InputDecoration(
                labelText: '项目 / 仓库路径',
                suffixIcon: IconButton(
                  tooltip: '选择目录',
                  onPressed: _busy
                      ? null
                      : () async {
                          final path = await getDirectoryPath();
                          if (!mounted || path == null) return;
                          _path.text = path;
                          await _discover();
                        },
                  icon: const Icon(Icons.folder_open),
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('add-project-discover'),
              onPressed: _busy ? null : _discover,
              icon: const Icon(Icons.search, size: 18),
              label: Text(_busy ? '识别中…' : '识别项目'),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: TextStyle(color: _colors.error)),
              ),
            if (_projects.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '选择要添加的应用包',
                style: TextStyle(fontSize: 12, color: _colors.onSurfaceVariant),
              ),
              for (final project in _projects)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _checked.contains(project.path),
                  title: Text(project.name),
                  subtitle: Text(
                    project.path,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onChanged: _busy
                      ? null
                      : (checked) => setState(() {
                          checked == true
                              ? _checked.add(project.path)
                              : _checked.remove(project.path);
                        }),
                ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('add-project-confirm'),
        onPressed:
            !_busy &&
                _checked.isNotEmpty &&
                _discoveredRoot == _path.text.trim()
            ? () => Navigator.pop(
                context,
                _projects.where((p) => _checked.contains(p.path)).toList(),
              )
            : null,
        child: const Text('添加项目'),
      ),
    ],
  );
}

String stateLabel(String state) =>
    const {
      'preparing': '准备中',
      'starting': '启动中',
      'running': '运行中',
      'paused': '已暂停',
      'stopping': '停止中',
      'ended': '已结束',
      'failed': '失败',
    }[state] ??
    state;
