import 'dart:convert';

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
}
