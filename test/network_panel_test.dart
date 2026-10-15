import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';
import 'package:flutter_dev/core/presentation/workbench_theme.dart';
import 'package:flutter_dev/features/devtools/network_panel.dart';

import 'workbench_test.dart' show FakeBridge;

const _session = Session(
  id: 'one',
  generation: 1,
  state: 'running',
  projectPath: '/app',
  deviceId: 'macos',
  mode: 'debug',
  serviceUri: 'ws://localhost:123/ws',
);

class NetworkFake extends FakeBridge {
  final calls =
      <({String session, String method, Map<String, dynamic> args})>[];
  Future<Map<String, dynamic>> Function(String, String, Map<String, dynamic>)?
  handler;
  int timestamp = 200;
  Map<String, dynamic> ref = {
    'id': 'request-1',
    'method': 'POST',
    'uri': 'https://example.test/search?q=%E4%B8%AD%E6%96%87&tag=one&tag=two',
    'startTime': 100,
    'request': {
      'headers': {
        'content-type': ['application/x-www-form-urlencoded'],
      },
    },
    'response': {
      'statusCode': 200,
      'endTime': 150,
      'contentLength': 12,
      'headers': {
        'content-type': ['application/json'],
      },
    },
  };
  @override
  Future<Map<String, dynamic>> networkRequest(
    String id,
    String method,
    Map<String, dynamic> args,
  ) async {
    calls.add((session: id, method: method, args: Map.of(args)));
    if (handler != null) return handler!(id, method, args);
    return response(method, args);
  }

  Map<String, dynamic> response(
    String method,
    Map<String, dynamic> args,
  ) => switch (method) {
    'getVM' => {
      'isolates': [
        {'id': 'isolates/1'},
      ],
    },
    'getIsolate' => {
      'extensionRPCs': ['ext.dart.io.getHttpProfile'],
    },
    'ext.dart.io.getVersion' => {'major': 4, 'minor': 0},
    'ext.dart.io.httpEnableTimelineLogging' => {'enabled': true},
    'ext.dart.io.getHttpProfile' => {
      'timestamp': timestamp++,
      'requests': [ref],
    },
    'ext.dart.io.getHttpProfileRequest' => {
      ...ref,
      'requestBody': utf8.encode(
        'payload=%7B%22name%22%3A%22%E4%B8%AD%E6%96%87%22%2C%22page%22%3A1%7D&tag=first&tag=second',
      ),
      'responseBody': utf8.encode('{"ok":true}'),
    },
    _ => {},
  };
}

