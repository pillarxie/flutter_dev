import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_theme.dart';
import 'package:flutter_dev/features/devtools/network_format.dart';
import 'package:flutter_dev/features/devtools/network_request_details.dart';

Map<String, dynamic> _data(
  String body, {
  String type = 'application/x-www-form-urlencoded',
}) => {
  'method': 'POST',
  'uri': 'https://example.test/orders',
  'startTime': 100,
  'request': {
    'headers': {
      'content-type': [type],
    },
  },
  'response': {'statusCode': 200, 'endTime': 300},
  'requestBody': utf8.encode(body),
};

Future<void> _show(
  WidgetTester tester,
  Map<String, dynamic> data, {
  String requestKey = 'one',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: workbenchTheme(Brightness.light),
      home: Scaffold(
        body: NetworkRequestDetails(data: data, requestKey: requestKey),
      ),
    ),
  );
  await tester.pump();
}

Finder _node(String pointer, {String identity = 'form-0'}) {
  final path = pointer.startsWith('/') ? '\$$pointer' : pointer;
  return find.byKey(ValueKey('network-payload-toggle-$identity-$path'));
}

Finder _tab(String name) => find.byKey(ValueKey('network-detail-tab-$name'));

void main() {
  testWidgets(
    'payload nodes retain state across tabs, raw mode and live data without changing copied content',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final payload = {
        'customer': {
          'name': '节点中文',
          'address': {'city': '节点城市'},
        },
        'items': [
          {
            'sku': '商品一',
            'meta': {'code': '子节点一'},
          },
          {'sku': '商品二'},
        ],
        'escaped': '%26+literal',
      };
      final raw =
          'payload=${Uri.encodeQueryComponent(jsonEncode(payload))}&source=desktop';
      var data = _data(raw);
      await _show(tester, data);
      expect(find.text(jsonEncode('节点中文')), findsOneWidget);
      expect(find.text(jsonEncode('节点城市')), findsNothing);
      expect(find.text(jsonEncode('%26+literal')), findsOneWidget);
      await tester.tap(_node('/customer/address'));
      await tester.pump();
      expect(find.text(jsonEncode('节点城市')), findsOneWidget);
      await tester.tap(_node('/items/0'));
      await tester.pump();
      expect(find.text(jsonEncode('商品一')), findsOneWidget);
      await tester.tap(_node('/items/0/meta'));
      await tester.pump();
      expect(find.text(jsonEncode('子节点一')), findsOneWidget);
      expect(find.text(jsonEncode('商品二')), findsNothing);
      await tester.tap(_node('/customer'));
      await tester.pump();
      expect(find.text(jsonEncode('节点中文')), findsNothing);
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
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.byTooltip('复制请求正文格式化内容'));
      expect(
        copied,
        formatNetworkBody(
          utf8.encode(raw),
          'application/x-www-form-urlencoded',
        ).formatted,
      );
      await tester.tap(
        find.byKey(const ValueKey('network-detail-raw-request-body')),
      );
      await tester.pump();
      expect(find.text(raw), findsOneWidget);
      await tester.tap(find.byTooltip('复制请求正文原始内容'));
      expect(copied, raw);
      await tester.tap(
        find.byKey(const ValueKey('network-detail-raw-request-body')),
      );
      await tester.pump();
      expect(find.text(jsonEncode('节点中文')), findsNothing);
      await tester.tap(_tab('headers'));
      await tester.pump();
      data = {
        ...data,
        'response': {'statusCode': 201, 'endTime': 500},
      };
      await _show(tester, data);
      expect(find.text('Query 参数'), findsNothing);
      await tester.tap(_tab('parameters'));
      await tester.pump();
      expect(find.text(jsonEncode('节点中文')), findsNothing);
      expect(find.text(jsonEncode('子节点一')), findsOneWidget);
      await tester.tap(_node('/customer'));
      await tester.pump();
      expect(find.text(jsonEncode('节点城市')), findsOneWidget);
      await tester.tap(_tab('response'));
      await tester.pump();
      await _show(tester, data, requestKey: 'two');
      expect(find.text('Query 参数'), findsOneWidget);
      expect(find.text(jsonEncode('节点中文')), findsOneWidget);
      expect(find.text(jsonEncode('节点城市')), findsNothing);
      expect(find.text(jsonEncode('商品一')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repeated payload fields collapse independently and invalid or double encoded JSON stays text',
    (tester) async {
      final first = Uri.encodeQueryComponent(jsonEncode({'name': '第一份'}));
      final second = Uri.encodeQueryComponent(jsonEncode({'name': '第二份'}));
      final doubleEncoded = Uri.encodeQueryComponent(first);
      await _show(
        tester,
        _data(
          'payload=$first&payload=$second&payload=%7Bbroken&payload=$doubleEncoded',
        ),
      );
      expect(find.text(jsonEncode('第一份')), findsOneWidget);
      expect(find.text(jsonEncode('第二份')), findsOneWidget);
      expect(find.text('{broken'), findsOneWidget);
      expect(find.text(first), findsOneWidget);
      expect(_node(r'$', identity: 'form-2'), findsNothing);
      expect(_node(r'$', identity: 'form-3'), findsNothing);
      await tester.tap(_node(r'$'));
      await tester.pump();
      expect(find.text(jsonEncode('第一份')), findsNothing);
      expect(find.text(jsonEncode('第二份')), findsOneWidget);
      await tester.tap(_node(r'$', identity: 'form-1'));
      await tester.pump();
      expect(find.text(jsonEncode('第二份')), findsNothing);
      await tester.tap(_node(r'$'));
      await tester.pump();
      expect(find.text(jsonEncode('第一份')), findsOneWidget);
      expect(find.text(jsonEncode('第二份')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'JSON body payload supports nested arrays and pointer-safe field names',
    (tester) async {
      await _show(
        tester,
        _data(
          jsonEncode({
            'payload': {
              'a/b': {
                '~key': {'value': '正确路径'},
              },
              'items': [1, false, null],
            },
            'source': 'desktop',
          }),
          type: 'application/json',
        ),
      );
      expect(_node(r'$', identity: 'json-payload'), findsOneWidget);
      expect(find.text(jsonEncode('正确路径')), findsNothing);
      await tester.tap(_node('/a~1b/~0key', identity: 'json-payload'));
      await tester.pump();
      expect(find.text(jsonEncode('正确路径')), findsOneWidget);
      await tester.tap(_node('/items', identity: 'json-payload'));
      await tester.pump();
      expect(find.text(jsonEncode('正确路径')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'node limit only reports truncation when visible payload content is omitted',
    (tester) async {
      for (final count in [199, 200]) {
        final payload = List.generate(count, (index) => 'entry-$index');
        await _show(
          tester,
          _data('payload=${Uri.encodeQueryComponent(jsonEncode(payload))}'),
          requestKey: 'limit-$count',
        );
        expect(find.text(jsonEncode('entry-198')), findsOneWidget);
        expect(
          find.text('节点较多，仅展示前 200 个可见节点；完整内容仍可复制。'),
          count == 199 ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('large and deep payload stays bounded in a narrow detail pane', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    dynamic deep = {'leaf': '深层内容'};
    for (var i = 0; i < 20; i++) {
      deep = {'layer$i': deep};
    }
    final payload = {
      'items': List.generate(1000, (i) => 'item-$i'),
      'deep': deep,
    };
    await _show(
      tester,
      _data('payload=${Uri.encodeQueryComponent(jsonEncode(payload))}'),
    );
    expect(find.text(jsonEncode('item-0')), findsOneWidget);
    expect(find.text(jsonEncode('item-999')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(_node('/items'));
    await tester.pump();
    for (var depth = 2; depth <= 15; depth++) {
      final path =
          '/deep${List.generate(depth - 1, (i) => '/layer${19 - i}').join()}';
      final node = _node(path);
      if (node.evaluate().isEmpty) break;
      await tester.ensureVisible(node);
      await tester.tap(node);
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
    expect(find.text(jsonEncode('深层内容')), findsNothing);
  });
}
