import 'dart:convert';

const networkPreviewLimit = 128 * 1024;

class NetworkField {
  const NetworkField(this.name, this.value);
  final String name, value;
}

class NetworkContent {
  const NetworkContent({
    required this.raw,
    required this.formatted,
    this.fields = const [],
    this.note,
  });
  final String raw, formatted;
  final List<NetworkField> fields;
  final String? note;
}

String _pretty(String value) {
  try {
    final parsed = jsonDecode(value);
    if (parsed is Map || parsed is List) {
      return const JsonEncoder.withIndent('  ').convert(parsed);
    }
  } on FormatException {
    // Plain strings keep their original spelling.
  }
  return value;
}

/// Decode exactly one form/query layer. Invalid escapes remain visible.
String decodeNetworkField(String value) {
  final spaces = value.replaceAll('+', ' ');
  return spaces.replaceAllMapped(RegExp(r'(?:%[0-9a-fA-F]{2})+'), (match) {
    final run = match[0]!;
    final bytes = <int>[
      for (var i = 0; i < run.length; i += 3)
        int.parse(run.substring(i + 1, i + 3), radix: 16),
    ];
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return run;
    }
  });
}

NetworkContent formatNetworkParameters(String raw) {
  final truncated = raw.length > networkPreviewLimit;
  final preview = truncated ? raw.substring(0, networkPreviewLimit) : raw;
  final fields = <NetworkField>[];
  if (preview.isNotEmpty) {
    for (final pair in preview.split('&')) {
      final separator = pair.indexOf('=');
      final name = separator < 0 ? pair : pair.substring(0, separator);
      final value = separator < 0 ? '' : pair.substring(separator + 1);
      fields.add(
        NetworkField(
          decodeNetworkField(name),
          _pretty(decodeNetworkField(value)),
        ),
      );
    }
  }
  return NetworkContent(
    raw: preview,
    formatted: fields.map((f) => '${f.name}: ${f.value}').join('\n'),
    fields: fields,
    note: truncated ? '内容过大，仅展示和复制前 128 Ki 字符。' : null,
  );
}

NetworkContent formatNetworkQuery(String uri) {
  final query = uri.indexOf('?');
  final fragment = uri.indexOf('#');
  if (query < 0 || (fragment >= 0 && fragment < query)) {
    return formatNetworkParameters('');
  }
  return formatNetworkParameters(
    uri.substring(query + 1, fragment < 0 ? uri.length : fragment),
  );
}

String networkContentType(Map<String, dynamic> data) {
  final headers = data['headers'];
  if (headers is! Map) return '';
  for (final entry in headers.entries) {
    if (entry.key.toString().toLowerCase() == 'content-type') {
      return entry.value is List
          ? (entry.value as List).join('; ')
          : entry.value.toString();
    }
  }
  return '';
}

NetworkContent formatNetworkBody(dynamic body, String contentType) {
  if (body == null) {
    return const NetworkContent(
      raw: '',
      formatted: '',
      note: '正文尚未采集，或请求仍在进行。',
    );
  }
  final bytes = body is List
      ? body.whereType<int>().toList()
      : utf8.encode(body.toString());
  final mediaType = contentType.split(';').first.trim().toLowerCase();
  final truncated = bytes.length > networkPreviewLimit;
  final preview = bytes.take(networkPreviewLimit).toList();
  final binary =
      mediaType.startsWith('image/') ||
      mediaType.startsWith('audio/') ||
      mediaType.startsWith('video/') ||
      mediaType.startsWith('font/') ||
      const [
        'application/octet-stream',
        'application/pdf',
        'application/zip',
        'application/gzip',
      ].contains(mediaType);
  String raw;
  try {
    final charset = RegExp(
      r'charset\s*=\s*["\x27]?([^;"\x27\s]+)',
      caseSensitive: false,
    ).firstMatch(contentType)?.group(1)?.toLowerCase();
    raw = const ['iso-8859-1', 'latin1', 'latin-1'].contains(charset)
        ? latin1.decode(preview)
        : utf8.decode(preview, allowMalformed: truncated);
  } on FormatException {
    return NetworkContent(
      raw: '',
      formatted: '',
      note: '二进制或非 UTF-8 正文，${bytes.length} bytes。',
    );
  }
  if (binary ||
      (!mediaType.startsWith('multipart/') &&
          preview.any((b) => b < 9 || (b > 13 && b < 32)))) {
    return NetworkContent(
      raw: '',
      formatted: '',
      note: '二进制正文，${bytes.length} bytes。',
    );
  }
  if (mediaType == 'application/x-www-form-urlencoded') {
    final form = formatNetworkParameters(raw);
    return NetworkContent(
      raw: form.raw,
      formatted: form.formatted,
      fields: form.fields,
      note: truncated ? '正文过大，仅展示和复制前 128 KiB。' : form.note,
    );
  }
  return NetworkContent(
    raw: raw,
    formatted: mediaType.startsWith('multipart/') ? raw : _pretty(raw),
    note: mediaType.startsWith('multipart/')
        ? '暂不拆分 multipart 字段，以下展示原始文本${truncated ? '（前 128 KiB）' : ''}。'
        : truncated
        ? '正文过大，仅展示和复制前 128 KiB。'
        : null,
  );
}