Future<void> _mount(
  WidgetTester tester,
  NetworkFake bridge, {
  Session? session = _session,
  Size size = const Size(1100, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: workbenchTheme(Brightness.light),
      home: Scaffold(
        body: NetworkPanel(bridge: bridge, session: session),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  for (final width in [1100.0, 420.0]) {
    testWidgets(
      'new requests keep details geometry, scroll and raw mode stable at ${width.toInt()}px',
      (tester) async {
        final bridge = NetworkFake();
        final detail = {
          ...bridge.response('ext.dart.io.getHttpProfileRequest', {}),
          'requestBody': utf8.encode(
            'payload=${Uri.encodeQueryComponent(jsonEncode({'items': List.generate(100, (index) => 'request item $index')}))}&tag=first&tag=second',
          ),
        };
        bridge.handler = (id, method, args) async =>
            method == 'ext.dart.io.getHttpProfileRequest'
            ? detail
            : bridge.response(method, args);
        await _mount(tester, bridge, size: Size(width, 900));
        await tester.tap(find.byType(ListTile).first);
        await tester.pump();
        await tester.pump();
        await tester.tap(find.text('原始').first);
        await tester.pump();
        final details = find.byKey(
          const ValueKey('network-details-isolates/1/request-1'),
        );
        final contentScroll = find.byKey(
          const ValueKey(
            'network-details-scroll-isolates/1/request-1-parameters',
          ),
        );
        await tester.drag(contentScroll, const Offset(0, -120));
        await tester.pumpAndSettle();
        final scroll = tester.state<ScrollableState>(
          find
              .descendant(of: contentScroll, matching: find.byType(Scrollable))
              .first,
        );
        final rect = tester.getRect(details);
        final offset = scroll.position.pixels;
        expect(offset, greaterThan(0));
        await tester.tap(
          find.byKey(const ValueKey('network-detail-tab-headers')),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('network-detail-tab-parameters')),
        );
        await tester.pump();
        expect(scroll.position.pixels, offset);
        final pending = Completer<Map<String, dynamic>>();
        bridge.handler = (id, method, args) async =>
            method == 'ext.dart.io.getHttpProfile'
            ? pending.future
            : bridge.response(method, args);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(tester.getRect(details), rect);
        expect(scroll.position.pixels, offset);
        pending.complete({
          'timestamp': 300,
          'requests': [
            {
              ...bridge.ref,
              'id': 'new-request',
              'uri': 'https://new.test/',
              'startTime': 250,
            },
          ],
        });
        await tester.pump();
        await tester.pump();
        expect(find.text('2 / 500 条'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(tester.getRect(details), rect);
        expect(scroll.position.pixels, offset);
        scroll.position.jumpTo(0);
        await tester.pump();
        expect(find.byTooltip('复制Query 参数原始内容'), findsOneWidget);
        expect(
          bridge.calls.where(
            (call) => call.method == 'ext.dart.io.getHttpProfileRequest',
          ),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'detail tabs separate content and preserve raw mode when returning to parameters',
    (tester) async {
      final bridge = NetworkFake();
      bridge.ref = {
        ...bridge.ref,
        'request': {
          'headers': {
            'content-type': ['application/x-www-form-urlencoded'],
            'x-trace': ['first-trace', 'second-trace'],
          },
        },
      };
      await _mount(tester, bridge);
      await tester.tap(find.byType(ListTile).first);
      await tester.pump();
      await tester.pump();
      final headerTab = find.byKey(
        const ValueKey('network-detail-tab-headers'),
      );
      final parameterTab = find.byKey(
        const ValueKey('network-detail-tab-parameters'),
      );
      final responseTab = find.byKey(
        const ValueKey('network-detail-tab-response'),
      );
      expect(
        tester.getCenter(headerTab).dx,
        lessThan(tester.getCenter(parameterTab).dx),
      );
      expect(
        tester.getCenter(parameterTab).dx,
        lessThan(tester.getCenter(responseTab).dx),
      );
      expect(find.text('Query 参数'), findsOneWidget);
      expect(find.text('响应正文'), findsNothing);
      await tester.tap(find.text('原始').first);
      await tester.pump();
      final originalQuery = bridge.ref['uri'].toString().split('?').last;
      expect(find.text(originalQuery), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('network-detail-tab-headers')),
      );
      await tester.pump();
      expect(find.text('first-trace'), findsOneWidget);
      expect(find.text('second-trace'), findsOneWidget);
      expect(find.text('x-trace'), findsNWidgets(2));
      expect(find.text('Query 参数'), findsNothing);
      expect(find.text('响应 Headers'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('network-detail-tab-response')),
      );
      await tester.pump();
      expect(find.text('{\n  "ok": true\n}'), findsOneWidget);
      expect(find.text('响应 Headers'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('network-detail-tab-parameters')),
      );
      await tester.pump();
      expect(find.text(originalQuery), findsOneWidget);
      expect(find.byTooltip('复制Query 参数原始内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'lazy detail formats encoded query and form JSON, raw and copy retain original',
    (tester) async {
      final bridge = NetworkFake();
      await _mount(tester, bridge);
      expect(
        bridge.calls.where(
          (c) => c.method == 'ext.dart.io.getHttpProfileRequest',
        ),
        isEmpty,
      );
      final enable = bridge.calls.firstWhere(
        (c) => c.method == 'ext.dart.io.httpEnableTimelineLogging',
      );
      expect(enable.args['enabled'], isTrue);
      await tester.tap(find.byType(ListTile).first);
      await tester.pump();
      await tester.pump();
      expect(find.text('中文'), findsOneWidget);
      expect(find.text('"中文"'), findsOneWidget);
      expect(find.text('page:'), findsOneWidget);
      expect(find.text('tag'), findsNWidgets(4));
      await tester.tap(find.text('原始').at(1));
      await tester.pump();
      final raw =
          'payload=%7B%22name%22%3A%22%E4%B8%AD%E6%96%87%22%2C%22page%22%3A1%7D&tag=first&tag=second';
      expect(find.text(raw), findsOneWidget);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      await tester.tap(find.byTooltip('复制完整请求 URL'));
      expect(copied, bridge.ref['uri']);
      await tester.tap(find.byTooltip('复制请求正文原始内容'));
      expect(copied, raw);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'polling is serialized, pause stops automatic reads, clearing hides retained requests',
    (tester) async {
      final bridge = NetworkFake();
      await _mount(tester, bridge);
      final pending = Completer<Map<String, dynamic>>();
      bridge.handler = (id, method, args) async =>
          method == 'ext.dart.io.getHttpProfile'
          ? pending.future
          : bridge.response(method, args);
      await tester.pump(const Duration(seconds: 1));
      final count = bridge.calls.length;
      await tester.pump(const Duration(seconds: 5));
      expect(bridge.calls.length, count);
      await tester.tap(find.byKey(const ValueKey('network-pause')));
      pending.complete({
        'timestamp': 250,
        'requests': [bridge.ref],
      });
      await tester.pump();
      bridge.handler = null;
      await tester.pump(const Duration(seconds: 5));
      expect(bridge.calls.length, count);
      await tester.tap(find.byKey(const ValueKey('network-clear')));
      await tester.tap(find.byKey(const ValueKey('network-refresh')));
      await tester.pump();
      expect(find.byType(ListTile), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late previous-session profile and details cannot contaminate the next session',
    (tester) async {
      final bridge = NetworkFake();
      final pending = Completer<Map<String, dynamic>>();
      bridge.handler = (id, method, args) async =>
          id == 'one' && method == 'ext.dart.io.getHttpProfile'
          ? pending.future
          : bridge.response(method, args);
      await _mount(tester, bridge);
      const next = Session(
        id: 'two',
        generation: 1,
        state: 'running',
        projectPath: '/other',
        deviceId: 'macos',
        mode: 'debug',
        serviceUri: 'ws://localhost:456/ws',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: workbenchTheme(Brightness.light),
          home: Scaffold(
            body: NetworkPanel(bridge: bridge, session: next),
          ),
        ),
      );
      pending.complete({
        'timestamp': 300,
        'requests': [
          {...bridge.ref, 'uri': 'https://old.test/'},
        ],
      });
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('old.test'), findsNothing);
      expect(find.byType(ListTile), findsOneWidget);
      final detail = Completer<Map<String, dynamic>>();
      bridge.handler = (id, method, args) async =>
          method == 'ext.dart.io.getHttpProfileRequest'
          ? detail.future
          : bridge.response(method, args);
      await tester.tap(find.byType(ListTile));
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          theme: workbenchTheme(Brightness.light),
          home: Scaffold(
            body: NetworkPanel(bridge: bridge, session: _session),
          ),
        ),
      );
      detail.complete({...bridge.ref, 'uri': 'https://late-detail.test/'});
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('late-detail.test'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'narrow layout opens details with back navigation and errors recover',
    (tester) async {
      final bridge = NetworkFake();
      await _mount(tester, bridge, size: const Size(420, 900));
      await tester.tap(find.byType(ListTile));
      await tester.pump();
      await tester.pump();
      expect(find.text('返回请求列表'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('返回请求列表'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('network-search')),
        'missing',
      );
      await tester.pump();
      expect(find.text('没有匹配的请求'), findsOneWidget);
      bridge.handler = (id, method, args) async => throw StateError('网络连接断开');
      await tester.tap(find.byKey(const ValueKey('network-refresh')));
      await tester.pump();
      expect(find.textContaining('网络连接断开'), findsOneWidget);
      bridge.handler = null;
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(find.textContaining('网络连接断开'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'same URI hot restart invalidates pending profile and pause survives session updates',
    (tester) async {
      final bridge = NetworkFake();
      final pending = Completer<Map<String, dynamic>>();
      bridge.handler = (id, method, args) async =>
          method == 'ext.dart.io.getHttpProfile'
          ? pending.future
          : bridge.response(method, args);
      await _mount(tester, bridge);
      const restarting = Session(
        id: 'one',
        generation: 1,
        state: 'running',
        operation: 'hotRestart',
        projectPath: '/app',
        deviceId: 'macos',
        mode: 'debug',
        serviceUri: 'ws://localhost:123/ws',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: workbenchTheme(Brightness.light),
          home: Scaffold(
            body: NetworkPanel(bridge: bridge, session: restarting),
          ),
        ),
      );
      pending.complete({
        'timestamp': 300,
        'requests': [
          {...bridge.ref, 'uri': 'https://pre-restart.test/'},
        ],
      });
      await tester.pump();
      expect(find.textContaining('pre-restart.test'), findsNothing);
      bridge.handler = null;
      await tester.pumpWidget(
        MaterialApp(
          theme: workbenchTheme(Brightness.light),
          home: Scaffold(
            body: NetworkPanel(bridge: bridge, session: _session),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ListTile), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('network-pause')));
      final count = bridge.calls.length;
      const updated = Session(
        id: 'one',
        generation: 1,
        sequence: 2,
        state: 'paused',
        projectPath: '/app',
        deviceId: 'macos',
        mode: 'debug',
        serviceUri: 'ws://localhost:123/ws',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: workbenchTheme(Brightness.light),
          home: Scaffold(
            body: NetworkPanel(bridge: bridge, session: updated),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(bridge.calls.length, count);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'clear during first profile ignores its late result and establishes a VM timestamp boundary',
    (tester) async {
      final bridge = NetworkFake();
      final pending = Completer<Map<String, dynamic>>();
      bridge.handler = (id, method, args) async =>
          method == 'ext.dart.io.getHttpProfile'
          ? pending.future
          : bridge.response(method, args);
      await _mount(tester, bridge);
      await tester.tap(find.byKey(const ValueKey('network-clear')));
      bridge.handler = null;
      pending.complete({
        'timestamp': 199,
        'requests': [bridge.ref],
      });
      await tester.pump();
      await tester.pump();
      expect(find.byType(ListTile), findsNothing);
      bridge.ref = {
        ...bridge.ref,
        'id': 'new',
        'startTime': 201,
        'uri': 'https://new.test/',
      };
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('new.test'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('release and disconnected sessions never send network requests', (
    tester,
  ) async {
    final bridge = NetworkFake();
    await _mount(tester, bridge, session: null);
    await tester.pump(const Duration(seconds: 5));
    expect(bridge.calls, isEmpty);
    expect(find.textContaining('Debug 会话'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
