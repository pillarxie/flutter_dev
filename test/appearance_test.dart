import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';

import 'workbench_test.dart'
    show
        FakeBridge,
        addProject,
        enterConfig,
        key,
        mount,
        running,
        selectProject,
        selectSession;

Brightness appearance(WidgetTester tester) =>
    Theme.of(tester.element(key('project-sidebar'))).brightness;

void main() {
  testWidgets('failed first save restores the delayed persisted appearance', (
    tester,
  ) async {
    final load = Completer<AppSettings>();
    final bridge = FakeBridge()
      ..initialSettings = load.future
      ..themeResponse = (_) => Future.error(Exception('read only'));
    await mount(tester, bridge);
    await tester.tap(key('theme-dark'));
    await tester.pump();
    load.complete(const AppSettings(themeMode: 'dark'));
    await tester.pumpAndSettle();
    expect(appearance(tester), Brightness.dark);
    expect(find.textContaining('主题设置保存失败'), findsOneWidget);
  });

  testWidgets('restores saved appearance without changing SDK settings', (
    tester,
  ) async {
    final bridge = FakeBridge()
      ..appSettings = const AppSettings(
        defaultSdkPath: '/global/flutter',
        themeMode: 'dark',
      );
    await mount(tester, bridge);
    await tester.pumpAndSettle();
    expect(appearance(tester), Brightness.dark);
    expect(bridge.savedThemeModes, isEmpty);

    await tester.tap(key('theme-light'));
    await tester.pumpAndSettle();
    expect(appearance(tester), Brightness.light);
    expect(bridge.savedThemeModes, ['light']);
    expect(bridge.appSettings.defaultSdkPath, '/global/flutter');
    expect(bridge.appSettings.themeMode, 'light');
    expect(bridge.savedSdkPaths, isEmpty);
  });

  testWidgets(
    'theme changes retain selected session and project launch draft',
    (tester) async {
      final bridge = FakeBridge()..sessions = [running()];
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await selectProject(tester, '/sample');
      await enterConfig(tester, 'sdk-path', '/project/flutter');
      await tester.ensureVisible(key('resolve-sdk'));
      await tester.tap(key('resolve-sdk'));
      await tester.pumpAndSettle();
      await enterConfig(tester, 'entrypoint', 'lib/custom.dart');
      await selectSession(tester, 'session-1');
      final workspace = tester.element(key('session-workspace'));
      final requests = bridge.sdkRequests.length;
      final logReads = bridge.logReads;

      await tester.tap(key('theme-dark'));
      await tester.pumpAndSettle();
      expect(appearance(tester), Brightness.dark);
      expect(tester.element(key('session-workspace')), same(workspace));
      expect(bridge.sdkRequests.length, requests);
      expect(bridge.logReads, logReads);
      expect(bridge.starts, 0);
      expect(bridge.stops, isEmpty);

      await selectProject(tester, '/sample');
      expect(
        tester.widget<TextField>(key('sdk-path')).controller!.text,
        '/project/flutter',
      );
      await tester.ensureVisible(key('entrypoint'));
      expect(
        tester.widget<TextField>(key('entrypoint')).controller!.text,
        'lib/custom.dart',
      );
    },
  );

  testWidgets('settings theme switch retains unsaved global SDK editor', (
    tester,
  ) async {
    final bridge = FakeBridge()
      ..appSettings = const AppSettings(defaultSdkPath: '/saved/flutter');
    await mount(tester, bridge);
    await tester.tap(key('app-settings'));
    await tester.pumpAndSettle();
    await tester.enterText(key('default-sdk-path'), '/unsaved/flutter');
    await tester.tap(key('settings-theme-dark'));
    await tester.pumpAndSettle();
    expect(appearance(tester), Brightness.dark);
    expect(
      tester.widget<TextField>(key('default-sdk-path')).controller!.text,
      '/unsaved/flutter',
    );
    expect(bridge.appSettings.defaultSdkPath, '/saved/flutter');
    expect(bridge.savedSdkPaths, isEmpty);
    expect(bridge.sdkRequests, isEmpty);
  });

  testWidgets(
    'resizing settings to 560 by 500 retains the SDK draft and reachable controls',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = const AppSettings(defaultSdkPath: '/saved/flutter');
      await mount(tester, bridge, size: const Size(1000, 800));
      await tester.tap(key('app-settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('default-sdk-path'));
      await tester.enterText(
        key('default-sdk-path'),
        '/Users/developer/Flutter SDKs/unsaved/flutter',
      );

      tester.view.physicalSize = const Size(560, 500);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<TextField>(key('default-sdk-path')).controller!.text,
        '/Users/developer/Flutter SDKs/unsaved/flutter',
      );

      await tester.ensureVisible(key('settings-theme-dark'));
      await tester.tap(key('settings-theme-dark'));
      await tester.pumpAndSettle();
      expect(appearance(tester), Brightness.dark);
      expect(bridge.appSettings.defaultSdkPath, '/saved/flutter');
      expect(bridge.savedSdkPaths, isEmpty);

      tester.view.physicalSize = const Size(1000, 800);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('default-sdk-path')).controller!.text,
        '/Users/developer/Flutter SDKs/unsaved/flutter',
      );
      tester.view.physicalSize = const Size(560, 500);
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('settings-theme-light'));
      await tester.tap(key('settings-theme-light'));
      await tester.pumpAndSettle();
      expect(appearance(tester), Brightness.light);

      await tester.ensureVisible(key('default-sdk-browse'));
      expect(key('default-sdk-browse').hitTestable(), findsOneWidget);
      await tester.ensureVisible(key('default-sdk-save'));
      expect(key('default-sdk-save').hitTestable(), findsOneWidget);
      await tester.tap(key('default-sdk-save'));
      await tester.pumpAndSettle();
      expect(bridge.savedSdkPaths, [
        '/Users/developer/Flutter SDKs/unsaved/flutter',
      ]);
      expect(find.text('SDK 已验证，全局默认设置已保存。'), findsOneWidget);

      await tester.ensureVisible(key('default-sdk-clear'));
      expect(key('default-sdk-clear').hitTestable(), findsOneWidget);
      await tester.tap(key('default-sdk-clear'));
      await tester.pumpAndSettle();
      expect(bridge.appSettings.defaultSdkPath, isNull);
      expect(
        tester.widget<TextField>(key('default-sdk-path')).controller!.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed theme save restores last persisted mode and explains error',
    (tester) async {
      final bridge = FakeBridge()
        ..themeResponse = (_) async => throw Exception('disk full');
      await mount(tester, bridge);
      await tester.tap(key('theme-dark'));
      await tester.pumpAndSettle();
      expect(appearance(tester), Brightness.light);
      expect(find.textContaining('主题设置保存失败'), findsOneWidget);
      expect(find.textContaining('disk full'), findsOneWidget);
      expect(bridge.appSettings.themeMode, 'light');
    },
  );

  testWidgets(
    'rapid toggles persist in order and ignore stale startup settings',
    (tester) async {
      final initial = Completer<AppSettings>();
      final darkSave = Completer<AppSettings>();
      final bridge = FakeBridge()
        ..initialSettings = initial.future
        ..themeResponse = (mode) => mode == 'dark'
            ? darkSave.future
            : Future.value(AppSettings(themeMode: mode));
      await mount(tester, bridge);
      await tester.tap(key('theme-dark'));
      await tester.pump();
      await tester.tap(key('theme-light'));
      await tester.pump();
      expect(bridge.savedThemeModes, ['dark']);

      initial.complete(const AppSettings(themeMode: 'dark'));
      await tester.pumpAndSettle();
      expect(appearance(tester), Brightness.light);
      darkSave.complete(const AppSettings(themeMode: 'dark'));
      await tester.pumpAndSettle();
      expect(bridge.savedThemeModes, ['dark', 'light']);
      expect(bridge.appSettings.themeMode, 'light');
      expect(appearance(tester), Brightness.light);
    },
  );

  testWidgets(
    'last failed toggle restores latest successful intermediate save',
    (tester) async {
      final darkSave = Completer<AppSettings>();
      final bridge = FakeBridge()
        ..themeResponse = (mode) => mode == 'dark'
            ? darkSave.future
            : Future.error(Exception('read only'));
      await mount(tester, bridge);
      await tester.tap(key('theme-dark'));
      await tester.pump();
      await tester.tap(key('theme-light'));
      await tester.pump();
      darkSave.complete(const AppSettings(themeMode: 'dark'));
      await tester.pumpAndSettle();
      expect(appearance(tester), Brightness.dark);
      expect(bridge.appSettings.themeMode, 'dark');
      expect(find.textContaining('主题设置保存失败'), findsOneWidget);
    },
  );

  for (final mode in ['light', 'dark']) {
    testWidgets(
      '$mode appearance fits project, session and settings at 560px',
      (tester) async {
        final bridge = FakeBridge()..appSettings = AppSettings(themeMode: mode);
        await mount(tester, bridge, size: const Size(560, 800));
        await addProject(tester, '/sample');
        expect(tester.takeException(), isNull);
        await tester.tap(key('run-project'));
        await tester.pumpAndSettle();
        expect(key('session-workspace'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(key('app-settings'));
        await tester.pumpAndSettle();
        expect(key('sdk-settings-page'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(
          appearance(tester),
          mode == 'dark' ? Brightness.dark : Brightness.light,
        );
      },
    );
  }
}
