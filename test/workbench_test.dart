import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/app.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';

class FakeBridge implements WorkbenchBridge {
  final controller = StreamController<WorkbenchEvent>.broadcast(sync: true);
  List<Session> sessions = [];
  List<LogEntry> logs = [];
  int logReads = 0, starts = 0;
  List<Project> Function(String root)? discoverResponse;
  final discoveredRoots = <String>[];
  Future<Sdk> Function(String projectPath, String? explicitPath)? sdkResponse;
  AppSettings appSettings = const AppSettings();
  Future<AppSettings>? initialSettings;
  Future<AppSettings> Function(String? path)? settingsResponse;
  final savedSdkPaths = <String?>[];
  final savedThemeModes = <String>[];
  Future<AppSettings> Function(String mode)? themeResponse;
  Future<AppSettings> Function(List<Project> projects, String? selectedPath)?
  workspaceResponse;
  final workspaceSaves = <({List<Project> projects, String? selectedPath})>[];
  int shutdowns = 0;
  final sdkRequests = <({String projectPath, String? explicitPath})>[];
  List<Device> devices = const [
    Device(id: 'macos', name: 'Mac', platform: 'darwin'),
  ];
  List<Emulator> emulators = const [];
  final deviceRequests = <String>[];
  final emulatorRequests = <String>[];
  final launchedEmulators = <({String sdkPath, String emulatorId})>[];
  Future<void> Function(String sdkPath, String emulatorId)?
  emulatorLaunchResponse;
  final startedConfigs = <RunConfig>[];
  final reloads = <String>[];
  final restarts = <String>[];
  final stops = <String>[];
  final debugRequests =
      <({String id, String command, Map<String, dynamic> args})>[];
  Future<Map<String, dynamic>> Function(String, String, Map<String, dynamic>)?
  debugResponse;
  Future<Map<String, dynamic>> Function(String, String, Map<String, dynamic>)?
  networkResponse;
  final networkRequests =
      <({String id, String method, Map<String, dynamic> args})>[];
  final openedDevTools = <({String sessionId, String module})>[];
  final closedDevTools = <String>[];
  Future<String> Function(String sessionId, String module)? devToolsResponse;
  Future<void> Function(String sessionId)? closeDevToolsResponse;
  bool failStart = false;
  Future<Session> Function()? startResponse;
  Future<List<Session>>? initialSessions;
  Completer<LogPage>? firstLogResponse;
  RunConfig? lastConfig;
  @override
  Stream<WorkbenchEvent> get events => controller.stream;
  @override
  Future<AppSettings> getAppSettings() async => initialSettings ?? appSettings;
  @override
  Future<AppSettings> setWorkspaceProjects(
    List<Project> projects,
    String? selectedProjectPath,
  ) async {
    final snapshot = List<Project>.of(projects);
    workspaceSaves.add((projects: snapshot, selectedPath: selectedProjectPath));
    if (workspaceResponse != null) {
      appSettings = await workspaceResponse!(snapshot, selectedProjectPath);
    } else {
      appSettings = AppSettings(
        defaultSdkPath: appSettings.defaultSdkPath,
        themeMode: appSettings.themeMode,
        buildPresets: appSettings.buildPresets,
        projects: snapshot,
        selectedProjectPath: selectedProjectPath,
      );
    }
    return appSettings;
  }

  @override
  Future<AppSettings> setBuildPresets(List<BuildPreset> presets) async {
    appSettings = AppSettings(
      defaultSdkPath: appSettings.defaultSdkPath,
      themeMode: appSettings.themeMode,
      buildPresets: presets,
      projects: appSettings.projects,
      selectedProjectPath: appSettings.selectedProjectPath,
    );
    return appSettings;
  }

