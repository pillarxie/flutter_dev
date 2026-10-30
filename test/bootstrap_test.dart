import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/app.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';
import 'package:flutter_dev/main.dart';

import 'workbench_test.dart' show FakeBridge;

void main() {
  testWidgets('loading shell paints before native initialization starts', (
    tester,
  ) async {
    final pending = Completer<WorkbenchBridge>();
    var calls = 0;
    tester.binding.addPostFrameCallback((_) {
      expect(calls, 0);
      expect(find.text('正在加载运行核心…'), findsOneWidget);
    });
    await tester.pumpWidget(
      FlutterDevBootstrap(
        initialize: () {
          calls++;
          return pending.future;
        },
      ),
    );
    expect(calls, 1);
    expect(find.text('正在加载运行核心…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    pending.completeError(StateError('late native failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('native failure can retry and open the workbench', (
    tester,
  ) async {
    final bridge = FakeBridge();
    addTearDown(bridge.controller.close);
    var calls = 0;
    await tester.pumpWidget(
      FlutterDevBootstrap(
        initialize: () {
          calls++;
          if (calls == 1) throw StateError('DLL could not load');
          return Future.value(bridge);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Rust 核心加载失败'), findsOneWidget);
    expect(find.textContaining('DLL could not load'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(FlutterDevApp), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'late successful initialization does not reopen a removed shell',
    (tester) async {
      final bridge = FakeBridge();
      addTearDown(bridge.controller.close);
      final pending = Completer<WorkbenchBridge>();
      await tester.pumpWidget(
        FlutterDevBootstrap(initialize: () => pending.future),
      );
      await tester.pumpWidget(const SizedBox());
      pending.complete(bridge);
      await tester.pump();
      expect(find.byType(FlutterDevApp), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
