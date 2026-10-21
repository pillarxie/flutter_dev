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
}