  @override
  Future<BuildSnapshot> startBuild(BuildConfig config) async =>
      throw UnimplementedError();
  @override
  Future<BuildSnapshot> buildSnapshot(String id) async =>
      throw UnimplementedError();
  @override
  Future<LogPage> readBuildLogs(
    String id, {
    int afterId = 0,
    int limit = 200,
  }) async => throw UnimplementedError();
  @override
  Future<void> stopBuild(String id) async => throw UnimplementedError();
  @override
  Future<void> openBuildOutput(String id) async => throw UnimplementedError();
  @override
  Future<AppSettings> setDefaultSdk(String? path) async {
    savedSdkPaths.add(path);
    if (settingsResponse != null) {
      appSettings = await settingsResponse!(path);
    } else {
      if (path == '/invalid') throw Exception('SDK 路径无效');
      appSettings = AppSettings(
        defaultSdkPath: path,
        themeMode: appSettings.themeMode,
        buildPresets: appSettings.buildPresets,
        projects: appSettings.projects,
        selectedProjectPath: appSettings.selectedProjectPath,
      );
    }
    initialSettings = null;
    return appSettings;
  }

  @override
  Future<AppSettings> setThemeMode(String mode) async {
    savedThemeModes.add(mode);
    appSettings = themeResponse == null
        ? AppSettings(
            defaultSdkPath: appSettings.defaultSdkPath,
            themeMode: mode,
            buildPresets: appSettings.buildPresets,
            projects: appSettings.projects,
            selectedProjectPath: appSettings.selectedProjectPath,
          )
        : await themeResponse!(mode);
    return appSettings;
  }

  @override
  Future<List<Project>> discoverProjects(String root) async {
    discoveredRoots.add(root);
    return discoverResponse?.call(root) ??
        [
          Project(name: root.split('/').last, path: root, platforms: ['macos']),
        ];
  }

  @override
  Future<Sdk> resolveSdk(String projectPath, String? explicitPath) async {
    sdkRequests.add((projectPath: projectPath, explicitPath: explicitPath));
    if (sdkResponse != null) return sdkResponse!(projectPath, explicitPath);
    return Sdk(
      path: explicitPath ?? '/sdk',
      flutterVersion: '3.44',
      dartVersion: '3.12',
      source: 'test',
    );
  }

  @override
  Future<List<Device>> listDevices(String sdkPath) async {
    deviceRequests.add(sdkPath);
    return devices;
  }

  @override
  Future<List<Emulator>> listEmulators(String sdkPath) async {
    emulatorRequests.add(sdkPath);
    return emulators;
  }

  @override
  Future<void> launchEmulator(String sdkPath, String emulatorId) async {
    launchedEmulators.add((sdkPath: sdkPath, emulatorId: emulatorId));
    await emulatorLaunchResponse?.call(sdkPath, emulatorId);
  }

  @override
  Future<Session> startSession(RunConfig config) async {
    starts++;
    lastConfig = config;
    startedConfigs.add(config);
    if (failStart) throw Exception('编译失败，请检查入口');
    if (startResponse != null) return startResponse!();
    return running(
      id: 'session-$starts',
      projectPath: config.projectPath,
      mode: config.mode,
      capabilities: {
        'debugger': config.mode == 'debug' && !config.noDebug,
        'supportsHotReload': true,
        'supportsHotRestart': true,
      },
    );
  }

  @override
  Future<void> stopSession(String id) async {
    stops.add(id);
  }

  @override
  Future<void> reload(String id) async {
    reloads.add(id);
  }

  @override
  Future<void> restart(String id) async {
    restarts.add(id);
  }

  @override
  Future<List<Session>> listSessions() async => initialSessions ?? sessions;
  @override
  Future<LogPage> readLogs(
    String id, {
    int afterId = 0,
    int limit = 200,
    String query = '',
  }) async {
    logReads++;
    if (logReads == 1 && firstLogResponse != null) {
      return firstLogResponse!.future;
    }
    final page = logs
        .where((e) => e.id > afterId && e.text.contains(query))
        .take(limit)
        .toList();
    return LogPage(entries: page, nextAfterId: page.lastOrNull?.id ?? afterId);
  }

