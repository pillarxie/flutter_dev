import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';
import 'package:flutter_dev/core/presentation/workbench_theme.dart';
import 'package:flutter_dev/features/build/build_dialog.dart';

import 'workbench_test.dart' show FakeBridge;

class BuildBridge extends FakeBridge {
  BuildSnapshot snapshot = const BuildSnapshot(
    id: 'build-1',
    projectPath: '/sample',
    state: 'running',
    target: 'apk',
    version: BuildVersion(buildName: '1.2.3', buildNumber: '45'),
  );
  final configs = <BuildConfig>[];
  final saved = <List<BuildPreset>>[];
  final opened = <String>[];
  final buildLogs = <LogEntry>[];
  int stopped = 0;
  bool failBuildStart = false, failNextLogs = false, failNextSnapshot = false;
  bool failOpenOutput = false;
  Future<BuildSnapshot>? pendingBuildStart;
  final readBuildIds = <String>[];
  BuildVersion previewVersion = const BuildVersion(
    buildName: '1.2.3',
    buildNumber: '45',
  );
  final versionRequests = <List<String>>[];
  Future<BuildVersion> Function(String, List<String>)? versionResponse;

  @override
  Future<BuildVersion> readBuildVersion(
    String projectPath,
    List<String> args,
  ) async {
    versionRequests.add(List.of(args));
    if (versionResponse != null) return versionResponse!(projectPath, args);
    return previewVersion;
  }

  @override
  Future<AppSettings> setBuildPresets(List<BuildPreset> presets) async {
    saved.add(List.of(presets));
    appSettings = AppSettings(buildPresets: presets);
    return appSettings;
  }

  @override
  Future<BuildSnapshot> startBuild(BuildConfig config) async {
    configs.add(config);
    if (failBuildStart) throw Exception('missing flutter');
    if (pendingBuildStart != null) return pendingBuildStart!;
    return snapshot;
  }

  @override
  Future<BuildSnapshot> buildSnapshot(String id) async {
    if (failNextSnapshot) {
      failNextSnapshot = false;
      throw Exception('暂时不可用');
    }
    return snapshot;
  }

  @override
  Future<LogPage> readBuildLogs(
    String id, {
    int afterId = 0,
    int limit = 200,
  }) async {
    readBuildIds.add(id);
    if (failNextLogs) {
      failNextLogs = false;
      throw Exception('日志暂时不可用');
    }
    final page = buildLogs
        .where((entry) => entry.id > afterId)
        .take(limit)
        .toList();
    return LogPage(entries: page, nextAfterId: page.lastOrNull?.id ?? afterId);
  }

  @override
  Future<void> stopBuild(String id) async {
    stopped++;
    finish('cancelled');
  }

  void finish(String state, {String? error}) {
    snapshot = BuildSnapshot(
      id: 'build-1',
      projectPath: '/sample',
      state: state,
      target: 'apk',
      outputDirectory: '/sample/build/app/outputs/flutter-apk',
      error: error,
      version: snapshot.version,
    );
  }

  @override
  Future<void> openBuildOutput(String id) async {
    if (failOpenOutput) throw Exception('Finder unavailable');
    opened.add(id);
    finish('succeeded');
  }
}

Finder field(String name) => find.byKey(Key(name));

Future<void> mountBuild(
  WidgetTester tester,
  BuildBridge bridge, {
  Size size = const Size(1000, 900),
  Brightness brightness = Brightness.light,
  List<String> platforms = const ['android'],
  BuildSnapshot? initialBuild,
  ValueChanged<BuildSnapshot>? onBuildStarted,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: workbenchTheme(brightness),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => BuildDialog(
                bridge: bridge,
                project: Project(
                  name: 'sample',
                  path: '/sample',
                  platforms: platforms,
                ),
                sdkPreference: '/custom/flutter',
                initialBuild: initialBuild,
                onBuildStarted: onBuildStarted,
              ),
            ),
            child: const Text('打开构建'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开构建'));
  if (initialBuild?.active ?? false) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  } else {
    await tester.pumpAndSettle();
  }
}

Future<void> enter(WidgetTester tester, String name, String text) async {
  await tester.ensureVisible(field(name));
  await tester.enterText(field(name), text);
  await tester.pump();
}

