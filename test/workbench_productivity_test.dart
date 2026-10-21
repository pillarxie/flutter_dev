import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/app.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';
import 'package:flutter_dev/core/presentation/workbench_select.dart';
import 'package:flutter_dev/features/devtools/network_panel.dart';
import 'package:flutter_dev/features/logs/log_panel.dart';
import 'package:flutter_dev/features/testing/test_panel.dart';

import 'workbench_test.dart'
    show
        FakeBridge,
        enterConfig,
        expandAdvancedSettings,
        key,
        mount,
        selectProject,
        selectSession;

const _project = Project(name: 'sample', path: '/sample', platforms: ['macos']);
const _second = Project(name: 'second', path: '/second', platforms: ['macos']);

AppSettings _settings(
  WorkspacePreferences preferences, {
  List<Project> projects = const [_project],
  String? selected = '/sample',
  String mode = 'light',
}) => AppSettings(
  projects: projects,
  selectedProjectPath: selected,
  themeMode: mode,
  workspacePreferences: preferences,
);

void _persist(FakeBridge bridge, WorkspacePreferences preferences) {
  final old = bridge.appSettings;
  bridge.appSettings = AppSettings(
    defaultSdkPath: old.defaultSdkPath,
    themeMode: old.themeMode,
    buildPresets: old.buildPresets,
    projects: old.projects,
    selectedProjectPath: old.selectedProjectPath,
    workspacePreferences: preferences,
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump();
}

String _value(WidgetTester tester, String name) =>
    tester.widget<TextField>(key(name)).controller!.text;

Future<void> _saveAs(WidgetTester tester, String name) async {
  await tester.ensureVisible(key('run-profile-save-as'));
  await tester.tap(key('run-profile-save-as'));
  await tester.pumpAndSettle();
  await tester.enterText(key('run-profile-name'), name);
  await tester.tap(key('run-profile-confirm'));
  await tester.pumpAndSettle();
}

Future<void> _chooseProfile(WidgetTester tester, String name) async {
  await tester.ensureVisible(key('run-profile-select'));
  await tester.tap(key('run-profile-select'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

Future<void> _profileAction(
  WidgetTester tester,
  String action, {
  String? name,
}) async {
  await tester.ensureVisible(key('run-profile-actions'));
  await tester.tap(key('run-profile-actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
  if (name != null) {
    await tester.enterText(key('run-profile-name'), name);
    await tester.tap(key('run-profile-confirm'));
    await tester.pumpAndSettle();
  }
}

Future<void> _hotkey(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool control = false,
  bool meta = false,
  bool shift = false,
  bool alt = false,
}) async {
  final modifiers = [
    if (control) LogicalKeyboardKey.controlLeft,
    if (meta) LogicalKeyboardKey.metaLeft,
    if (shift) LogicalKeyboardKey.shiftLeft,
    if (alt) LogicalKeyboardKey.altLeft,
  ];
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  await tester.sendKeyEvent(key);
  for (final modifier in modifiers.reversed) {
    await tester.sendKeyUpEvent(modifier);
  }
  await tester.pump();
}

Session _session(
  String id, {
  String project = '/sample',
  String mode = 'debug',
  Map<String, bool>? capabilities,
  String? operation,
  int sequence = 1,
}) => Session(
  id: id,
  generation: 1,
  sequence: sequence,
  state: 'running',
  projectPath: project,
  deviceId: 'macos',
  mode: mode,
  operation: operation,
  serviceUri: 'ws://localhost:123/ws',
  capabilities:
      capabilities ??
      const {
        'debugger': true,
        'supportsHotReload': true,
        'supportsHotRestart': true,
      },
);

class _TestBridge extends FakeBridge {
  final testDiscoveries = <String>[];
  @override
  Future<List<String>> discoverTestFiles(String projectPath) async {
    testDiscoveries.add(projectPath);
    return ['test/real_test.dart'];
  }
}

void main() {
  testWidgets(
    'restores project SDK, device, target, mode and full saved launch draft',
    (tester) async {
      const profile = RunProfile(
        id: 'draft',
        name: 'draft',
        projectPath: '/sample',
        sdkPath: '/custom/flutter',
        deviceId: 'preferred',
        platform: 'macos',
        entrypoint: 'lib/staging.dart',
        mode: 'profile',
        flavor: 'staging',
        dartDefines: ['API=staging'],
        environment: {'TOKEN': 'a=b'},
        toolArgs: ['--verbose'],
        noDebug: true,
      );
      final bridge = FakeBridge()
        ..devices = const [
          Device(id: 'macos', name: 'Mac', platform: 'darwin'),
          Device(id: 'preferred', name: 'Preferred', platform: 'darwin'),
        ]
        ..appSettings = _settings(
          const WorkspacePreferences(
            projectStates: [
              ProjectRunState(
                projectPath: '/sample',
                draft: profile,
                autoReload: true,
              ),
            ],
          ),
        );
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      expect(bridge.sdkRequests.last.explicitPath, '/custom/flutter');
      expect(find.text('Preferred · darwin'), findsOneWidget);
      expect(
        tester.widget<WorkbenchSelect<String>>(key('platform-select')).value,
        'macos',
      );
      expect(find.text('profile'), findsOneWidget);
      expect(_value(tester, 'entrypoint'), 'lib/staging.dart');
      expect(tester.widget<Switch>(key('auto-reload')).value, isTrue);
      await expandAdvancedSettings(tester);
      expect(_value(tester, 'sdk-path'), '/custom/flutter');
      expect(_value(tester, 'flavor'), 'staging');
      expect(_value(tester, 'dart-defines'), 'API=staging');
      expect(_value(tester, 'environment'), 'TOKEN=a=b');
      expect(_value(tester, 'tool-args'), '["--verbose"]');
      await tester.tap(key('run-project'));
      await tester.pumpAndSettle();
      final actual = bridge.startedConfigs.single;
      expect(actual.sdkPreference, '/custom/flutter');
      expect(actual.deviceId, 'preferred');
      expect(actual.mode, 'profile');
      expect(actual.env, {'TOKEN': 'a=b'});
      expect(actual.toolArgs, ['--verbose']);
      expect(actual.noDebug, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'partially typed environment and tool arguments survive remount verbatim',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = _settings(const WorkspacePreferences());
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await enterConfig(tester, 'environment', 'TOKEN=first\nINCOMPLETE');
      await enterConfig(tester, 'tool-args', '["--verbose",');
      await _flush(tester);
      final saved = bridge.appSettings.workspacePreferences;
      expect(
        saved.projectStates.single.draft!.environmentText,
        'TOKEN=first\nINCOMPLETE',
      );
      expect(saved.projectStates.single.draft!.toolArgsText, '["--verbose",');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(FlutterDevApp(bridge: bridge));
      await tester.pumpAndSettle();
      await expandAdvancedSettings(tester);
      expect(_value(tester, 'environment'), 'TOKEN=first\nINCOMPLETE');
      expect(_value(tester, 'tool-args'), '["--verbose",');
      expect(bridge.starts, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'named profiles support save, select, update, rename, delete and project isolation',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = _settings(
          const WorkspacePreferences(),
          projects: [_project, _second],
        );
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await enterConfig(tester, 'entrypoint', 'lib/development.dart');
      await _saveAs(tester, '开发环境');
      await enterConfig(tester, 'entrypoint', 'lib/production.dart');
      await _saveAs(tester, '生产环境');
      expect(bridge.appSettings.workspacePreferences.runProfiles, hasLength(2));
      await _chooseProfile(tester, '开发环境');
      expect(_value(tester, 'entrypoint'), 'lib/development.dart');
      await enterConfig(tester, 'entrypoint', 'lib/new_development.dart');
      await _profileAction(tester, '更新当前配置');
      await _chooseProfile(tester, '生产环境');
      expect(_value(tester, 'entrypoint'), 'lib/production.dart');
      await _chooseProfile(tester, '开发环境');
      expect(_value(tester, 'entrypoint'), 'lib/new_development.dart');
      await _profileAction(tester, '重命名', name: '本地开发');
      expect(
        bridge.appSettings.workspacePreferences.runProfiles.any(
          (p) => p.name == '本地开发',
        ),
        isTrue,
      );
      await selectProject(tester, '/second');
      await tester.tap(key('run-profile-select'));
      await tester.pumpAndSettle();
      expect(find.text('本地开发'), findsNothing);
      expect(find.text('生产环境'), findsNothing);
      await tester.tap(find.text('当前草稿').last);
      await tester.pumpAndSettle();
      await enterConfig(tester, 'entrypoint', 'lib/other.dart');
      await _saveAs(tester, '独立配置');
      await selectProject(tester, '/sample');
      expect(_value(tester, 'entrypoint'), 'lib/new_development.dart');
      await _profileAction(tester, '删除配置');
      expect(
        bridge.appSettings.workspacePreferences.runProfiles.map((p) => p.name),
        containsAll(['生产环境', '独立配置']),
      );
      expect(
        bridge.appSettings.workspacePreferences.runProfiles.any(
          (p) => p.name == '本地开发',
        ),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'preference write failures keep draft and expose a successful retry',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = _settings(const WorkspacePreferences());
      bridge.preferencesResponse = (_) =>
          Future.error(StateError('disk is read only'));
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await enterConfig(tester, 'entrypoint', 'lib/retained.dart');
      await _flush(tester);
      expect(find.textContaining('运行配置保存失败'), findsOneWidget);
      expect(_value(tester, 'entrypoint'), 'lib/retained.dart');
      bridge.preferencesResponse = null;
      await tester.tap(find.text('重试保存'));
      await tester.pump();
      expect(find.textContaining('运行配置保存失败'), findsNothing);
      expect(
        bridge
            .appSettings
            .workspacePreferences
            .projectStates
            .single
            .draft!
            .entrypoint,
        'lib/retained.dart',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'editing a new draft while submitted launch saves does not cancel that launch',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = _settings(const WorkspacePreferences());
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await enterConfig(tester, 'entrypoint', 'lib/submitted.dart');
      await _flush(tester);
      final pending = Completer<AppSettings>();
      WorkspacePreferences? submitted;
      bridge.preferencesResponse = (preferences) {
        submitted = preferences;
        return pending.future;
      };
      await tester.tap(key('run-project'));
      await tester.pump();
      expect(bridge.starts, 0);
      expect(submitted, isNotNull);
      await enterConfig(tester, 'entrypoint', 'lib/new_draft.dart');
      bridge.preferencesResponse = null;
      _persist(bridge, submitted!);
      pending.complete(bridge.appSettings);
      await tester.pump();
      await _flush(tester);
      expect(bridge.startedConfigs.single.entrypoint, 'lib/submitted.dart');
      expect(find.textContaining('运行配置尚未保存'), findsNothing);
      await selectProject(tester, '/sample');
      expect(_value(tester, 'entrypoint'), 'lib/new_draft.dart');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late settings preserve edited draft and restore unrelated saved project metadata',
    (tester) async {
      final pending = Completer<AppSettings>();
      final bridge = FakeBridge()..initialSettings = pending.future;
      await mount(tester, bridge);
      // Avoid pumpAndSettle while the initial workspace read is deliberately pending.
      await tester.tap(key('add-project'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(key('add-project-path'), '/sample');
      await tester.tap(key('add-project-discover'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(key('add-project-confirm'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(key('entrypoint'), 'lib/typed.dart');
      const named = RunProfile(
        id: 'named',
        name: '原配置',
        projectPath: '/sample',
        entrypoint: 'lib/named.dart',
        deviceId: 'macos',
      );
      const oldDraft = RunProfile(
        id: 'draft',
        name: 'draft',
        projectPath: '/sample',
        entrypoint: 'lib/old.dart',
      );
      const last = RunProfile(
        id: 'last',
        name: 'last',
        projectPath: '/sample',
        entrypoint: 'lib/last.dart',
        deviceId: 'macos',
      );
      bridge.initialSettings = null;
      bridge.appSettings = _settings(
        const WorkspacePreferences(
          runProfiles: [named],
          projectStates: [
            ProjectRunState(
              projectPath: '/sample',
              draft: oldDraft,
              lastRun: last,
              selectedProfileId: 'named',
              autoReload: true,
            ),
          ],
        ),
      );
      pending.complete(bridge.appSettings);
      await tester.pumpAndSettle();
      await _flush(tester);
      expect(_value(tester, 'entrypoint'), 'lib/typed.dart');
      expect(tester.widget<Switch>(key('auto-reload')).value, isTrue);
      final state =
          bridge.appSettings.workspacePreferences.projectStates.single;
      expect(state.lastRun!.entrypoint, 'lib/last.dart');
      expect(state.selectedProfileId, 'named');
      expect(
        tester.widget<WorkbenchSelect<String>>(key('run-profile-select')).value,
        'named',
      );
      expect(state.autoReload, isTrue);
      expect(
        tester.widget<IconButton>(key('quick-run-/sample')).onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('F5 starts and Shift F5 stops the selected session', (
    tester,
  ) async {
    final bridge = FakeBridge()
      ..appSettings = _settings(const WorkspacePreferences());
    await mount(tester, bridge);
    await tester.pumpAndSettle();
    await _hotkey(tester, LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();
    expect(bridge.starts, 1);
    await _hotkey(tester, LogicalKeyboardKey.f5, shift: true);
    await tester.pump();
    expect(bridge.stops, ['session-1']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'reload shortcuts honor mode, operation and adapter capabilities',
    (tester) async {
      final capable = _session('capable');
      final unsupported = _session(
        'unsupported',
        capabilities: const {
          'supportsHotReload': false,
          'supportsHotRestart': false,
        },
      );
      final profile = _session('profile', mode: 'profile');
      final busy = _session('busy', operation: 'hotRestart');
      final bridge = FakeBridge()
        ..sessions = [capable, unsupported, profile, busy];
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      for (final current in [unsupported, profile, busy]) {
        await selectSession(tester, current.id);
        await _hotkey(tester, LogicalKeyboardKey.keyR, control: true);
        await _hotkey(tester, LogicalKeyboardKey.keyR, meta: true, shift: true);
      }
      expect(bridge.reloads, isEmpty);
      expect(bridge.restarts, isEmpty);
      await selectSession(tester, capable.id);
      await _hotkey(tester, LogicalKeyboardKey.keyR, control: true);
      await tester.pump();
      await _hotkey(tester, LogicalKeyboardKey.keyR, meta: true, shift: true);
      await tester.pump();
      expect(bridge.reloads, ['capable']);
      expect(bridge.restarts, ['capable']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'search and page shortcuts focus the active panel without intercepting Option digit',
    (tester) async {
      final bridge = FakeBridge()..sessions = [_session('active')];
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await selectSession(tester, 'active');
      await _hotkey(tester, LogicalKeyboardKey.keyF, control: true);
      final logSearch = find.descendant(
        of: find.byType(LogPanel),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(logSearch).focusNode!.hasFocus, isTrue);
      await _hotkey(tester, LogicalKeyboardKey.digit3, meta: true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(NetworkPanel), findsOneWidget);
      await _hotkey(tester, LogicalKeyboardKey.keyF, meta: true);
      final networkSearch = find
          .descendant(
            of: find.byType(NetworkPanel),
            matching: find.byType(TextField),
          )
          .first;
      expect(
        tester.widget<TextField>(networkSearch).focusNode!.hasFocus,
        isTrue,
      );
      await _hotkey(tester, LogicalKeyboardKey.digit1, alt: true);
      expect(find.byType(NetworkPanel), findsOneWidget);
      await _hotkey(tester, LogicalKeyboardKey.digit1, control: true);
      await tester.pump();
      expect(find.byType(LogPanel), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'project and session shortcuts cycle selection without launching work',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = _settings(
          const WorkspacePreferences(),
          projects: [_project, _second],
        )
        ..sessions = [_session('a'), _session('b', project: '/second')];
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await _hotkey(
        tester,
        LogicalKeyboardKey.arrowDown,
        control: true,
        alt: true,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('workspace-title')).data, 'second');
      await _hotkey(tester, LogicalKeyboardKey.arrowUp, meta: true, alt: true);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('workspace-title')).data, 'sample');
      await _hotkey(tester, LogicalKeyboardKey.tab, control: true);
      await tester.pumpAndSettle();
      expect(key('logs-a-1'), findsOneWidget);
      await _hotkey(tester, LogicalKeyboardKey.tab, control: true);
      await tester.pumpAndSettle();
      expect(key('logs-b-1'), findsOneWidget);
      await _hotkey(tester, LogicalKeyboardKey.tab, control: true, shift: true);
      await tester.pumpAndSettle();
      expect(key('logs-a-1'), findsOneWidget);
      expect(bridge.starts, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'project tests open independently of a running application session',
    (tester) async {
      final bridge = _TestBridge()
        ..appSettings = _settings(const WorkspacePreferences());
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await tester.tap(key('test-project'));
      await tester.pumpAndSettle();
      expect(find.byType(TestPanel), findsOneWidget);
      expect(find.text('real_test.dart'), findsOneWidget);
      expect(bridge.testDiscoveries, ['/sample']);
      expect(bridge.starts, 0);
      await tester.tap(find.byTooltip('关闭测试面板'));
      await tester.pumpAndSettle();
      expect(find.byType(TestPanel), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'editor saves share the preference queue and retain profiles and newer drafts',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = _settings(const WorkspacePreferences());
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await _saveAs(tester, '保留配置');
      final pending = Completer<AppSettings>();
      WorkspacePreferences? first;
      bridge.preferencesResponse = (preferences) {
        first ??= preferences;
        return pending.future;
      };
      await _profileAction(tester, '重命名', name: '同时重命名');
      await enterConfig(tester, 'entrypoint', 'lib/while_saving.dart');
      await _flush(tester);
      await tester.tap(key('app-settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('editor-executable'));
      await tester.enterText(
        key('editor-executable'),
        '/Applications/Editor.app/editor',
      );
      await tester.enterText(
        key('editor-arguments'),
        '["--goto","{file}:{line}:{column}"]',
      );
      await tester.tap(key('editor-save'));
      await tester.pump();
      bridge.preferencesResponse = null;
      _persist(bridge, first!);
      pending.complete(bridge.appSettings);
      await tester.pumpAndSettle();
      final prefs = bridge.appSettings.workspacePreferences;
      expect(prefs.editorExecutable, '/Applications/Editor.app/editor');
      expect(prefs.runProfiles.single.name, '同时重命名');
      expect(
        prefs.projectStates.single.draft!.entrypoint,
        'lib/while_saving.dart',
      );
      expect(find.text('编辑器设置已保存'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [const Size(560, 900), const Size(1400, 1000)]) {
    for (final appearance in ['light', 'dark']) {
      testWidgets('configuration and editor fit ${size.width} $appearance', (
        tester,
      ) async {
        final bridge = FakeBridge()
          ..appSettings = _settings(
            const WorkspacePreferences(),
            mode: appearance,
          );
        await mount(tester, bridge, size: size);
        await tester.pumpAndSettle();
        expect(key('run-profile-select'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(key('app-settings'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(key('editor-save'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
