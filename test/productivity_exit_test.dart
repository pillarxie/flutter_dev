import 'dart:async';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';
import 'workbench_test.dart' show FakeBridge, mount, addProject, key, running;

class _UnavailableTestsBridge extends FakeBridge {
  @override
  Future<List<TestRunSnapshot>> listTestRuns() async =>
      throw StateError('测试服务读取失败');
}

void main() {
  testWidgets('failed test inventory cancels exit with visible feedback', (
    tester,
  ) async {
    final bridge = _UnavailableTestsBridge();
    await mount(tester, bridge);
    final exiting = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    expect(await exiting, AppExitResponse.cancel);
    expect(find.textContaining('读取后台测试失败，退出已取消'), findsOneWidget);
    expect(bridge.shutdowns, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('exit waits for an already submitted launch before shutdown', (
    tester,
  ) async {
    final pending = Completer<Session>();
    final bridge = FakeBridge()..startResponse = () => pending.future;
    await mount(tester, bridge);
    await addProject(tester, '/sample');
    await tester.tap(key('run-project'));
    await tester.pump();
    await tester.pump();
    expect(bridge.starts, 1);
    final exiting = tester.binding.handleRequestAppExit();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('停止任务并退出'));
    await tester.pump();
    expect(bridge.shutdowns, 0);
    pending.complete(running());
    await tester.pumpAndSettle();
    expect(await exiting, AppExitResponse.exit);
    expect(bridge.shutdowns, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'exit prevents a launch waiting on configuration persistence from registering late',
    (tester) async {
      final bridge = FakeBridge();
      await mount(tester, bridge);
      await addProject(tester, '/sample');
      final saved = Completer<AppSettings>();
      bridge.preferencesResponse = (_) => saved.future;
      await tester.tap(key('run-project'));
      await tester.pump();
      await tester.pump();
      expect(bridge.preferenceSaves, isNotEmpty);
      expect(bridge.starts, 0);
      final exiting = tester.binding.handleRequestAppExit();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.pump();
      expect(bridge.starts, 0);
      saved.complete(bridge.appSettings);
      await tester.pumpAndSettle();
      expect(await exiting, AppExitResponse.exit);
      expect(bridge.starts, 0);
      expect(bridge.shutdowns, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
