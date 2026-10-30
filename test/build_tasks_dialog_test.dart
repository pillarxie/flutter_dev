import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';
import 'package:flutter_dev/core/presentation/workbench_theme.dart';
import 'package:flutter_dev/features/build/build_tasks_dialog.dart';

import 'workbench_test.dart' show FakeBridge;

class TaskBridge extends FakeBridge {
  final tasks = <String, BuildSnapshot>{
    'active': const BuildSnapshot(
      id: 'active',
      projectPath: '/projects/active-app',
      state: 'running',
      target: 'apk',
      version: BuildVersion(buildName: '1.2.3', buildNumber: '45'),
    ),
    'finished': const BuildSnapshot(
      id: 'finished',
      projectPath: r'C:\projects\finished-app',
      state: 'succeeded',
      target: 'windows',
      version: BuildVersion(buildName: '1.0.0', buildNumber: '7'),
      outputDirectory: r'C:\projects\finished-app\build\windows',
    ),
  };
  final reads = <String>[];
  final stopped = <String>[];
  int cleanupCalls = 0;
  Future<BuildCacheCleanupResult> Function()? cleanup;

  @override
  Future<BuildCacheCleanupResult> clearBuildCache() async {
    cleanupCalls++;
    return await cleanup?.call() ?? const BuildCacheCleanupResult();
  }

  @override
  Future<BuildSnapshot> buildSnapshot(String id) async => tasks[id]!;

  @override
  Future<LogPage> readBuildLogs(
    String id, {
    int afterId = 0,
    int limit = 200,
  }) async {
    reads.add(id);
    return LogPage(
      entries: afterId == 0
          ? [LogEntry(id: 1, category: 'stdout', text: '$id stored log')]
          : [],
      nextAfterId: 1,
    );
  }

  @override
  Future<void> stopBuild(String id) async {
    stopped.add(id);
    final task = tasks[id]!;
    tasks[id] = BuildSnapshot(
      id: task.id,
      projectPath: task.projectPath,
      state: 'cancelled',
      target: task.target,
      version: task.version,
    );
  }
}

Finder control(String key) => find.byKey(Key(key));

