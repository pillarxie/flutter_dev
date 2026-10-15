import 'dart:async';
import 'dart:convert';

import '../presentation/workbench_models.dart';
import 'generated/api/core.dart' as api;
import 'generated/build.dart' as build;
import 'generated/frb_generated.dart';
import 'generated/project.dart' as native_project;
import 'generated/session.dart' as native;
import 'generated/settings.dart' as settings;

/// Converts native snapshots into the visible workbench projection.
/// Processes, session transitions and all protocol requests remain owned by Rust.
class NativeWorkbenchBridge extends WorkbenchBridge {
  NativeWorkbenchBridge._();

  static Future<NativeWorkbenchBridge> initialize() async {
    await RustLib.init();
    return NativeWorkbenchBridge._();
  }

  late final Stream<WorkbenchEvent> _events = api
      .subscribeEvents()
      .map(_event)
      .asBroadcastStream(
        onCancel: (subscription) {
          unawaited(subscription.cancel());
          unawaited(api.cancelEventSubscription());
        },
      );

  @override
  Stream<WorkbenchEvent> get events => _events;

  WorkbenchEvent _event(native.CoreEvent event) {
    final kind = switch (event.kind) {
      native.CoreEventKind.outputAvailable => 'logs',
      native.CoreEventKind.devicesChanged => 'devices',
      _ => 'session',
    };
    Session? session;
    if (event.kind == native.CoreEventKind.state ||
        event.kind == native.CoreEventKind.serviceUri) {
      session = _fromJson(jsonDecode(event.payload) as Map<String, dynamic>);
    }
    return WorkbenchEvent(
      kind: kind,
      sessionId: event.sessionId.isEmpty ? null : event.sessionId,
      generation: event.generation,
      sequence: event.sequence,
      session: session,
    );
  }

  Session _snapshot(native.SessionSnapshot value) => _fromJson({
    'session_id': value.sessionId,
    'generation': value.generation,
    'sequence': value.sequence,
    'state': value.state.name,
    'project_path': value.projectPath,
    'device_id': value.deviceId,
    'mode': value.mode.name,
    'no_debug': value.noDebug,
    'operation': value.operation,
    'service_uri': value.serviceUri,
    'error': value.error,
    'capabilities_json': value.capabilitiesJson,
  });

  Session _fromJson(Map<String, dynamic> value) {
    final mode = (value['mode'] as String).toLowerCase();
    final state = (value['state'] as String).toLowerCase();
    final capabilities =
        jsonDecode(value['capabilities_json'] as String)
            as Map<String, dynamic>;
    final activeDebug =
        mode == 'debug' &&
        value['no_debug'] != true &&
        const ['starting', 'running', 'paused'].contains(state);
    return Session(
      id: value['session_id'] as String,
      generation: value['generation'] as int,
      sequence: value['sequence'] as int,
      state: state,
      projectPath: value['project_path'] as String,
      deviceId: value['device_id'] as String,
      mode: mode,
      operation: value['operation'] as String?,
      serviceUri: value['service_uri'] as String?,
      error: value['error'] as String?,
      capabilities: {
        for (final entry in capabilities.entries)
          if (entry.value is bool) entry.key: entry.value as bool,
        'debugger': activeDebug,
        // Flutter's SDK adapter defines these extensions; they are mode-specific.
        'supportsHotReload': mode == 'debug',
        'supportsHotRestart': mode == 'debug',
      },
    );
  }

  @override
  Future<List<Project>> discoverProjects(String root) async => [
    for (final value in await api.discoverProjects(root: root)) _project(value),
  ];

  Project _project(native_project.ProjectInfo value) => Project(
    name: value.name,
    path: value.path,
    entrypoint: value.entrypoint,
    platforms: value.platforms,
  );

  @override
  Future<Sdk> resolveSdk(String projectPath, String? explicitPath) async {
    final value = await api.resolveSdk(
      projectPath: projectPath,
      explicitPath: explicitPath,
    );
    return Sdk(
      path: value.path,
      flutterVersion: value.flutterVersion,
      dartVersion: value.dartVersion,
      source: value.source,
      fallbackReason: value.fallbackReason,
    );
  }

  @override
  Future<AppSettings> getAppSettings() async {
    return _appSettings(await api.getAppSettings());
  }

