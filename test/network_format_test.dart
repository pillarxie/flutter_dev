import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/features/devtools/network_format.dart';

void main() {
  test(
    'form/query decoding preserves order, duplicates, empty values and equals',
    () {
      final content = formatNetworkParameters(
        'tag=one&name=%E4%B8%AD%E6%96%87+name&tag=two&empty=&flag&value=a%3Db&plus=%2B',
      );
      expect(content.fields.map((f) => (f.name, f.value)), [
        ('tag', 'one'),
        ('name', '中文 name'),
        ('tag', 'two'),
        ('empty', ''),
        ('flag', ''),
        ('value', 'a=b'),
        ('plus', '+'),
      ]);
      expect(content.raw, contains('%E4%B8%AD'));
    },
  );

  test('nested JSON is readable after one percent decoding pass', () {
    final content = formatNetworkParameters(
      'payload=%7B%22name%22%3A%22%E4%B8%AD%E6%96%87%22%2C%22items%22%3A%5B1%2C2%5D%7D&escaped=%2526&literal=%252B',
    );
    expect(
      content.fields.first.value,
      '{\n  "name": "中文",\n  "items": [\n    1,\n    2\n  ]\n}',
    );
    expect(content.fields[1].value, '%26');
    expect(content.fields[2].value, '%2B');
  });

  test(
    'malformed encoding remains displayable without losing valid fields',
    () {
      final content = formatNetworkQuery(
        'https://example.test/?bad=%ZZ%2&good=%E4%B8%AD&broken=%FF#fragment',
      );
      expect(content.fields.map((f) => f.value), ['%ZZ%2', '中', '%FF']);
      expect(
        formatNetworkQuery('https://example.test/no-query').fields,
        isEmpty,
      );
      expect(
        formatNetworkQuery('https://example.test/#fragment?not=query').fields,
        isEmpty,
      );
    },
  );

  test('JSON and plain text do not guess percent decoding or plus spaces', () {
    final json = formatNetworkBody(
      utf8.encode('{"value":"%2526+a","count":2}'),
      'application/json',
    );
    expect(json.formatted, '{\n  "value": "%2526+a",\n  "count": 2\n}');
    expect(json.raw, '{"value":"%2526+a","count":2}');
    final plain = formatNetworkBody(utf8.encode('a=%E4%B8%AD+b'), 'text/plain');
    expect(plain.formatted, 'a=%E4%B8%AD+b');
    expect(plain.fields, isEmpty);
  });

  test('byte array form body decodes by content type and handles charset', () {
    final form = formatNetworkBody(
      utf8.encode('name=%E4%B8%AD%E6%96%87&tag=a&tag=b'),
      'application/x-www-form-urlencoded; charset=utf-8',
    );
    expect(form.fields.map((f) => f.value), ['中文', 'a', 'b']);
    expect(
      formatNetworkBody([233], 'text/plain; charset=iso-8859-1').formatted,
      'é',
    );
    expect(
      networkContentType({
        'headers': {
          'Content-Type': ['application/json'],
        },
      }),
      'application/json',
    );
  });

  test(
    'multipart fallback, binary, absent and large bodies have explicit limits',
    () {
      final multipart = formatNetworkBody(
        utf8.encode('--boundary\r\ncontent'),
        'multipart/form-data; boundary=boundary',
      );
      expect(multipart.note, contains('暂不拆分 multipart'));
      expect(multipart.formatted, '--boundary\r\ncontent');
      expect(
        formatNetworkBody([0, 255], 'application/octet-stream').note,
        contains('2 bytes'),
      );
      expect(formatNetworkBody(null, '').note, contains('尚未采集'));
      final large = formatNetworkBody(
        List.filled(networkPreviewLimit + 10, 97),
        'text/plain',
      );
      expect(large.raw.length, networkPreviewLimit);
      expect(large.note, contains('前 128 KiB'));
    },
  );
  test(
    'cURL preserves quoted URL, duplicate headers and JSON body as shell arguments',
    () async {
      const uri =
          "https://example.test/[a]?q=%2526+x&literal='&cmd=\$(printf BAD)";
      const body = '{"text":"it\'s \$(printf BAD) `echo BAD`","space":"a+b"}';
      final command = networkCurl({
        'uri': uri,
        'method': 'POST',
        'requestBody': utf8.encode(body),
        'endTime': 20,
        'request': {
          'contentLength': utf8.encode(body).length,
          'headers': {
            'content-type': ['application/json'],
            'x-tag': ["one's", 'two'],
            'x-empty': [''],
          },
        },
      });
      // Parse only: replacing curl with set/printf prevents any HTTP request.
      final result = await Process.run('/bin/sh', [
        '-c',
        'set -- ${command.substring(5)}; printf \'%s\\0\' "\$@"',
      ]);
      expect(result.exitCode, 0);
      final arguments = (result.stdout as String).split('\x00')..removeLast();
      expect(arguments, [
        '--globoff',
        '--path-as-is',
        '--request',
        'POST',
        '--header',
        'content-type: application/json',
        '--header',
        "x-tag: one's",
        '--header',
        'x-tag: two',
        '--header',
        'x-empty;',
        '--data-raw',
        body,
        '--url',
        uri,
      ]);
    },
    skip: Platform.isWindows,
  );

  test(
    'cURL preserves absent Content-Type and retains captured casing without duplication',
    () {
      Map<String, dynamic> capture(Map<String, dynamic> headers, String body) =>
          {
            'uri': 'https://example.test/raw',
            'method': 'POST',
            'endTime': 10,
            'request': {'headers': headers},
            'requestBody': utf8.encode(body),
          };
      final absent = networkCurl(
        capture({
          'x-tag': ['a'],
        }, '@raw body'),
      );
      expect(
        absent,
        contains("--header 'Content-Type:' --data-raw '@raw body'"),
      );
      expect(networkCurl(capture({}, '')), isNot(contains('Content-Type:')));
      for (final name in ['content-type', 'Content-Type', 'CONTENT-TYPE']) {
        final captured = networkCurl(
          capture({
            name: ['text/plain; charset=utf-8'],
          }, 'raw body'),
        );
        expect(
          captured,
          contains("--header '$name: text/plain; charset=utf-8'"),
        );
        expect(captured, isNot(contains("--header 'Content-Type:'")));
        expect(RegExp('--header').allMatches(captured), hasLength(1));
      }
    },
  );

  test(
    'cURL uses actual HttpProfileRequest schema while response is still streaming',
    () {
      final data = <String, dynamic>{
        'type': 'HttpProfileRequest',
        'id': 'request-1',
        'method': 'POST',
        'uri': 'https://example.test/stream',
        'startTime': 100,
        'endTime': 120,
        'request': {
          'headers': {
            'content-type': ['application/json'],
          },
          'contentLength': 11,
        },
        'requestBody': utf8.encode('{"ok":true}'),
        'response': {'startTime': 130, 'statusCode': 200},
        'responseBody': utf8.encode('partial response'),
      };
      expect(networkCurl(data), contains("--data-raw '{\"ok\":true}'"));
      // Until sending ends, even an available partial body must not be copied.
      data.remove('endTime');
      expect(() => networkCurl(data), throwsFormatException);
    },
  );

  test('cURL refuses missing, incomplete, binary and oversized captures', () {
    Map<String, dynamic> capture(dynamic body) => {
      'uri': 'https://example.test/',
      'method': 'POST',
      'requestBody': body,
      'endTime': 10,
      'request': {'headers': <String, dynamic>{}},
    };
    for (final body in [
      null,
      [0, 12],
      [255],
      List.filled(networkPreviewLimit + 1, 97),
    ]) {
      expect(() => networkCurl(capture(body)), throwsFormatException);
    }
    expect(
      () => networkCurl({
        ...capture([]),
        'endTime': null,
        'request': {'headers': {}},
      }),
      throwsFormatException,
    );
    expect(
      () => networkCurl({
        ...capture([97]),
        'request': {'contentLength': 2, 'headers': {}},
      }),
      throwsFormatException,
    );
    expect(
      () => networkCurl({
        ...capture([97]),
        'request': {
          'headers': {
            'content-type': ['image/png'],
          },
        },
      }),
      throwsFormatException,
    );
    expect(
      () => networkCurl({...capture([]), 'request': <String, dynamic>{}}),
      throwsFormatException,
    );
    expect(
      networkCurl(capture(utf8.encode('@secret.txt'))),
      contains("--data-raw '@secret.txt'"),
    );
    expect(networkCurl(capture([])), contains("--url 'https://example.test/'"));
  });

  test(
    'method and status selections intersect search and distinguish transport failures',
    () {
      Map<String, dynamic> request(
        int? code, {
        Object? error,
        bool pending = false,
      }) => {
        'method': 'POST',
        'uri': 'https://example.test/items',
        'response': {
          'statusCode': code,
          if (!pending) 'endTime': 10,
          'error': ?error,
        },
      };
      for (final code in [200, 302, 404, 503]) {
        expect(networkStatusCategory(request(code)), '${code ~/ 100}xx');
      }
      expect(networkStatusCategory(request(200, pending: true)), '进行中');
      expect(
        networkStatusCategory(request(null, error: 'connection reset')),
        '失败',
      );
      expect(
        matchesNetworkRequest(
          request(404),
          methods: {'POST', 'GET'},
          statuses: {'4xx', '失败'},
          query: 'ITEMS',
        ),
        isTrue,
      );
      expect(matchesNetworkRequest(request(404), methods: {'GET'}), isFalse);
      expect(matchesNetworkRequest(request(404), statuses: {'失败'}), isFalse);
      expect(
        matchesNetworkRequest(request(404), statuses: {'4xx'}, query: '503'),
        isFalse,
      );
    },
  );
}