  @override
  Future<Map<String, dynamic>> debuggerRequest(
    String id,
    String command,
    Map<String, dynamic> args,
  ) async {
    debugRequests.add((id: id, command: command, args: Map.of(args)));
    if (debugResponse != null) return debugResponse!(id, command, args);
    if (command == 'threads') {
      return {
        'threads': [
          {'id': 42, 'name': 'main'},
        ],
      };
    }
    return {};
  }

  @override
  Future<String> openDevTools(String sessionId, String module) async {
    openedDevTools.add((sessionId: sessionId, module: module));
    return devToolsResponse == null
        ? 'http://127.0.0.1:9100/?embed=true&compiler=js#/$module?uri=test'
        : await devToolsResponse!(sessionId, module);
  }

  @override
  Future<void> closeDevTools(String sessionId) async {
    closedDevTools.add(sessionId);
    await closeDevToolsResponse?.call(sessionId);
  }

  @override
  Future<Map<String, dynamic>> networkRequest(
    String id,
    String method,
    Map<String, dynamic> args,
  ) async {
    networkRequests.add((id: id, method: method, args: Map.of(args)));
    if (networkResponse != null) return networkResponse!(id, method, args);
    return {};
  }

  @override
  Future<String> readSource(String path) async => 'void main() {}';
  @override
  Future<void> shutdown() async {
    shutdowns++;
  }
}

Session running({
  String id = 'session-1',
  String projectPath = '/sample',
  String mode = 'debug',
  String? operation,
  Map<String, bool>? capabilities,
  int generation = 1,
  int sequence = 1,
  String state = 'running',
}) => Session(
  id: id,
  generation: generation,
  sequence: sequence,
  state: state,
  projectPath: projectPath,
  deviceId: 'macos',
  mode: mode,
  operation: operation,
  capabilities:
      capabilities ??
      const {
        'debugger': true,
        'supportsHotReload': true,
        'supportsHotRestart': true,
      },
);

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);

Finder key(String value) => find.byKey(ValueKey(value));

Future<void> addProject(WidgetTester tester, String path) async {
  await tester.tap(key('add-project'));
  await tester.pumpAndSettle();
  await tester.enterText(key('add-project-path'), path);
  await tester.tap(key('add-project-discover'));
  await tester.pumpAndSettle();
  await tester.tap(key('add-project-confirm'));
  await tester.pumpAndSettle();
}

Future<void> selectProject(WidgetTester tester, String path) async {
  await tester.tap(key('project-$path'));
  await tester.pumpAndSettle();
}

Future<void> selectSession(WidgetTester tester, String id) async {
  await tester.tap(key('session-$id'));
  await tester.pumpAndSettle();
}

