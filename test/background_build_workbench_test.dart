import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';

import 'build_dialog_test.dart' show BuildBridge;
import 'workbench_test.dart' show addProject, key, mount;

class BackgroundBuildBridge extends BuildBridge {
  bool hasTask = false;
  int listReads = 0, buildLogReads = 0;
  Completer<BuildSnapshot>? pendingStart;
  Future<List<BuildSnapshot>> Function()? listResponse;

  @override
  Future<BuildSnapshot> startBuild(BuildConfig config) async {
    if (pendingStart case final pending?) {
      configs.add(config);
      snapshot = await pending.future;
    } else {
      snapshot = await super.startBuild(config);
    }
    hasTask = true;
    return snapshot;
  }

  @override
  Future<List<BuildSnapshot>> listBuilds() async {
    listReads++;
    return listResponse == null ? [if (hasTask) snapshot] : listResponse!();
  }

  @override
  Future<LogPage> readBuildLogs(String id, {int afterId = 0, int limit = 200}) {
    buildLogReads++;
    return super.readBuildLogs(id, afterId: afterId, limit: limit);
  }
}

Future<void> startBuild(WidgetTester tester) async {
  await tester.tap(key('build-project'));
  await tester.pumpAndSettle();
  await tester.tap(key('build-start'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets(
    'closed build stays discoverable across projects and finishes in background',
    (tester) async {
      final bridge = BackgroundBuildBridge()
        ..buildLogs.add(
          const LogEntry(id: 1, category: 'stdout', text: '后台编译日志'),
        );
      await mount(tester, bridge, size: const Size(560, 850));
      await addProject(tester, '/sample');
      await startBuild(tester);
      await tester.tap(key('build-close'));
      await tester.pumpAndSettle();
      expect(key('build-dialog'), findsNothing);
      expect(bridge.stopped, 0);
      expect(key('active-build-count'), findsOneWidget);

      final reads = bridge.buildLogReads;
      await tester.pump(const Duration(seconds: 2));
      expect(bridge.buildLogReads, reads);
      await addProject(tester, '/other');
      await tester.tap(key('build-tasks'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(key('build-task-build-1'), findsOneWidget);
      await tester.tap(key('build-task-build-1'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.ensureVisible(key('build-logs'));
      await tester.pump();
      expect(find.text('构建详情'), findsOneWidget);
      expect(find.text('后台编译日志'), findsOneWidget);
      expect(key('build-preset'), findsNothing);
      await tester.tap(key('build-close'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(key('build-tasks-dialog'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: key('build-tasks-dialog'),
          matching: find.text('关闭'),
        ),
      );
      await tester.pumpAndSettle();

      bridge.finish('succeeded');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(key('active-build-count'), findsNothing);
      final listReads = bridge.listReads;
      await tester.pump(const Duration(seconds: 3));
      expect(bridge.listReads, listReads);
      await tester.tap(key('build-tasks'));
      await tester.pumpAndSettle();
      await tester.tap(key('build-task-build-1'));
      await tester.pumpAndSettle();
      expect(find.text('构建成功'), findsOneWidget);
      expect(key('build-open-output'), findsOneWidget);
      expect(bridge.stopped, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'dismissed pending start is tracked and exit waits before cleanup',
    (tester) async {
      final bridge = BackgroundBuildBridge()
        ..pendingStart = Completer<BuildSnapshot>();
      await mount(tester, bridge);
      await addProject(tester, '/sample');
      await startBuild(tester);
      await tester.tap(key('build-close'));
      await tester.pumpAndSettle();
      final exit = tester.binding.handleRequestAppExit();
      await tester.pumpAndSettle();
      expect(find.text('退出 Flutter Dev？'), findsOneWidget);
      await tester.tap(find.text('停止任务并退出'));
      await tester.pumpAndSettle();
      expect(bridge.shutdowns, 0);
      bridge.pendingStart!.complete(bridge.snapshot);
      await tester.pumpAndSettle();
      expect(await exit, AppExitResponse.exit);
      expect(bridge.shutdowns, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('late pre-start task list cannot remove a newly started task', (
    tester,
  ) async {
    final stale = Completer<List<BuildSnapshot>>();
    final bridge = BackgroundBuildBridge()..listResponse = () => stale.future;
    await mount(tester, bridge);
    await addProject(tester, '/sample');
    await startBuild(tester);
    await tester.tap(key('build-close'));
    await tester.pumpAndSettle();
    stale.complete(const []);
    await tester.pump();
    expect(key('active-build-count'), findsOneWidget);
    bridge.listResponse = null;
    await tester.pump(const Duration(seconds: 1));
    expect(key('active-build-count'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    final reads = bridge.listReads;
    await tester.pump(const Duration(seconds: 2));
    expect(bridge.listReads, reads);
    expect(tester.takeException(), isNull);
  });
}