Future<void> mountTasks(
  WidgetTester tester,
  TaskBridge bridge,
  ValueNotifier<List<BuildSnapshot>> builds,
  Future<void> Function() onRefresh, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(560, 700);
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
              builder: (_) => BuildTasksDialog(
                bridge: bridge,
                builds: builds,
                onRefresh: onRefresh,
              ),
            ),
            child: const Text('打开任务'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开任务'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      '$brightness at 560px switches active and completed task details',
      (tester) async {
        final bridge = TaskBridge();
        final builds = ValueNotifier(bridge.tasks.values.toList());
        addTearDown(builds.dispose);
        var refreshes = 0;
        await mountTasks(tester, bridge, builds, () async {
          refreshes++;
          builds.value = bridge.tasks.values.toList();
        }, brightness: brightness);
        expect(find.text('active-app'), findsOneWidget);
        expect(find.text('finished-app'), findsOneWidget);
        expect(find.text('apk · 正在构建'), findsOneWidget);
        expect(find.text('windows · 构建成功'), findsOneWidget);
        expect(find.text('构建版本：1.2.3+45'), findsOneWidget);
        expect(find.text('构建版本：1.0.0+7'), findsOneWidget);
        expect(bridge.reads, isEmpty);
        await tester.tap(control('build-task-active'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('active stored log'), findsOneWidget);
        expect(control('build-preset'), findsNothing);
        await tester.tap(control('build-stop'));
        await tester.pumpAndSettle();
        expect(bridge.stopped, ['active']);
        await tester.tap(control('build-close'));
        await tester.pumpAndSettle();
        expect(control('build-tasks-dialog'), findsOneWidget);
        expect(find.text('apk · 已停止'), findsOneWidget);
        await tester.tap(control('build-task-finished'));
        await tester.pumpAndSettle();
        expect(find.text('finished stored log'), findsOneWidget);
        expect(
          tester.widget<Text>(control('build-version')).data,
          '构建版本：1.0.0+7',
        );
        expect(find.text('active stored log'), findsNothing);
        expect(control('build-open-output'), findsOneWidget);
        expect(control('build-start'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(control('build-close'));
        await tester.pumpAndSettle();
        expect(refreshes, 3);
        await tester.tap(control('build-tasks-close'));
        await tester.pumpAndSettle();
        expect(control('build-tasks-dialog'), findsNothing);
      },
    );
  }

  testWidgets(
    'old tasks without version show unread instead of current project version',
    (tester) async {
      final bridge = TaskBridge();
      final task = bridge.tasks['finished']!;
      bridge.tasks['finished'] = BuildSnapshot(
        id: task.id,
        projectPath: task.projectPath,
        state: task.state,
        target: task.target,
      );
      final builds = ValueNotifier(bridge.tasks.values.toList());
      addTearDown(builds.dispose);
      await mountTasks(tester, bridge, builds, () async {});
      expect(
        tester.widget<Text>(control('build-task-version-finished')).data,
        '构建版本：未读取',
      );
      await tester.tap(control('build-task-finished'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(control('build-version')).data, '构建版本：未读取');
    },
  );

  testWidgets(
    'empty task list supports loading, failure and refresh recovery',
    (tester) async {
      final bridge = TaskBridge();
      final builds = ValueNotifier(<BuildSnapshot>[]);
      addTearDown(builds.dispose);
      final firstRefresh = Completer<void>();
      var refreshes = 0;
      await mountTasks(tester, bridge, builds, () async {
        refreshes++;
        if (refreshes == 1) await firstRefresh.future;
        if (refreshes == 2) throw Exception('core unavailable');
      });
      expect(find.text('正在读取构建任务'), findsOneWidget);
      firstRefresh.complete();
      await tester.pumpAndSettle();
      expect(find.text('暂无构建任务'), findsOneWidget);
      await tester.tap(control('build-tasks-refresh'));
      await tester.pumpAndSettle();
      expect(find.textContaining('core unavailable'), findsOneWidget);
      await tester.tap(control('build-tasks-refresh'));
      await tester.pumpAndSettle();
      expect(find.textContaining('core unavailable'), findsNothing);
      builds.value = bridge.tasks.values.toList();
      await tester.pumpAndSettle();
      expect(find.text('active-app'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty task list can cancel cache cleanup', (tester) async {
    final bridge = TaskBridge();
    final builds = ValueNotifier(<BuildSnapshot>[]);
    addTearDown(builds.dispose);
    await mountTasks(tester, bridge, builds, () async {});
    await tester.tap(control('build-cache-clear'));
    await tester.pumpAndSettle();
    expect(find.text('清除构建缓存？'), findsOneWidget);
    expect(find.textContaining('所有已导入项目的 build 目录'), findsOneWidget);
    expect(find.textContaining('无法撤销'), findsOneWidget);
    await tester.tap(control('build-cache-cancel'));
    await tester.pumpAndSettle();
    expect(bridge.cleanupCalls, 0);
    expect(find.text('暂无构建任务'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      '$brightness at 560px cleans cache and refreshes obsolete output actions',
      (tester) async {
        final bridge = TaskBridge();
        final pending = Completer<BuildCacheCleanupResult>();
        bridge.cleanup = () => pending.future;
        final builds = ValueNotifier(bridge.tasks.values.toList());
        addTearDown(builds.dispose);
        var refreshes = 0;
        await mountTasks(tester, bridge, builds, () async {
          refreshes++;
          builds.value = bridge.tasks.values.toList();
        }, brightness: brightness);
        await tester.tap(control('build-cache-clear'));
        await tester.pumpAndSettle();
        await tester.tap(control('build-cache-confirm'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(bridge.cleanupCalls, 1);
        expect(find.text('正在清除构建缓存…'), findsOneWidget);
        expect(
          tester.widget<TextButton>(control('build-cache-clear')).onPressed,
          isNull,
        );
        expect(
          tester.widget<IconButton>(control('build-tasks-refresh')).onPressed,
          isNull,
        );
        expect(
          tester.widget<ListTile>(control('build-task-finished')).onTap,
          isNull,
        );
        final finished = bridge.tasks['finished']!;
        bridge.tasks['finished'] = BuildSnapshot(
          id: finished.id,
          projectPath: finished.projectPath,
          state: finished.state,
          target: finished.target,
          version: finished.version,
        );
        pending.complete(
          const BuildCacheCleanupResult(
            deletedPaths: [
              '/projects/active-app/build',
              r'C:\projects\finished-app\build',
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(refreshes, 2);
        expect(find.text('已清除 2 个构建缓存路径。'), findsOneWidget);
        await tester.tap(control('build-task-finished'));
        await tester.pumpAndSettle();
        expect(control('build-open-output'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('cleanup errors display individual paths and allow retry', (
    tester,
  ) async {
    final bridge = TaskBridge();
    final builds = ValueNotifier(<BuildSnapshot>[]);
    addTearDown(builds.dispose);
    var refreshes = 0;
    bridge.cleanup = () async => const BuildCacheCleanupResult(
      deletedPaths: ['/projects/app/build'],
      errors: [
        '/projects/other/build: permission denied',
        '/custom/packages/app.apk: file in use',
      ],
    );
    await mountTasks(tester, bridge, builds, () async => refreshes++);
    await tester.tap(control('build-cache-clear'));
    await tester.pumpAndSettle();
    await tester.tap(control('build-cache-confirm'));
    await tester.pumpAndSettle();
    expect(find.text('已清除 1 个构建缓存路径。 2 项清理失败，可重试。'), findsOneWidget);
    expect(
      find.text('/projects/other/build: permission denied'),
      findsOneWidget,
    );
    expect(find.text('/custom/packages/app.apk: file in use'), findsOneWidget);
    expect(refreshes, 2);
    bridge.cleanup = () async => const BuildCacheCleanupResult(
      deletedPaths: ['/projects/other/build', '/custom/packages/app.apk'],
    );
    await tester.tap(control('build-cache-clear'));
    await tester.pumpAndSettle();
    await tester.tap(control('build-cache-confirm'));
    await tester.pumpAndSettle();
    expect(bridge.cleanupCalls, 2);
    expect(find.text('已清除 2 个构建缓存路径。'), findsOneWidget);
    expect(find.textContaining('permission denied'), findsNothing);
    expect(refreshes, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cleanup failure stays visible and can be retried', (
    tester,
  ) async {
    final bridge = TaskBridge();
    bridge.cleanup = () async => throw Exception('请先结束活动任务');
    final builds = ValueNotifier(<BuildSnapshot>[]);
    addTearDown(builds.dispose);
    await mountTasks(tester, bridge, builds, () async {});
    await tester.tap(control('build-cache-clear'));
    await tester.pumpAndSettle();
    await tester.tap(control('build-cache-confirm'));
    await tester.pumpAndSettle();
    expect(find.textContaining('清除构建缓存失败：Exception: 请先结束活动任务'), findsOneWidget);
    expect(
      tester.widget<TextButton>(control('build-cache-clear')).onPressed,
      isNotNull,
    );
    bridge.cleanup = () async => const BuildCacheCleanupResult();
    await tester.tap(control('build-cache-clear'));
    await tester.pumpAndSettle();
    await tester.tap(control('build-cache-confirm'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请先结束活动任务'), findsNothing);
    expect(find.text('已清除 0 个构建缓存路径。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing during cleanup ignores its late result safely', (
    tester,
  ) async {
    final bridge = TaskBridge();
    final pending = Completer<BuildCacheCleanupResult>();
    bridge.cleanup = () => pending.future;
    final builds = ValueNotifier(<BuildSnapshot>[]);
    addTearDown(builds.dispose);
    var refreshes = 0;
    await mountTasks(tester, bridge, builds, () async => refreshes++);
    await tester.tap(control('build-cache-clear'));
    await tester.pumpAndSettle();
    await tester.tap(control('build-cache-confirm'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(control('build-tasks-close'));
    await tester.pumpAndSettle();
    pending.complete(
      const BuildCacheCleanupResult(deletedPaths: ['/app/build']),
    );
    await tester.pumpAndSettle();
    expect(control('build-tasks-dialog'), findsNothing);
    expect(refreshes, 1);
    expect(tester.takeException(), isNull);
  });
}