Future<void> changeMode(WidgetTester tester, String mode) async {
  await tester.ensureVisible(key('mode-select'));
  await tester.tap(key('mode-select'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(mode).last);
  await tester.pumpAndSettle();
}

Future<void> enterConfig(
  WidgetTester tester,
  String fieldKey,
  String text,
) async {
  if (key(fieldKey).evaluate().isEmpty) {
    await expandAdvancedSettings(tester);
  }
  await tester.ensureVisible(key(fieldKey));
  await tester.enterText(key(fieldKey), text);
  await tester.pump();
}

Future<void> expandAdvancedSettings(WidgetTester tester) async {
  if (key('sdk-path').evaluate().isNotEmpty) return;
  await tester.ensureVisible(key('advanced-settings'));
  await tester.tap(key('advanced-settings'));
  await tester.pumpAndSettle();
}

Future<void> mount(
  WidgetTester tester,
  FakeBridge bridge, {
  Size size = const Size(1400, 1000),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(bridge.controller.close);
  await tester.pumpWidget(FlutterDevApp(bridge: bridge));
  await tester.pump();
}

void main() {
  testWidgets('late preparing launch response cannot replace terminal event', (
    tester,
  ) async {
    final bridge = FakeBridge();
    bridge.startResponse = () async {
      bridge.controller.add(
        WorkbenchEvent(
          kind: 'session',
          sessionId: 'session-1',
          generation: 1,
          sequence: 2,
          session: running(sequence: 2, state: 'failed'),
        ),
      );
      return running(sequence: 1, state: 'preparing');
    };
    await mount(tester, bridge);
    await addProject(tester, '/sample');
    await tester.ensureVisible(key('run-project'));
    await tester.tap(key('run-project'));
    await tester.pumpAndSettle();
    expect(find.textContaining('失败'), findsWidgets);
    expect(find.textContaining('准备中'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late initial snapshot merges without replacing newer event', (
    tester,
  ) async {
    final snapshot = Completer<List<Session>>();
    final bridge = FakeBridge()..initialSessions = snapshot.future;
    await mount(tester, bridge);
    bridge.controller.add(
      WorkbenchEvent(
        kind: 'session',
        sessionId: 'session-1',
        generation: 1,
        sequence: 2,
        session: running(sequence: 2, state: 'paused'),
      ),
    );
    await tester.pump();
    snapshot.complete([running(sequence: 1, state: 'preparing')]);
    await tester.pumpAndSettle();
    expect(find.textContaining('已暂停'), findsWidgets);
    expect(find.textContaining('准备中'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late log response from previous search is discarded', (
    tester,
  ) async {
    final page = Completer<LogPage>();
    final bridge = FakeBridge()
      ..sessions = [running()]
      ..firstLogResponse = page
      ..logs = [
        const LogEntry(
          id: 2,
          category: 'stdout',
          text: 'current search result',
        ),
      ];
    await mount(tester, bridge);
    await selectSession(tester, 'session-1');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '搜索日志内容…',
      ),
      'current',
    );
    await tester.pump(const Duration(milliseconds: 300));
    page.complete(
      const LogPage(
        entries: [
          LogEntry(id: 1, category: 'stdout', text: 'old search result'),
        ],
        nextAfterId: 1,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('old search result'), findsNothing);
    expect(find.text('current search result'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed launch displays actionable error and allows retry', (
    tester,
  ) async {
    final bridge = FakeBridge()..failStart = true;
    await mount(tester, bridge);
    await addProject(tester, '/sample');
    await tester.ensureVisible(key('run-project'));
    await tester.tap(key('run-project'));
    await tester.pumpAndSettle();
    expect(find.textContaining('编译失败，请检查入口'), findsOneWidget);
    bridge.failStart = false;
    await tester.ensureVisible(key('run-project'));
    await tester.tap(key('run-project'));
    await tester.pumpAndSettle();
    expect(bridge.starts, 2);
    expect(bridge.lastConfig?.sdkPath, '/sdk');
    expect(find.textContaining('编译失败，请检查入口'), findsNothing);
    expect(find.textContaining('运行中'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'older session generations and sequences do not overwrite newer state',
    (tester) async {
      final bridge = FakeBridge()..sessions = [running()];
      await mount(tester, bridge);
      bridge.controller.add(
        WorkbenchEvent(
          kind: 'session',
          sessionId: 'session-1',
          generation: 2,
          sequence: 4,
          session: running(generation: 2, sequence: 4, state: 'paused'),
        ),
      );
      await tester.pump();
      bridge.controller.add(
        WorkbenchEvent(
          kind: 'session',
          sessionId: 'session-1',
          generation: 1,
          sequence: 999,
          session: running(),
        ),
      );
      bridge.controller.add(
        WorkbenchEvent(
          kind: 'session',
          sessionId: 'session-1',
          generation: 2,
          sequence: 3,
          session: running(generation: 2, sequence: 3),
        ),
      );
      await tester.pump();
      expect(find.textContaining('已暂停'), findsWidgets);
      expect(find.textContaining('运行中'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'log events coalesce and stale events do not trigger reads or idle polling',
    (tester) async {
      final bridge = FakeBridge()..sessions = [running()];
      await mount(tester, bridge);
      await selectSession(tester, 'session-1');
      await tester.pump(const Duration(milliseconds: 100));
      final initial = bridge.logReads;
      for (var sequence = 1; sequence <= 100; sequence++) {
        bridge.controller.add(
          WorkbenchEvent(
            kind: 'logs',
            sessionId: 'session-1',
            generation: 1,
            sequence: sequence,
          ),
        );
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(bridge.logReads, initial + 1);
      bridge.controller.add(
        const WorkbenchEvent(
          kind: 'logs',
          sessionId: 'session-1',
          generation: 1,
          sequence: 50,
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(bridge.logReads, initial + 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('narrow workbench remains usable and mode gates hot reload', (
    tester,
  ) async {
    final bridge = FakeBridge()
      ..sessions = [
        Session(
          id: 'session-1',
          generation: 1,
          state: 'running',
          projectPath: '/sample',
          deviceId: 'macos',
          mode: 'release',
          capabilities: const {'supportsHotReload': true},
        ),
      ];
    await mount(tester, bridge, size: const Size(560, 1000));
    await selectSession(tester, 'session-1');
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    final reload = tester.widget<IconButton>(
      find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '热重载'),
    );
    expect(reload.onPressed, isNull);
    await tester.tap(find.text('源码与调试'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('选择可调试的 Debug 会话后使用调试操作。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'add dialog accumulates projects and deduplicates discovered paths',
    (tester) async {
      final bridge = FakeBridge()
        ..discoverResponse = (root) => root == '/repo'
            ? const [
                Project(name: 'a', path: '/a', platforms: ['macos']),
                Project(name: 'b', path: '/b', platforms: ['macos']),
              ]
            : [
                Project(name: 'a', path: '/a', platforms: ['macos']),
              ];
      await mount(tester, bridge);
      await addProject(tester, '/a');
      await addProject(tester, '/repo');
      expect(key('project-/a'), findsOneWidget);
      expect(key('project-/b'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await selectProject(tester, '/a');
      expect(key('project-config'), findsOneWidget);
      expect(key('session-workspace'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('projects keep independent launch drafts across selection', (
    tester,
  ) async {
    final bridge = FakeBridge();
    await mount(tester, bridge);
    await addProject(tester, '/a');
    await enterConfig(tester, 'entrypoint', 'lib/a.dart');
    await enterConfig(tester, 'flavor', 'flavor-a');
    await enterConfig(tester, 'sdk-path', '/sdk-a');
    await addProject(tester, '/b');
    await enterConfig(tester, 'entrypoint', 'lib/b.dart');
    await enterConfig(tester, 'flavor', 'flavor-b');
    await enterConfig(tester, 'sdk-path', '/sdk-b');
    await selectProject(tester, '/a');
    expect(
      tester.widget<TextField>(key('entrypoint')).controller!.text,
      'lib/a.dart',
    );
    expect(
      tester.widget<TextField>(key('flavor')).controller!.text,
      'flavor-a',
    );
    expect(
      tester.widget<TextField>(key('sdk-path')).controller!.text,
      '/sdk-a',
    );
    await selectProject(tester, '/b');
    expect(
      tester.widget<TextField>(key('entrypoint')).controller!.text,
      'lib/b.dart',
    );
    expect(
      tester.widget<TextField>(key('flavor')).controller!.text,
      'flavor-b',
    );
    expect(
      tester.widget<TextField>(key('sdk-path')).controller!.text,
      '/sdk-b',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('quick launch reuses that project last submitted configuration', (
    tester,
  ) async {
    final bridge = FakeBridge();
    await mount(tester, bridge);
    await addProject(tester, '/a');
    await enterConfig(tester, 'entrypoint', 'lib/app.dart');
    await enterConfig(tester, 'flavor', 'production');
    await enterConfig(tester, 'dart-defines', 'API=one\nNAME=two');
    await enterConfig(tester, 'environment', 'TOKEN=one=two');
    await enterConfig(tester, 'tool-args', '["--verbose"]');
    await tester.ensureVisible(key('run-project'));
    await tester.tap(key('run-project'));
    await tester.pumpAndSettle();
    await selectProject(tester, '/a');
    await enterConfig(tester, 'flavor', 'unsubmitted');
    await enterConfig(tester, 'entrypoint', 'lib/unsubmitted.dart');
    await addProject(tester, '/b');
    await enterConfig(tester, 'flavor', 'other-project');
    await tester.tap(key('quick-run-/a'));
    await tester.pumpAndSettle();
    expect(bridge.starts, 2);
    final config = bridge.startedConfigs.last;
    expect(config.projectPath, '/a');
    expect(config.sdkPath, '/sdk');
    expect(config.deviceId, 'macos');
    expect(config.entrypoint, 'lib/app.dart');
    expect(config.flavor, 'production');
    expect(config.dartDefines, ['API=one', 'NAME=two']);
    expect(config.env, {'TOKEN': 'one=two'});
    expect(config.toolArgs, ['--verbose']);
    expect(key('session-session-1'), findsOneWidget);
    expect(key('session-session-2'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'background events preserve explicit project and session selection',
    (tester) async {
      final bridge = FakeBridge()
        ..sessions = [
          running(id: 'one', projectPath: '/a'),
          running(id: 'two', projectPath: '/b'),
        ];
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await selectProject(tester, '/a');
      bridge.controller.add(
        WorkbenchEvent(
          kind: 'session',
          sessionId: 'two',
          generation: 1,
          sequence: 2,
          session: running(
            id: 'two',
            projectPath: '/b',
            sequence: 2,
            state: 'paused',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(key('project-config'), findsOneWidget);
      expect(key('session-workspace'), findsNothing);
      await selectSession(tester, 'one');
      bridge.controller.add(
        WorkbenchEvent(
          kind: 'session',
          sessionId: 'three',
          generation: 1,
          sequence: 1,
          session: running(id: 'three', projectPath: '/b'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(key('session-reload'));
      await tester.pumpAndSettle();
      expect(bridge.reloads, ['one']);
      expect(key('project-/a'), findsOneWidget);
      expect(key('project-/b'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'top controls target selected session and actual debugger thread',
    (tester) async {
      final bridge = FakeBridge()
        ..sessions = [running(id: 'one'), running(id: 'two')];
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await selectSession(tester, 'two');
      await tester.tap(key('session-pause'));
      await tester.pumpAndSettle();
      expect(bridge.debugRequests.map((r) => r.command), ['threads', 'pause']);
      expect(bridge.debugRequests.every((r) => r.id == 'two'), isTrue);
      expect(bridge.debugRequests.last.args['threadId'], 42);
      await tester.tap(key('session-restart'));
      await tester.pumpAndSettle();
      await tester.tap(key('session-reload'));
      await tester.pumpAndSettle();
      expect(bridge.restarts, ['two']);
      expect(bridge.reloads, ['two']);
      bridge.controller.add(
        WorkbenchEvent(
          kind: 'session',
          sessionId: 'two',
          generation: 1,
          sequence: 2,
          session: running(id: 'two', sequence: 2, state: 'paused'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(key('session-pause'));
      await tester.pumpAndSettle();
      expect(bridge.debugRequests.last.command, 'continue');
      expect(bridge.debugRequests.last.args['threadId'], 42);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('capabilities and in-flight operations gate top actions', (
    tester,
  ) async {
    final bridge = FakeBridge()
      ..sessions = [
        running(id: 'profile', mode: 'profile'),
        running(id: 'release', mode: 'release'),
        running(
          id: 'no-debug',
          capabilities: const {
            'debugger': false,
            'supportsHotReload': true,
            'supportsHotRestart': true,
          },
        ),
        running(id: 'operation', operation: 'reload'),
        running(id: 'unsupported', capabilities: const {'debugger': true}),
      ];
    await mount(tester, bridge);
    await tester.pumpAndSettle();
    for (final id in ['profile', 'release', 'operation']) {
      await selectSession(tester, id);
      for (final action in [
        'session-pause',
        'session-restart',
        'session-reload',
      ]) {
        expect(
          tester.widget<IconButton>(key(action)).onPressed,
          isNull,
          reason: '$id should disable $action',
        );
      }
    }
    await selectSession(tester, 'no-debug');
    expect(tester.widget<IconButton>(key('session-pause')).onPressed, isNull);
    await selectSession(tester, 'unsupported');
    expect(tester.widget<IconButton>(key('session-restart')).onPressed, isNull);
    expect(tester.widget<IconButton>(key('session-reload')).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('560px keeps project sidebar beside configuration and session', (
    tester,
  ) async {
    final bridge = FakeBridge()..sessions = [running()];
    await mount(tester, bridge, size: const Size(560, 1000));
    await selectSession(tester, 'session-1');
    final sidebar = tester.getRect(key('project-sidebar'));
    final workspace = tester.getRect(key('session-workspace'));
    expect(sidebar.right, lessThanOrEqualTo(workspace.left));
    expect(sidebar.top, lessThan(workspace.top));
    final actions = tester.getRect(key('session-actions'));
    expect(actions.right, lessThanOrEqualTo(workspace.right));
    expect(actions.top, lessThan(workspace.top));
    await selectProject(tester, '/sample');
    final config = tester.getRect(key('project-config'));
    expect(sidebar.right, lessThanOrEqualTo(config.left));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'same generation sessions reset log cursor when selection changes',
    (tester) async {
      final bridge = FakeBridge()
        ..sessions = [running(id: 'one'), running(id: 'two')]
        ..logs = const [
          LogEntry(id: 9, category: 'stdout', text: 'first session log'),
        ];
      await mount(tester, bridge);
      await selectSession(tester, 'one');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('first session log'), findsOneWidget);
      bridge.logs = const [
        LogEntry(id: 1, category: 'stdout', text: 'second session log'),
      ];
      await selectSession(tester, 'two');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('first session log'), findsNothing);
      expect(find.text('second session log'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late launch completion preserves newer explicit project selection',
    (tester) async {
      final pending = Completer<Session>();
      final bridge = FakeBridge()..startResponse = () => pending.future;
      await mount(tester, bridge);
      await addProject(tester, '/a');
      await addProject(tester, '/b');
      await selectProject(tester, '/a');
      await tester.ensureVisible(key('run-project'));
      await tester.tap(key('run-project'));
      await tester.pump();
      await tester.tap(key('project-/b'));
      await tester.pump();
      pending.complete(running(projectPath: '/a'));
      await tester.pumpAndSettle();
      expect(key('project-config'), findsOneWidget);
      expect(key('session-workspace'), findsNothing);
      expect(key('session-session-1'), findsOneWidget);
      await enterConfig(tester, 'flavor', 'still-b');
      bridge.startResponse = null;
      await tester.ensureVisible(key('run-project'));
      await tester.tap(key('run-project'));
      await tester.pumpAndSettle();
      expect(bridge.lastConfig!.projectPath, '/b');
      expect(bridge.lastConfig!.flavor, 'still-b');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'delayed thread discovery keeps pause bound to originating session',
    (tester) async {
      final threads = Completer<Map<String, dynamic>>();
      final bridge = FakeBridge()
        ..sessions = [running(id: 'one'), running(id: 'two')]
        ..debugResponse = (id, command, args) async =>
            command == 'threads' ? threads.future : {};
      await mount(tester, bridge);
      await selectSession(tester, 'one');
      await tester.tap(key('session-pause'));
      await tester.pump();
      await tester.tap(key('session-two'));
      await tester.pump();
      threads.complete({
        'threads': [
          {'id': 73, 'name': 'main'},
        ],
      });
      await tester.pumpAndSettle();
      expect(bridge.debugRequests.map((r) => r.command), ['threads', 'pause']);
      expect(bridge.debugRequests.every((r) => r.id == 'one'), isTrue);
      expect(bridge.debugRequests.last.args['threadId'], 73);
      await tester.tap(key('session-reload'));
      await tester.pumpAndSettle();
      expect(bridge.reloads, ['two']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'platform device mode and explicit SDK feed launch configuration',
    (tester) async {
      final bridge = FakeBridge();
      bridge.discoverResponse = (_) => const [
        Project(
          name: 'sample',
          path: '/sample',
          platforms: ['macos', 'android'],
        ),
      ];
      bridge.devices = const [
        Device(id: 'macos', name: 'Mac', platform: 'darwin'),
        Device(id: 'phone', name: 'Android phone', platform: 'android-arm64'),
      ];
      await mount(tester, bridge);
      await addProject(tester, '/sample');
      await enterConfig(tester, 'sdk-path', '/custom-sdk');
      await tester.ensureVisible(key('resolve-sdk'));
      await tester.tap(key('resolve-sdk'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('platform-select'));
      await tester.tap(key('platform-select'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('android').last);
      await tester.pumpAndSettle();
      await changeMode(tester, 'profile');
      await tester.ensureVisible(key('run-project'));
      await tester.tap(key('run-project'));
      await tester.pumpAndSettle();
      expect(bridge.lastConfig!.sdkPath, '/custom-sdk');
      expect(bridge.lastConfig!.deviceId, 'phone');
      expect(bridge.lastConfig!.mode, 'profile');
      expect(tester.widget<IconButton>(key('session-pause')).onPressed, isNull);
      expect(
        tester.widget<IconButton>(key('session-reload')).onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('SDK path edits disable launch until the new path is resolved', (
    tester,
  ) async {
    final bridge = FakeBridge();
    await mount(tester, bridge);
    await addProject(tester, '/sample');
    await enterConfig(tester, 'sdk-path', '/new-sdk');
    expect(tester.widget<FilledButton>(key('run-project')).onPressed, isNull);
    await tester.ensureVisible(key('resolve-sdk'));
    await tester.tap(key('resolve-sdk'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(key('run-project'));
    await tester.tap(key('run-project'));
    await tester.pumpAndSettle();
    expect(bridge.lastConfig!.sdkPath, '/new-sdk');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'selection during slow SDK resolution resolves the chosen project',
    (tester) async {
      final sdkA = Completer<Sdk>();
      final bridge = FakeBridge()
        ..sessions = [
          running(id: 'one', projectPath: '/a'),
          running(id: 'two', projectPath: '/b'),
        ]
        ..sdkResponse = (path, explicit) async => path == '/a'
            ? sdkA.future
            : const Sdk(
                path: '/sdk-b',
                flutterVersion: '3.44',
                dartVersion: '3.12',
                source: 'test',
              );
      await mount(tester, bridge);
      await tester.tap(key('project-/a'));
      await tester.pump();
      await tester.tap(key('project-/b'));
      await tester.pump();
      sdkA.complete(
        const Sdk(
          path: '/sdk-a',
          flutterVersion: '3.44',
          dartVersion: '3.12',
          source: 'test',
        ),
      );
      await tester.pumpAndSettle();
      expect(bridge.sdkRequests.map((r) => r.projectPath), ['/a', '/b']);
      await tester.ensureVisible(key('run-project'));
      await tester.tap(key('run-project'));
      await tester.pumpAndSettle();
      expect(bridge.lastConfig!.projectPath, '/b');
      expect(bridge.lastConfig!.sdkPath, '/sdk-b');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
