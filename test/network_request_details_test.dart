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
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: workbenchTheme(brightness),
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
    'JSON form and query fields fold independently regardless of parameter name',
    (tester) async {
      final value = jsonEncode({
        'products': [
          {'name': '嵌套商品'},
        ],
        'source': '字段内容',
      });
      final encoded = Uri.encodeQueryComponent(value);
      final data = {
        ..._data('products=$encoded&metadata=$encoded&invalid=%7Bbroken'),
        'uri': 'https://example.test/orders?filter=$encoded&invalid=%7Bbroken',
      };
      await _show(tester, data);
      expect(_node(r'$', identity: 'query-0'), findsOneWidget);
      expect(_node(r'$', identity: 'form-0'), findsOneWidget);
      expect(_node(r'$', identity: 'form-1'), findsOneWidget);
      expect(_node(r'$', identity: 'query-1'), findsNothing);
      expect(_node(r'$', identity: 'form-2'), findsNothing);
      expect(find.text('{broken'), findsNWidgets(2));
      expect(find.text(jsonEncode('字段内容')), findsNWidgets(3));
      await tester.tap(_node(r'$', identity: 'query-0'));
      await tester.pump();
      expect(find.text(jsonEncode('字段内容')), findsNWidgets(2));
      await tester.ensureVisible(_node(r'$', identity: 'form-0'));
      await tester.tap(_node(r'$', identity: 'form-0'));
      await tester.pump();
      expect(find.text(jsonEncode('字段内容')), findsOneWidget);
      await tester.ensureVisible(_node('/products/0', identity: 'form-1'));
      await tester.tap(_node('/products/0', identity: 'form-1'));
      await tester.pump();
      expect(find.text(jsonEncode('嵌套商品')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ordinary JSON request fields keep their table and independent object and array nodes',
    (tester) async {
      await _show(
        tester,
        _data(
          jsonEncode({
            'table_id': 4950,
            'products': [
              {
                'name': '请求商品',
                'details': {'stock': '请求库存'},
              },
            ],
            'metadata': {'name': '请求元数据'},
            r'$group/a/b': {'name': '特殊字段内容'},
            'message': '普通文本',
          }),
          type: 'application/json',
        ),
      );
      expect(find.text('table_id'), findsOneWidget);
      expect(find.text('4950'), findsOneWidget);
      expect(find.text('products'), findsOneWidget);
      expect(_node(r'$', identity: 'json-products'), findsOneWidget);
      expect(_node(r'$', identity: 'json-metadata'), findsOneWidget);
      expect(find.text(jsonEncode('请求商品')), findsOneWidget);
      expect(find.text(jsonEncode('请求库存')), findsNothing);
      await tester.ensureVisible(
        _node('/0/details', identity: 'json-products'),
      );
      await tester.tap(_node('/0/details', identity: 'json-products'));
      await tester.pump();
      expect(find.text(jsonEncode('请求库存')), findsOneWidget);
      await tester.tap(_node(r'$', identity: 'json-products'));
      await tester.pump();
      expect(find.text(jsonEncode('请求商品')), findsNothing);
      expect(find.text(jsonEncode('请求元数据')), findsOneWidget);
      expect(find.text(jsonEncode('特殊字段内容')), findsOneWidget);
      final specialRoot = _node(
        r'$',
        identity: 'json-${Uri.encodeComponent(r'$group/a/b')}',
      );
      await tester.ensureVisible(specialRoot);
      await tester.tap(specialRoot);
      await tester.pump();
      expect(find.text(jsonEncode('特殊字段内容')), findsNothing);
      expect(find.text(jsonEncode('请求元数据')), findsOneWidget);
      expect(find.text(jsonEncode('普通文本')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'JSON field names and nested pointers never share folding state',
    (tester) async {
      await _show(
        tester,
        _data(
          jsonEncode({
            'a': {
              r'b-$': {'name': '嵌套字段内容'},
            },
            r'a-$/b': {'name': '顶层字段内容'},
          }),
          type: 'application/json',
        ),
      );
      final nested = _node(r'/b-$', identity: 'json-a');
      final root = _node(
        r'$',
        identity: 'json-${Uri.encodeComponent(r'a-$/b')}',
      );
      expect(find.text(jsonEncode('嵌套字段内容')), findsOneWidget);
      expect(find.text(jsonEncode('顶层字段内容')), findsOneWidget);
      await tester.tap(nested);
      await tester.pump();
      expect(find.text(jsonEncode('嵌套字段内容')), findsNothing);
      expect(find.text(jsonEncode('顶层字段内容')), findsOneWidget);
      await tester.ensureVisible(root);
      await tester.tap(root);
      await tester.pump();
      expect(find.text(jsonEncode('嵌套字段内容')), findsNothing);
      expect(find.text(jsonEncode('顶层字段内容')), findsNothing);
      await tester.ensureVisible(nested);
      await tester.tap(nested);
      await tester.pump();
      expect(find.text(jsonEncode('嵌套字段内容')), findsOneWidget);
      expect(find.text(jsonEncode('顶层字段内容')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('JSON root arrays and nested response objects can be folded', (
    tester,
  ) async {
    final request = [
      {
        'name': '数组请求',
        'details': {'name': '数组请求子节点'},
      },
    ];
    final response = {
      'data': [
        {
          'name': '响应商品',
          'details': {'name': '响应子节点'},
        },
      ],
      'success': true,
    };
    final data = {
      ..._data(jsonEncode(request), type: 'application/json'),
      'responseBody': utf8.encode(jsonEncode(response)),
    };
    await _show(tester, data);
    expect(_node(r'$', identity: 'request-body'), findsOneWidget);
    expect(find.text(jsonEncode('数组请求')), findsOneWidget);
    expect(find.text(jsonEncode('数组请求子节点')), findsNothing);
    await tester.tap(_node('/0/details', identity: 'request-body'));
    await tester.pump();
    expect(find.text(jsonEncode('数组请求子节点')), findsOneWidget);
    await tester.tap(_node(r'$', identity: 'request-body'));
    await tester.pump();
    await tester.tap(_tab('response'));
    await tester.pump();
    expect(_node(r'$', identity: 'response-body'), findsOneWidget);
    expect(find.text(jsonEncode('响应商品')), findsNothing);
    await tester.tap(_node('/data/0', identity: 'response-body'));
    await tester.pump();
    expect(find.text(jsonEncode('响应商品')), findsOneWidget);
    await tester.tap(_node('/data/0/details', identity: 'response-body'));
    await tester.pump();
    expect(find.text(jsonEncode('响应子节点')), findsOneWidget);
    await tester.tap(_tab('parameters'));
    await tester.pump();
    expect(find.text(jsonEncode('数组请求')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'response array folding preserves formatted and raw copies across refresh and resets per request',
    (tester) async {
      final raw = '[ { "name": "响应数组", "details": {"value": "响应深层"} } ]';
      var data = {..._data('source=desktop'), 'responseBody': utf8.encode(raw)};
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
      await _show(tester, data);
      await tester.tap(_tab('response'));
      await tester.pump();
      expect(find.text(jsonEncode('响应数组')), findsOneWidget);
      await tester.tap(_node('/0/details', identity: 'response-body'));
      await tester.pump();
      expect(find.text(jsonEncode('响应深层')), findsOneWidget);
      await tester.tap(_node('/0', identity: 'response-body'));
      await tester.pump();
      expect(find.text(jsonEncode('响应数组')), findsNothing);
      await tester.tap(find.byTooltip('复制响应正文格式化内容'));
      expect(copied, formatNetworkBody(utf8.encode(raw), '').formatted);
      await tester.tap(
        find.byKey(const ValueKey('network-detail-raw-response-body')),
      );
      await tester.pump();
      expect(find.text(raw), findsOneWidget);
      await tester.tap(find.byTooltip('复制响应正文原始内容'));
      expect(copied, raw);
      await tester.tap(
        find.byKey(const ValueKey('network-detail-raw-response-body')),
      );
      await tester.pump();
      expect(find.text(jsonEncode('响应数组')), findsNothing);
      data = {
        ...data,
        'response': {'statusCode': 201, 'endTime': 500},
      };
      await _show(tester, data);
      expect(find.text(jsonEncode('响应数组')), findsNothing);
      await tester.tap(_node('/0', identity: 'response-body'));
      await tester.pump();
      expect(find.text(jsonEncode('响应深层')), findsOneWidget);
      await _show(tester, data, requestKey: 'new-response');
      await tester.tap(_tab('response'));
      await tester.pump();
      expect(find.text(jsonEncode('响应数组')), findsOneWidget);
      expect(find.text(jsonEncode('响应深层')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid and scalar response JSON remains selectable text', (
    tester,
  ) async {
    for (final raw in ['{"unfinished":', 'false', '"plain JSON string"']) {
      await _show(tester, {
        ..._data('source=desktop'),
        'responseBody': utf8.encode(raw),
      }, requestKey: raw);
      await tester.tap(_tab('response'));
      await tester.pump();
      expect(find.text(raw), findsOneWidget);
      expect(_node(r'$', identity: 'response-body'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'JSON parameter and response trees fit narrow light and dark panes',
    (tester) async {
      tester.view.physicalSize = const Size(280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final value = {
        'products': [
          {
            'very_long_field_name_that_wraps':
                '很长的 JSON 字符串内容，用于检查窄窗口里的自动换行与展开收起。',
          },
        ],
      };
      for (final brightness in Brightness.values) {
        final data = {
          ..._data(jsonEncode(value), type: 'application/json'),
          'responseBody': utf8.encode(jsonEncode(value)),
        };
        await _show(
          tester,
          data,
          requestKey: brightness.name,
          brightness: brightness,
        );
        await tester.tap(_node(r'$', identity: 'json-products'));
        await tester.pump();
        await tester.tap(_node(r'$', identity: 'json-products'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.tap(_tab('response'));
        await tester.pump();
        await tester.tap(_node('/products/0', identity: 'response-body'));
        await tester.pump();
        expect(find.text('very_long_field_name_that_wraps:'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
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
  testWidgets(
    'response search finds folded content, keeps copy exact and resets per request',
    (tester) async {
      final response = jsonEncode({
        'outer': {
          'middle': {'leaf': 'Needle Needle'},
        },
      });
      final data = {..._data(''), 'responseBody': utf8.encode(response)};
      await _show(tester, data);
      await tester.tap(_tab('response'));
      await tester.pump();
      expect(find.text(jsonEncode('Needle Needle')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('network-response-search')),
        'needle',
      );
      await tester.pump();
      expect(find.textContaining('2 处匹配'), findsOneWidget);
      final texts = tester.widgetList<SelectableText>(
        find.byType(SelectableText),
      );
      expect(
        texts.any(
          (text) =>
              text.textSpan?.toPlainText().contains('Needle Needle') == true,
        ),
        isTrue,
      );
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
      await tester.tap(find.byTooltip('复制响应正文格式化内容'));
      expect(copied, formatNetworkBody(utf8.encode(response), '').formatted);
      await tester.tap(
        find.byKey(const ValueKey('network-detail-raw-response-body')),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('复制响应正文原始内容'));
      expect(copied, response);
      await tester.enterText(
        find.byKey(const ValueKey('network-response-search')),
        'absent',
      );
      await tester.pump();
      expect(find.textContaining('0 处匹配'), findsOneWidget);
      await _show(tester, data, requestKey: 'two');
      await tester.tap(_tab('response'));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('network-response-search')),
            )
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'expand all covers hidden descendants and collapse remains independent per section',
    (tester) async {
      final payload = jsonEncode({
        'a': {
          'b': {
            'c': {'leaf': 'deep value'},
          },
        },
        'empty': [],
      });
      final data = {
        ..._data('payload=${Uri.encodeQueryComponent(payload)}'),
        'responseBody': utf8.encode(payload),
      };
      await _show(tester, data);
      expect(find.text(jsonEncode('deep value')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('network-json-expand-request-body')),
      );
      await tester.pump();
      expect(find.text(jsonEncode('deep value')), findsOneWidget);
      expect(_node('/empty'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('network-json-collapse-request-body')),
      );
      await tester.pump();
      expect(_node('/a'), findsNothing);
      await tester.tap(_node(r'$'));
      await tester.pump();
      expect(_node('/a'), findsOneWidget);
      expect(_node('/a/b'), findsNothing);
      await tester.tap(_node('/a'));
      await tester.pump();
      expect(_node('/a/b'), findsOneWidget);
      await tester.tap(_tab('response'));
      await tester.pump();
      expect(_node('/a/b', identity: 'response-body'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('network-json-expand-response-body')),
      );
      await tester.pump();
      expect(find.text(jsonEncode('deep value')), findsOneWidget);
      await tester.tap(_tab('parameters'));
      await tester.pump();
      expect(find.text(jsonEncode('deep value')), findsNothing);
    },
  );

  testWidgets(
    'all expansion honors depth and visible node limits in 280px light and dark panes',
    (tester) async {
      tester.view.physicalSize = const Size(280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      dynamic deep = {'leaf': 'unreachable leaf'};
      for (var i = 0; i < 20; i++) {
        deep = {'layer': deep};
      }
      final data = {
        ..._data(''),
        'responseBody': utf8.encode(
          jsonEncode({
            'deep': deep,
            'wide': List.generate(1000, (i) => 'item-$i'),
          }),
        ),
      };
      for (final brightness in Brightness.values) {
        await _show(
          tester,
          data,
          brightness: brightness,
          requestKey: brightness.name,
        );
        await tester.tap(_tab('response'));
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('network-json-expand-response-body')),
        );
        await tester.pump();
        expect(find.textContaining('已达到展示深度上限'), findsOneWidget);
        expect(find.textContaining('节点较多，仅展示前 200'), findsOneWidget);
        expect(find.text(jsonEncode('unreachable leaf')), findsNothing);
        expect(find.text(jsonEncode('item-999')), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