void main() {
  testWidgets(
    'version preview reads default and build argument overrides without changing focus',
    (tester) async {
      final bridge = BuildBridge();
      await mountBuild(tester, bridge);
      expect(find.text('构建版本：1.2.3+45'), findsOneWidget);
      expect(bridge.versionRequests, [[]]);
      bridge.versionResponse = (_, args) async {
        expect(args, ['--build-name=2.0.0', '--build-number', '86']);
        return const BuildVersion(buildName: '2.0.0', buildNumber: '86');
      };
      await enter(
        tester,
        'build-args',
        '["--build-name=2.0.0", "--build-number", "86"]',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text('构建版本：2.0.0+86'), findsOneWidget);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(
        tester.widget<TextField>(field('build-args')).controller!.text,
        '["--build-name=2.0.0", "--build-number", "86"]',
      );
    },
  );

  testWidgets(
    'version preview debounces input and rejects stale or invalid argument results',
    (tester) async {
      final bridge = BuildBridge();
      await mountBuild(tester, bridge);
      final old = Completer<BuildVersion>();
      bridge.versionResponse = (_, args) async =>
          args.contains('--build-name=old')
          ? old.future
          : const BuildVersion(buildName: 'new', buildNumber: '50');
      await enter(tester, 'build-args', '["--build-name=old"]');
      await tester.pump(const Duration(milliseconds: 250));
      await enter(tester, 'build-args', '["--build-name=intermediate"]');
      await tester.pump(const Duration(milliseconds: 50));
      await enter(tester, 'build-args', '["--build-name=new"]');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      old.complete(const BuildVersion(buildName: 'old', buildNumber: '10'));
      await tester.pump();
      expect(find.text('构建版本：new+50'), findsOneWidget);
      expect(bridge.versionRequests, [
        [],
        ['--build-name=old'],
        ['--build-name=new'],
      ]);
      await enter(tester, 'build-args', '[123]');
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('构建版本：参数无效'), findsOneWidget);
      expect(find.text('构建版本：new+50'), findsNothing);
      expect(bridge.versionRequests.length, 3);
    },
  );

  testWidgets('version read failure can retry and does not prevent building', (
    tester,
  ) async {
    var failVersion = true;
    final bridge = BuildBridge()
      ..versionResponse = (_, _) async {
        if (failVersion) throw Exception('pubspec unavailable');
        return const BuildVersion(buildName: '3.0.0', buildNumber: '99');
      };
    await mountBuild(tester, bridge);
    expect(find.text('构建版本：读取失败'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(field('build-start')).onPressed,
      isNotNull,
    );
    failVersion = false;
    await tester.ensureVisible(field('build-version-retry'));
    await tester.tap(field('build-version-retry'));
    await tester.pumpAndSettle();
    expect(find.text('构建版本：3.0.0+99'), findsOneWidget);
    failVersion = true;
    await enter(tester, 'build-args', '["--release"]');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.text('构建版本：读取失败'), findsOneWidget);
    await tester.tap(field('build-start'));
    await tester.pump();
    expect(bridge.configs.single.args, ['--release']);
    expect(tester.widget<Text>(field('build-version')).data, '构建版本：1.2.3+45');
    await tester.tap(field('build-close'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'details use historical snapshot version without re-reading project files',
    (tester) async {
      final bridge = BuildBridge()..finish('succeeded');
      bridge.previewVersion = const BuildVersion(
        buildName: '9.0.0',
        buildNumber: '900',
      );
      await mountBuild(tester, bridge, initialBuild: bridge.snapshot);
      expect(tester.widget<Text>(field('build-version')).data, '构建版本：1.2.3+45');
      expect(bridge.versionRequests, isEmpty);
      expect(field('build-version-retry'), findsNothing);
    },
  );

  testWidgets(
    'manual refresh reads changed project version while active task keeps its captured version',
    (tester) async {
      final bridge = BuildBridge();
      await mountBuild(tester, bridge);
      bridge.previewVersion = const BuildVersion(
        buildName: '4.0.0',
        buildNumber: '111',
      );
      await tester.ensureVisible(field('build-version-refresh'));
      await tester.tap(field('build-version-refresh'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(field('build-version')).data,
        '构建版本：4.0.0+111',
      );
      await tester.tap(field('build-start'));
      await tester.pump();
      expect(tester.widget<Text>(field('build-version')).data, '构建版本：1.2.3+45');
      expect(field('build-version-refresh'), findsNothing);
      bridge.previewVersion = const BuildVersion(
        buildName: '5.0.0',
        buildNumber: '222',
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.widget<Text>(field('build-version')).data, '构建版本：1.2.3+45');
      await tester.tap(field('build-stop'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(field('build-version')).data,
        '构建版本：4.0.0+111',
      );
      expect(
        tester.widget<Text>(field('build-snapshot-version')).data,
        '构建版本：1.2.3+45',
      );
    },
  );

  testWidgets(
    'selecting a preset refreshes the version with its exact arguments',
    (tester) async {
      final bridge = BuildBridge()
        ..appSettings = const AppSettings(
          buildPresets: [
            BuildPreset(id: 'first', name: '默认包', target: 'apk'),
            BuildPreset(
              id: 'second',
              name: '另一个版本',
              target: 'apk',
              args: ['--build-number=88'],
            ),
          ],
        )
        ..versionResponse = (_, args) async => BuildVersion(
          buildName: '1.2.3',
          buildNumber: args.contains('--build-number=88') ? '88' : '45',
        );
      await mountBuild(tester, bridge);
      expect(tester.widget<Text>(field('build-version')).data, '构建版本：1.2.3+45');
      await tester.tap(field('build-preset'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('另一个版本'));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(field('build-version')).data, '构建版本：1.2.3+88');
      expect(
        tester.widget<TextField>(field('build-args')).controller!.text,
        '["--build-number=88"]',
      );
    },
  );

  testWidgets(
    'disposing cancels pending debounce and ignores an in-flight version read',
    (tester) async {
      final bridge = BuildBridge();
      await mountBuild(tester, bridge);
      final response = Completer<BuildVersion>();
      bridge.versionResponse = (_, _) => response.future;
      await enter(tester, 'build-args', '["--release"]');
      await tester.pump(const Duration(milliseconds: 250));
      await enter(tester, 'build-args', '["--debug"]');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 250));
      response.complete(
        const BuildVersion(buildName: 'late', buildNumber: '1'),
      );
      await tester.pump();
      expect(bridge.versionRequests, [
        [],
        ['--release'],
      ]);
      expect(field('build-dialog'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'custom preset validates JSON and persists separate build options',
    (tester) async {
      final bridge = BuildBridge();
      await mountBuild(tester, bridge);
      await tester.tap(field('build-target'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Web (web)'));
      await tester.pumpAndSettle();
      await enter(tester, 'build-preset-name', '生产包');
      await enter(tester, 'build-args', '[1]');
      await tester.ensureVisible(field('build-save-preset'));
      await tester.tap(field('build-save-preset'));
      await tester.pumpAndSettle();
      expect(find.textContaining('参数应为 JSON 字符串数组'), findsOneWidget);
      expect(bridge.saved, isEmpty);
      await enter(
        tester,
        'build-args',
        '["--release", "--dart-define=TITLE=hello world"]',
      );
      await enter(tester, 'build-output-directory', 'custom/output');
      await tester.ensureVisible(field('build-save-preset'));
      await tester.tap(field('build-save-preset'));
      await tester.pumpAndSettle();
      expect(bridge.saved.single.single.name, '生产包');
      expect(bridge.saved.single.single.target, 'web');
      expect(bridge.saved.single.single.args, [
        '--release',
        '--dart-define=TITLE=hello world',
      ]);
      expect(bridge.saved.single.single.outputDirectory, 'custom/output');
      await tester.tap(field('build-start'));
      await tester.pump();
      expect(bridge.configs.single.sdkPath, '/custom/flutter');
      expect(bridge.configs.single.args, bridge.saved.single.single.args);
      expect(
        tester.widget<TextButton>(field('build-close')).onPressed,
        isNotNull,
      );
      await tester.tap(field('build-stop'));
      await tester.pumpAndSettle();
      expect(bridge.stopped, 1);
      expect(find.text('构建已停止'), findsOneWidget);
      await tester.tap(field('build-close'));
      await tester.pumpAndSettle();
      expect(field('build-dialog'), findsNothing);
    },
  );

  testWidgets('closing an active build leaves the core task running', (
    tester,
  ) async {
    final bridge = BuildBridge();
    final started = <BuildSnapshot>[];
    await mountBuild(tester, bridge, onBuildStarted: started.add);
    await tester.tap(field('build-start'));
    await tester.pump();
    expect(started.single.id, 'build-1');
    await tester.tap(field('build-close'));
    await tester.pumpAndSettle();
    expect(field('build-dialog'), findsNothing);
    expect(bridge.stopped, 0);
    expect(bridge.snapshot.state, 'running');
    final reads = bridge.readBuildIds.length;
    await tester.pump(const Duration(seconds: 2));
    expect(bridge.readBuildIds.length, reads);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late build start still reports to owner after closing', (
    tester,
  ) async {
    final response = Completer<BuildSnapshot>();
    final bridge = BuildBridge()..pendingBuildStart = response.future;
    final started = <BuildSnapshot>[];
    await mountBuild(tester, bridge, onBuildStarted: started.add);
    await tester.tap(field('build-start'));
    await tester.pump();
    await tester.tap(field('build-close'));
    await tester.pumpAndSettle();
    expect(field('build-dialog'), findsNothing);
    response.complete(bridge.snapshot);
    await tester.pump();
    expect(started.single.id, 'build-1');
    expect(bridge.stopped, 0);
    expect(bridge.readBuildIds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'task details restore core logs and stop without exposing a new build',
    (tester) async {
      final bridge = BuildBridge();
      bridge.buildLogs.add(
        const LogEntry(id: 1, category: 'stdout', text: 'background log'),
      );
      await mountBuild(tester, bridge, initialBuild: bridge.snapshot);
      expect(field('build-preset'), findsNothing);
      expect(field('build-command'), findsNothing);
      expect(field('build-start'), findsNothing);
      expect(find.text('构建详情'), findsOneWidget);
      expect(find.text('background log'), findsOneWidget);
      expect(bridge.readBuildIds, ['build-1']);
      await tester.tap(field('build-stop'));
      await tester.pumpAndSettle();
      expect(bridge.stopped, 1);
      expect(find.text('构建已停止'), findsOneWidget);
      expect(field('build-start'), findsNothing);
    },
  );

  testWidgets('selected preset supports editing and deletion', (tester) async {
    final bridge = BuildBridge()
      ..appSettings = const AppSettings(
        buildPresets: [
          BuildPreset(
            id: 'existing',
            name: '原预设',
            target: 'apk',
            args: ['--release'],
          ),
        ],
      );
    await mountBuild(tester, bridge);
    await enter(tester, 'build-preset-name', '修改后');
    await enter(tester, 'build-args', '["--debug"]');
    await tester.ensureVisible(field('build-save-preset'));
    await tester.tap(field('build-save-preset'));
    await tester.pumpAndSettle();
    expect(bridge.saved.single.single.id, 'existing');
    expect(bridge.saved.single.single.name, '修改后');
    expect(bridge.saved.single.single.args, ['--debug']);
    await tester.tap(field('build-delete-preset'));
    await tester.pumpAndSettle();
    expect(bridge.saved.last, isEmpty);
    expect(find.text('自定义构建'), findsOneWidget);
    expect(field('build-delete-preset'), findsNothing);
  });

  testWidgets(
    'failed start permits retry and failed builds retain log output',
    (tester) async {
      final bridge = BuildBridge()..failBuildStart = true;
      await mountBuild(tester, bridge);
      await tester.tap(field('build-start'));
      await tester.pumpAndSettle();
      expect(find.textContaining('missing flutter'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(field('build-start')).onPressed,
        isNotNull,
      );
      bridge.failBuildStart = false;
      bridge.finish('failed', error: 'compiler failed');
      bridge.buildLogs.add(
        const LogEntry(id: 1, category: 'stderr', text: 'compiler diagnostic'),
      );
      await tester.tap(field('build-start'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(field('build-logs'));
      expect(find.text('构建失败'), findsOneWidget);
      expect(find.text('compiler diagnostic'), findsOneWidget);
      expect(field('build-open-output'), findsNothing);
    },
  );

  testWidgets(
    'successful build drains final pages then allows repeat and opening output',
    (tester) async {
      final bridge = BuildBridge();
      bridge.finish('succeeded');
      bridge.buildLogs.addAll(
        List.generate(
          205,
          (i) => LogEntry(
            id: i + 1,
            category: 'stdout',
            text: 'build line ${i + 1}',
          ),
        ),
      );
      await mountBuild(tester, bridge);
      await tester.tap(field('build-start'));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(field('build-start')).onPressed,
        isNull,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.text('构建成功'), findsOneWidget);
      await tester.ensureVisible(field('build-logs'));
      await tester.pump();
      expect(find.text('build line 205'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(field('build-start')).onPressed,
        isNotNull,
      );
      await tester.tap(field('build-open-output'));
      await tester.pumpAndSettle();
      expect(bridge.opened, ['build-1']);
    },
  );

  testWidgets(
    'opening output retry clears manual error and refreshed automatic warning',
    (tester) async {
      final bridge = BuildBridge()..failOpenOutput = true;
      bridge.finish('succeeded', error: '自动打开产物目录失败');
      await mountBuild(tester, bridge);
      await tester.tap(field('build-start'));
      await tester.pumpAndSettle();
      expect(find.text('自动打开产物目录失败'), findsOneWidget);
      await tester.tap(field('build-open-output'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Finder unavailable'), findsOneWidget);
      bridge.failOpenOutput = false;
      await tester.tap(field('build-open-output'));
      await tester.pumpAndSettle();
      expect(bridge.opened, ['build-1']);
      expect(find.textContaining('Finder unavailable'), findsNothing);
      expect(find.text('自动打开产物目录失败'), findsNothing);
      expect(find.text('构建成功'), findsOneWidget);
    },
  );

  testWidgets('terminal status survives log failure and retries final logs', (
    tester,
  ) async {
    final bridge = BuildBridge()..failNextLogs = true;
    bridge.finish('succeeded');
    bridge.buildLogs.add(
      const LogEntry(id: 1, category: 'stdout', text: 'last output'),
    );
    await mountBuild(tester, bridge);
    await tester.tap(field('build-start'));
    await tester.pump();
    expect(find.text('构建成功'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    await tester.ensureVisible(field('build-logs'));
    expect(find.text('last output'), findsOneWidget);
    expect(find.textContaining('日志暂时不可用'), findsNothing);
    expect(
      tester.widget<FilledButton>(field('build-start')).onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'minimum window keeps build actions visible and content scrollable',
    (tester) async {
      final bridge = BuildBridge()..finish('succeeded');
      await mountBuild(tester, bridge, size: const Size(560, 500));
      expect(find.text('构建应用'), findsOneWidget);
      expect(field('build-start').hitTestable(), findsOneWidget);
      await tester.tap(field('build-start'));
      await tester.pumpAndSettle();
      expect(field('build-open-output').hitTestable(), findsOneWidget);
      expect(field('build-close').hitTestable(), findsOneWidget);
      await tester.ensureVisible(field('build-command'));
      expect(field('build-command').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resizing across build columns preserves name input focus', (
    tester,
  ) async {
    await mountBuild(tester, BuildBridge());
    await enter(tester, 'build-preset-name', '生产包');
    final focus = tester
        .widget<TextField>(field('build-preset-name'))
        .focusNode!;
    expect(focus.hasFocus, isTrue);
    tester.view.physicalSize = const Size(560, 900);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field('build-preset-name')).focusNode,
      same(focus),
    );
    expect(focus.hasFocus, isTrue);
    expect(
      tester.widget<TextField>(field('build-preset-name')).controller!.text,
      '生产包',
    );
    tester.testTextInput.enterText('生产包 Release');
    await tester.pump();
    tester.view.physicalSize = const Size(1000, 900);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(
      tester.widget<TextField>(field('build-preset-name')).controller!.text,
      '生产包 Release',
    );
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'narrow $brightness layout selects preset matching project platform',
      (tester) async {
        final bridge = BuildBridge()
          ..appSettings = const AppSettings(
            buildPresets: [
              BuildPreset(id: 'apk', name: 'Android 发布', target: 'apk'),
              BuildPreset(
                id: 'web',
                name: 'Web 发布',
                target: 'web',
                args: ['--release'],
              ),
            ],
          );
        await mountBuild(
          tester,
          bridge,
          size: const Size(440, 760),
          brightness: brightness,
          platforms: ['web'],
        );
        expect(
          find.descendant(
            of: field('build-preset'),
            matching: find.text('Web 发布'),
          ),
          findsOneWidget,
        );
        expect(find.text('Web (web)'), findsOneWidget);
        expect(find.text('构建版本：1.2.3+45'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(field('build-close'));
        await tester.pumpAndSettle();
      },
    );
  }
}
