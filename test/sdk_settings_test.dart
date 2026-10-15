import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';

import 'workbench_test.dart'
    show
        FakeBridge,
        addProject,
        enterConfig,
        expandAdvancedSettings,
        key,
        mount,
        running,
        selectProject;

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(key('app-settings'));
  await tester.pumpAndSettle();
}

String sdkInput(WidgetTester tester) =>
    tester.widget<TextField>(key('default-sdk-path')).controller!.text;

Future<void> saveSdk(WidgetTester tester, String path) async {
  await tester.enterText(key('default-sdk-path'), path);
  await tester.tap(key('default-sdk-save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a corrupted settings file can be replaced or cleared in the page',
    (tester) async {
      final load = Completer<AppSettings>();
      final bridge = FakeBridge()..initialSettings = load.future;
      await mount(tester, bridge);
      await tester.tap(key('app-settings'));
      await tester.pump();
      load.completeError(Exception('settings.json 损坏'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: key('sdk-settings-page'),
          matching: find.textContaining('settings.json 损坏'),
        ),
        findsOneWidget,
      );
      expect(find.text('读取失败，原有设置尚未确认'), findsOneWidget);
      expect(key('default-sdk-path'), findsOneWidget);
      expect(
        tester.widget<TextButton>(key('default-sdk-clear')).onPressed,
        isNotNull,
      );
      await saveSdk(tester, '/recovered-sdk');
      expect(bridge.appSettings.defaultSdkPath, '/recovered-sdk');
      expect(find.textContaining('settings.json 损坏'), findsNothing);
      await tester.tap(key('default-sdk-clear'));
      await tester.pumpAndSettle();
      expect(bridge.appSettings.defaultSdkPath, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('settings loads the saved SDK and fits the narrow layout', (
    tester,
  ) async {
    final bridge = FakeBridge()
      ..appSettings = const AppSettings(defaultSdkPath: '/saved-sdk');
    await mount(tester, bridge, size: const Size(560, 1000));
    await openSettings(tester);
    expect(key('sdk-settings-page'), findsOneWidget);
    expect(sdkInput(tester), '/saved-sdk');
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('尚未接入'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('invalid SDK shows an error without replacing saved settings', (
    tester,
  ) async {
    final bridge = FakeBridge()
      ..appSettings = const AppSettings(defaultSdkPath: '/saved-sdk');
    await mount(tester, bridge);
    await openSettings(tester);
    await saveSdk(tester, '/invalid');
    expect(find.textContaining('SDK 路径无效'), findsWidgets);
    expect(bridge.appSettings.defaultSdkPath, '/saved-sdk');
    expect(sdkInput(tester), '/invalid');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('save displays the canonical SDK path and clear removes it', (
    tester,
  ) async {
    final bridge = FakeBridge()
      ..settingsResponse = (path) async =>
          AppSettings(defaultSdkPath: path == null ? null : '/canonical-sdk');
    await mount(tester, bridge);
    await openSettings(tester);
    await saveSdk(tester, '/linked-sdk');
    expect(bridge.savedSdkPaths, ['/linked-sdk']);
    expect(sdkInput(tester), '/canonical-sdk');
    await tester.tap(key('default-sdk-clear'));
    await tester.pumpAndSettle();
    expect(bridge.savedSdkPaths, ['/linked-sdk', null]);
    expect(bridge.appSettings.defaultSdkPath, isNull);
    expect(sdkInput(tester), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'project SDK fallback displays its reason and launches globally',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = const AppSettings(defaultSdkPath: '/global-sdk')
        ..sdkResponse = (project, explicit) async => Sdk(
          path: explicit == '/broken-sdk' ? '/global-sdk' : '/project-sdk',
          flutterVersion: '3.44',
          dartVersion: '3.12',
          source: explicit == '/broken-sdk' ? 'global_default' : 'project',
          fallbackReason: explicit == '/broken-sdk' ? '项目 SDK 无法执行' : null,
        );
      await mount(tester, bridge);
      await addProject(tester, '/sample');
      await enterConfig(tester, 'sdk-path', '/broken-sdk');
      await tester.ensureVisible(key('resolve-sdk'));
      await tester.tap(key('resolve-sdk'));
      await tester.pumpAndSettle();
      expect(find.textContaining('项目 SDK 无法执行'), findsWidgets);
      expect(find.textContaining('/global-sdk'), findsWidgets);
      await tester.ensureVisible(key('run-project'));
      await tester.tap(key('run-project'));
      await tester.pumpAndSettle();
      expect(bridge.lastConfig?.sdkPath, '/global-sdk');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'global changes refresh project caches and quick launch configs',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = const AppSettings(defaultSdkPath: '/old-sdk');
      bridge.sdkResponse = (project, explicit) async => Sdk(
        path: explicit ?? bridge.appSettings.defaultSdkPath!,
        flutterVersion: '3.44',
        dartVersion: '3.12',
        source: 'global_default',
      );
      await mount(tester, bridge);
      await addProject(tester, '/a');
      await addProject(tester, '/b');
      await tester.ensureVisible(key('run-project'));
      await tester.tap(key('run-project'));
      await tester.pumpAndSettle();
      expect(bridge.lastConfig?.sdkPath, '/old-sdk');
      final resolves = bridge.sdkRequests.length;
      await openSettings(tester);
      await saveSdk(tester, '/new-sdk');
      await selectProject(tester, '/a');
      expect(bridge.sdkRequests.length, greaterThan(resolves));
      await expandAdvancedSettings(tester);
      expect(find.textContaining('/new-sdk'), findsWidgets);
      await tester.tap(key('quick-run-/b'));
      await tester.pumpAndSettle();
      expect(bridge.lastConfig?.sdkPath, '/new-sdk');
      expect(bridge.starts, 2);
      expect(bridge.stops, isEmpty);
      expect(bridge.restarts, isEmpty);
      expect(bridge.reloads, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('session updates keep the selected settings page visible', (
    tester,
  ) async {
    final bridge = FakeBridge()..sessions = [running()];
    await mount(tester, bridge);
    await openSettings(tester);
    bridge.controller.add(
      WorkbenchEvent(
        kind: 'session',
        sessionId: 'session-1',
        generation: 1,
        sequence: 2,
        session: running(sequence: 2, state: 'paused'),
      ),
    );
    await tester.pumpAndSettle();
    expect(key('sdk-settings-page'), findsOneWidget);
    expect(key('session-workspace'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('quick launch keeps the submitted independent SDK preference', (
    tester,
  ) async {
    final bridge = FakeBridge()
      ..appSettings = const AppSettings(defaultSdkPath: '/old-global');
    bridge.sdkResponse = (project, explicit) async => Sdk(
      path: explicit ?? bridge.appSettings.defaultSdkPath!,
      flutterVersion: '3.44',
      dartVersion: '3.12',
      source: explicit == null ? 'global_default' : 'explicit',
    );
    await mount(tester, bridge);
    await addProject(tester, '/sample');
    await enterConfig(tester, 'sdk-path', '/independent-sdk');
    await tester.ensureVisible(key('resolve-sdk'));
    await tester.tap(key('resolve-sdk'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(key('run-project'));
    await tester.tap(key('run-project'));
    await tester.pumpAndSettle();
    await selectProject(tester, '/sample');
    await enterConfig(tester, 'sdk-path', '/unsubmitted-sdk');
    await openSettings(tester);
    await saveSdk(tester, '/new-global');
    await tester.tap(key('quick-run-/sample'));
    await tester.pumpAndSettle();
    expect(bridge.lastConfig?.sdkPath, '/independent-sdk');
    expect(bridge.sdkRequests.last.explicitPath, '/independent-sdk');
    await selectProject(tester, '/sample');
    expect(
      tester.widget<TextField>(key('sdk-path')).controller!.text,
      '/unsubmitted-sdk',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a save completing after navigation refreshes the project SDK', (
    tester,
  ) async {
    final save = Completer<AppSettings>();
    final bridge = FakeBridge()
      ..appSettings = const AppSettings(defaultSdkPath: '/old-sdk')
      ..settingsResponse = (_) => save.future;
    bridge.sdkResponse = (project, explicit) async => Sdk(
      path: bridge.appSettings.defaultSdkPath!,
      flutterVersion: '3.44',
      dartVersion: '3.12',
      source: 'global_default',
    );
    await mount(tester, bridge);
    await addProject(tester, '/sample');
    await openSettings(tester);
    await tester.enterText(key('default-sdk-path'), '/new-sdk');
    await tester.tap(key('default-sdk-save'));
    await tester.pump();
    expect(tester.widget<TextField>(key('default-sdk-path')).enabled, isFalse);
    await selectProject(tester, '/sample');
    await expandAdvancedSettings(tester);
    expect(find.textContaining('/old-sdk'), findsWidgets);
    save.complete(const AppSettings(defaultSdkPath: '/new-sdk'));
    await tester.pumpAndSettle();
    expect(key('project-config'), findsOneWidget);
    expect(find.textContaining('/new-sdk'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'late settings load and save are safe after the page is disposed',
    (tester) async {
      final load = Completer<AppSettings>();
      final bridge = FakeBridge()..initialSettings = load.future;
      await mount(tester, bridge);
      await tester.tap(key('app-settings'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      load.complete(const AppSettings(defaultSdkPath: '/loaded-sdk'));
      await tester.pump();
      expect(tester.takeException(), isNull);

      final save = Completer<AppSettings>();
      final savingBridge = FakeBridge()..settingsResponse = (_) => save.future;
      await mount(tester, savingBridge);
      await openSettings(tester);
      await tester.enterText(key('default-sdk-path'), '/linked-sdk');
      await tester.tap(key('default-sdk-save'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      save.complete(const AppSettings(defaultSdkPath: '/canonical-sdk'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
