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
        selectProject;

Future<void> collapseAdvanced(WidgetTester tester) async {
  await tester.ensureVisible(key('advanced-settings'));
  await tester.tap(key('advanced-settings'));
  await tester.pumpAndSettle();
  expect(key('sdk-path'), findsNothing);
}

void main() {
  testWidgets('build action follows launch and works without a device', (
    tester,
  ) async {
    final bridge = FakeBridge()..devices = const [];
    await mount(tester, bridge);
    await addProject(tester, '/sample');
    expect(tester.widget<FilledButton>(key('run-project')).onPressed, isNull);
    final build = tester.widget<OutlinedButton>(key('build-project'));
    expect(build.onPressed, isNotNull);
    expect(
      tester.getRect(key('build-project')).left,
      greaterThanOrEqualTo(tester.getRect(key('run-project')).right),
    );
    await tester.tap(key('build-project'));
    await tester.pumpAndSettle();
    expect(key('build-dialog'), findsOneWidget);
    expect(bridge.starts, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'default launch page shows target and a fixed header launch action',
    (tester) async {
      final bridge = FakeBridge();
      await mount(tester, bridge);
      await addProject(tester, '/sample');
      expect(key('platform-select'), findsOneWidget);
      expect(key('device-select'), findsOneWidget);
      expect(key('mode-select'), findsOneWidget);
      expect(key('entrypoint'), findsOneWidget);
      expect(key('advanced-settings'), findsOneWidget);
      expect(key('sdk-path'), findsNothing);
      expect(key('flavor'), findsNothing);
      expect(find.text('Flutter SDK'), findsNothing);
      expect(find.text('启动选项'), findsNothing);

      final startRect = tester.getRect(key('run-project'));
      final titleRect = tester.getRect(key('workspace-title'));
      final bodyRect = tester.getRect(key('project-config'));
      expect(startRect.left, greaterThan(titleRect.right));
      expect(startRect.bottom, lessThanOrEqualTo(bodyRect.top));
      expect(
        find.ancestor(
          of: key('run-project'),
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );

      await expandAdvancedSettings(tester);
      await tester.ensureVisible(key('tool-args'));
      await tester.pumpAndSettle();
      expect(tester.getRect(key('run-project')), startRect);
      expect(tester.takeException(), isNull);
      await tester.tap(key('run-project'));
      await tester.pumpAndSettle();
      expect(bridge.starts, 1);
    },
  );

  testWidgets(
    'folding advanced options retains SDK and submitted launch values',
    (tester) async {
      final bridge = FakeBridge();
      await mount(tester, bridge);
      await addProject(tester, '/a');
      await enterConfig(tester, 'sdk-path', '/independent/flutter');
      await tester.tap(key('resolve-sdk'));
      await tester.pumpAndSettle();
      await enterConfig(tester, 'entrypoint', 'lib/production.dart');
      await enterConfig(tester, 'flavor', 'production');
      await enterConfig(tester, 'dart-defines', 'API=one\nNAME=two');
      await enterConfig(tester, 'environment', 'TOKEN=one=two');
      await enterConfig(tester, 'tool-args', '["--verbose"]');
      await collapseAdvanced(tester);
      final requests = bridge.sdkRequests.length;

      await addProject(tester, '/b');
      expect(key('sdk-path'), findsNothing);
      await enterConfig(tester, 'flavor', 'development');
      await selectProject(tester, '/a');
      expect(key('sdk-path'), findsNothing);
      await expandAdvancedSettings(tester);
      expect(
        tester.widget<TextField>(key('sdk-path')).controller!.text,
        '/independent/flutter',
      );
      expect(
        tester.widget<TextField>(key('flavor')).controller!.text,
        'production',
      );
      // Visiting another project accounts for one detection; folding adds none.
      expect(bridge.sdkRequests.length, requests + 1);
      await collapseAdvanced(tester);
      await tester.tap(key('run-project'));
      await tester.pumpAndSettle();
      final submitted = bridge.startedConfigs.single;
      expect(submitted.projectPath, '/a');
      expect(submitted.sdkPath, '/independent/flutter');
      expect(submitted.sdkPreference, '/independent/flutter');
      expect(submitted.entrypoint, 'lib/production.dart');
      expect(submitted.flavor, 'production');
      expect(submitted.dartDefines, ['API=one', 'NAME=two']);
      expect(submitted.env, {'TOKEN': 'one=two'});
      expect(submitted.toolArgs, ['--verbose']);
      await selectProject(tester, '/b');
      expect(key('sdk-path'), findsOneWidget);
      expect(
        tester.widget<TextField>(key('flavor')).controller!.text,
        'development',
      );
    },
  );

  testWidgets('device refresh and emulator launch update the device selector', (
    tester,
  ) async {
    final bridge = FakeBridge()
      ..devices = const []
      ..emulators = const [
        Emulator(id: 'pixel', name: 'Pixel Test', platform: 'android'),
      ]
      ..discoverResponse = (_) => const [
        Project(name: 'sample', path: '/sample', platforms: ['android']),
      ];
    await mount(tester, bridge);
    await addProject(tester, '/sample');
    expect(tester.widget<FilledButton>(key('run-project')).onPressed, isNull);
    final deviceReads = bridge.deviceRequests.length;
    final emulatorReads = bridge.emulatorRequests.length;
    bridge.devices = const [
      Device(id: 'usb', name: 'USB phone', platform: 'android-arm64'),
    ];
    await tester.tap(key('refresh-devices'));
    await tester.pumpAndSettle();
    expect(bridge.deviceRequests.length, deviceReads + 1);
    expect(bridge.emulatorRequests.length, emulatorReads + 1);
    expect(find.textContaining('USB phone'), findsWidgets);
    expect(
      tester.widget<FilledButton>(key('run-project')).onPressed,
      isNotNull,
    );

    bridge.emulatorLaunchResponse = (_, _) async {
      bridge.devices = const [
        Device(
          id: 'emulator-5554',
          name: 'Pixel Test',
          platform: 'android-arm64',
          isEmulator: true,
        ),
      ];
    };
    await tester.tap(key('launch-emulator'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pixel Test · android'));
    await tester.pumpAndSettle();
    expect(bridge.launchedEmulators, [(sdkPath: '/sdk', emulatorId: 'pixel')]);
    expect(bridge.deviceRequests.length, deviceReads + 2);
    expect(bridge.emulatorRequests.length, emulatorReads + 2);
    expect(find.textContaining('USB phone'), findsNothing);
    expect(find.textContaining('Pixel Test'), findsWidgets);
    await tester.tap(key('run-project'));
    await tester.pumpAndSettle();
    expect(bridge.startedConfigs.single.deviceId, 'emulator-5554');
  });

  for (final mode in ['light', 'dark']) {
    for (final width in [1400.0, 560.0]) {
      testWidgets(
        '$mode layout at ${width.toInt()}px keeps related controls adjacent',
        (tester) async {
          final bridge = FakeBridge()
            ..appSettings = AppSettings(themeMode: mode)
            ..emulators = const [
              Emulator(id: 'test', name: 'Test', platform: 'macos'),
            ];
          await mount(tester, bridge, size: Size(width, 800));
          await addProject(tester, '/sample');
          final group = key('device-controls');
          expect(
            find.descendant(of: group, matching: key('device-select')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: group, matching: key('refresh-devices')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: group, matching: key('launch-emulator')),
            findsOneWidget,
          );
          await tester.ensureVisible(group);
          await tester.pumpAndSettle();
          final device = tester.getRect(key('device-select'));
          final refresh = tester.getRect(key('refresh-devices'));
          final emulator = tester.getRect(key('launch-emulator'));
          expect(refresh.right, lessThanOrEqualTo(emulator.left));
          expect(refresh.center.dy, closeTo(emulator.center.dy, 2));
          if (width == 1400) {
            expect(device.right, lessThanOrEqualTo(refresh.left));
            expect(device.center.dy, closeTo(refresh.center.dy, 24));
          } else {
            expect(refresh.top, greaterThanOrEqualTo(device.bottom));
          }
          expect(tester.takeException(), isNull);

          await expandAdvancedSettings(tester);
          await tester.ensureVisible(key('sdk-path'));
          await tester.pumpAndSettle();
          final sdk = tester.getRect(key('sdk-path'));
          final resolve = tester.getRect(key('resolve-sdk'));
          expect(resolve.left, greaterThanOrEqualTo(sdk.right));
          expect(resolve.center.dy, closeTo(sdk.center.dy, 24));
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(key('tool-args'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await collapseAdvanced(tester);
          expect(tester.takeException(), isNull);
          await tester.tap(key('run-project'));
          await tester.pumpAndSettle();
          expect(bridge.starts, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