  @override
  Future<AppSettings> setDefaultSdk(String? path) async {
    return _appSettings(await api.setDefaultSdk(path: path));
  }

  @override
  Future<AppSettings> setThemeMode(String mode) async {
    return _appSettings(await api.setThemeMode(mode: mode));
  }

  AppSettings _appSettings(settings.AppSettings value) => AppSettings(
    defaultSdkPath: value.defaultSdkPath,
    themeMode: value.themeMode,
    projects: [for (final project in value.projects) _project(project)],
    selectedProjectPath: value.selectedProjectPath,
    buildPresets: [
      for (final preset in value.buildPresets)
        BuildPreset(
          id: preset.id,
          name: preset.name,
          target: preset.target,
          args: preset.args,
          outputDirectory: preset.outputDirectory,
        ),
    ],
  );

  @override
  Future<AppSettings> setWorkspaceProjects(
    List<Project> projects,
    String? selectedProjectPath,
  ) async => _appSettings(
    await api.setWorkspaceProjects(
      projects: [
        for (final project in projects)
          native_project.ProjectInfo(
            name: project.name,
            path: project.path,
            entrypoint: project.entrypoint,
            platforms: project.platforms,
          ),
      ],
      selectedProjectPath: selectedProjectPath,
    ),
  );

  @override
  Future<AppSettings> setBuildPresets(List<BuildPreset> presets) async =>
      _appSettings(
        await api.setBuildPresets(
          presets: [
            for (final preset in presets)
              build.BuildPreset(
                id: preset.id,
                name: preset.name,
                target: preset.target,
                args: preset.args,
                outputDirectory: preset.outputDirectory,
              ),
          ],
        ),
      );

  BuildSnapshot _buildSnapshot(build.BuildSnapshot value) => BuildSnapshot(
    id: value.id,
    projectPath: value.projectPath,
    state: value.state,
    target: value.target,
    outputDirectory: value.outputDirectory,
    error: value.error,
    exitCode: value.exitCode,
  );

  @override
  Future<BuildSnapshot> startBuild(BuildConfig config) async => _buildSnapshot(
    await api.startBuild(
      config: build.BuildConfiguration(
        projectPath: config.projectPath,
        sdkPath: config.sdkPath,
        target: config.target,
        args: config.args,
        outputDirectory: config.outputDirectory,
      ),
    ),
  );

  @override
  Future<BuildSnapshot> buildSnapshot(String id) async =>
      _buildSnapshot(await api.buildSnapshot(buildId: id));

  @override
  Future<LogPage> readBuildLogs(
    String id, {
    int afterId = 0,
    int limit = 200,
  }) async {
    final page = await api.readBuildLogs(
      buildId: id,
      afterId: afterId,
      limit: limit,
    );
    return LogPage(
      entries: [
        for (final entry in page.entries)
          LogEntry(id: entry.id, category: entry.category, text: entry.text),
      ],
      nextAfterId: page.nextAfterId ?? afterId,
      droppedBeforeId: page.droppedBeforeId ?? 0,
    );
  }

  @override
  Future<void> stopBuild(String id) => api.stopBuild(buildId: id);

  @override
  Future<void> openBuildOutput(String id) => api.openBuildOutput(buildId: id);

  @override
  Future<List<Device>> listDevices(String sdkPath) async => [
    for (final value in await api.listDevices(sdkPath: sdkPath))
      Device(
        id: value.id,
        name: value.name,
        platform: value.platformType ?? value.platform,
        isEmulator: value.emulator,
      ),
  ];

  @override
  Future<List<Emulator>> listEmulators(String sdkPath) async => [
    for (final value in await api.listEmulators(sdkPath: sdkPath))
      Emulator(
        id: value.id,
        name: value.name,
        platform: value.platformType ?? 'unknown',
      ),
  ];

  @override
  Future<void> launchEmulator(String sdkPath, String emulatorId) async {
    await api.launchEmulator(sdkPath: sdkPath, emulatorId: emulatorId);
  }

  @override
  Future<Session> startSession(RunConfig config) async => _snapshot(
    await api.startSession(
      config: native.RunConfiguration(
        projectPath: config.projectPath,
        sdkPath: config.sdkPreference ?? config.sdkPath,
        program: config.entrypoint,
        deviceId: config.deviceId,
        mode: native.RunMode.values.byName(config.mode),
        noDebug: config.noDebug,
        attachUri: config.attachUri,
        env: [
          for (final entry in config.env.entries)
            native.EnvVar(name: entry.key, value: entry.value),
        ],
        toolArgs: config.toolArgs,
        args: const [],
        flavor: config.flavor,
        dartDefines: config.dartDefines,
      ),
    ),
  );

  @override
  Future<void> stopSession(String id) => api.stopSession(sessionId: id);
  @override
  Future<void> reload(String id) => api.hotReload(sessionId: id);
  @override
  Future<void> restart(String id) => api.hotRestart(sessionId: id);
  @override
  Future<List<Session>> listSessions() async =>
      (await api.sessionSnapshots()).map(_snapshot).toList();

  @override
  Future<LogPage> readLogs(
    String id, {
    int afterId = 0,
    int limit = 200,
    String query = '',
  }) async {
    final page = await api.readLogs(
      sessionId: id,
      afterId: afterId,
      limit: limit,
      query: query,
    );
    return LogPage(
      entries: [
        for (final entry in page.entries)
          LogEntry(id: entry.id, category: entry.category, text: entry.text),
      ],
      nextAfterId: page.nextAfterId ?? afterId,
      droppedBeforeId: page.droppedBeforeId ?? 0,
    );
  }

  @override
  Future<String> openDevTools(String sessionId, String module) async =>
      (await api.openDevtools(sessionId: sessionId, module: module)).url;

  @override
  Future<void> closeDevTools(String sessionId) =>
      api.closeDevtools(sessionId: sessionId);

  @override
  Future<Map<String, dynamic>> networkRequest(
    String id,
    String method,
    Map<String, dynamic> args,
  ) async {
    final response = await api.networkRequest(
      sessionId: id,
      method: method,
      paramsJson: jsonEncode(args),
    );
    return jsonDecode(response.json) as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> debuggerRequest(
    String id,
    String command,
    Map<String, dynamic> args,
  ) async {
    final native.JsonResponse response;
    switch (command) {
      case 'threads':
        response = await api.threads(sessionId: id);
      case 'pause':
      case 'continue':
      case 'next':
      case 'stepIn':
      case 'stepOut':
        response = await api.debugAction(
          sessionId: id,
          action: command == 'continue'
              ? native.DebugAction.continue_
              : native.DebugAction.values.byName(command),
          threadId: args['threadId'] as int,
        );
      case 'setBreakpoints':
        final source = args['source'] as Map<String, dynamic>;
        response = await api.setBreakpoints(
          sessionId: id,
          path: source['path'] as String,
          breakpoints: [
            for (final item in args['breakpoints'] as List<dynamic>)
              native.SourceBreakpoint(
                line: item['line'] as int,
                condition: item['condition'] as String?,
                hitCondition: item['hitCondition'] as String?,
                logMessage: item['logMessage'] as String?,
              ),
          ],
        );
      case 'stackTrace':
        response = await api.stackTrace(
          sessionId: id,
          threadId: args['threadId'] as int,
          startFrame: args['startFrame'] as int? ?? 0,
          levels: args['levels'] as int? ?? 100,
        );
      case 'scopes':
        response = await api.scopes(
          sessionId: id,
          frameId: args['frameId'] as int,
        );
      case 'variables':
        response = await api.variables(
          sessionId: id,
          variablesReference: args['variablesReference'] as int,
          start: args['start'] as int? ?? 0,
          count: args['count'] as int? ?? 100,
        );
      case 'evaluate':
        response = await api.evaluate(
          sessionId: id,
          expression: args['expression'] as String,
          frameId: args['frameId'] as int?,
        );
      default:
        throw UnsupportedError('Unsupported debugger command: $command');
    }
    final decoded = jsonDecode(response.json);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  @override
  Future<String> readSource(String path) async {
    final page = await api.readSource(path: path, startLine: 1, limit: 2000);
    if (page.totalLines > page.lines.length) {
      throw StateError('文件超过首版源码视图的 2000 行上限；请使用外部编辑器查看。');
    }
    return page.lines.join('\n');
  }

  @override
  Future<void> shutdown() => api.shutdownCore();
}
