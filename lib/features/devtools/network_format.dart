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

/// Builds a POSIX-shell command only from a complete, lossless text capture.
/// The command is copied, never executed by the workbench.
String networkCurl(Map<String, dynamic> data) {
  final request = data['request'] is Map ? data['request'] as Map : const {};
  final response = data['response'] is Map ? data['response'] as Map : const {};
  final uri = data['uri'];
  final method = data['method'];
  if (uri is! String || uri.isEmpty || method is! String || method.isEmpty) {
    throw const FormatException('请求地址或方法尚未采集，无法复制完整 cURL。');
  }
  // HttpProfiler puts the request-send end time at the top level. A response
  // can still be streaming after the complete request body is available.
  if (data['endTime'] == null && response['endTime'] == null) {
    throw const FormatException('请求正文尚未采集完成，请等待请求发送完成后重试。');
  }
  final body = data['requestBody'];
  if (body == null) {
    throw const FormatException('请求正文尚未采集，无法复制完整 cURL。');
  }
  final bytes =
      body is List && body.every((b) => b is int && b >= 0 && b <= 255)
      ? body.cast<int>()
      : body is String
      ? utf8.encode(body)
      : null;
  if (bytes == null || bytes.length > networkPreviewLimit) {
    throw const FormatException('正文过大或格式未知，无法复制完整 cURL。');
  }
  final length = request['contentLength'];
  if (length is int && length >= 0 && length != bytes.length) {
    throw const FormatException('请求正文采集不完整，无法复制完整 cURL。');
  }
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    throw const FormatException('二进制或非 UTF-8 请求正文，暂不支持复制 cURL。');
  }
  final mediaType = networkContentType(
    Map<String, dynamic>.from(request),
  ).split(';').first.trim().toLowerCase();
  if (mediaType.startsWith('image/') ||
      mediaType.startsWith('audio/') ||
      mediaType.startsWith('video/') ||
      mediaType.startsWith('font/') ||
      const [
        'application/octet-stream',
        'application/pdf',
        'application/zip',
        'application/gzip',
      ].contains(mediaType) ||
      bytes.any((b) => b < 9 || b > 13 && b < 32)) {
    throw const FormatException('二进制请求正文，暂不支持复制 cURL。');
  }
  final arguments = <String>[
    'curl',
    '--globoff',
    '--path-as-is',
    '--request',
    _shellQuote(method),
  ];
  final headers = request['headers'];
  if (headers is! Map) {
    throw const FormatException('请求头尚未采集，无法复制完整 cURL。');
  }
  for (final entry in headers.entries) {
    final values = entry.value is List ? entry.value as List : [entry.value];
    for (final value in values) {
      final header = '${entry.key}: ${value ?? ''}';
      if (header.contains(RegExp(r'[\r\n\x00]'))) {
        throw const FormatException('请求头包含不支持的控制字符，无法复制 cURL。');
      }
      arguments.addAll([
        '--header',
        _shellQuote(value == '' ? '${entry.key};' : header),
      ]);
    }
  }
  if (text.isNotEmpty) {
    // Suppress curl's default form Content-Type when it was absent on capture.
    if (!headers.keys.any(
      (name) => name.toString().toLowerCase() == 'content-type',
    )) {
      arguments.addAll(['--header', _shellQuote('Content-Type:')]);
    }
    // --data-raw treats a leading @ as literal text, never a local file.
    arguments.addAll(['--data-raw', _shellQuote(text)]);
  }
  arguments.addAll(['--url', _shellQuote(uri)]);
  return arguments.join(' ');
}

String _shellQuote(String text) {
  if (text.contains('\x00')) {
    throw const FormatException('请求包含空字符，无法复制完整 cURL。');
  }
  return "'${text.replaceAll("'", "'\"'\"'")}'";
}

String networkStatusCategory(Map<String, dynamic> data) {
  final request = data['request'] is Map ? data['request'] as Map : const {};
  final response = data['response'] is Map ? data['response'] as Map : const {};
  if (request['error'] != null || response['error'] != null) return '失败';
  if (response['endTime'] == null) return '进行中';
  final code = response['statusCode'];
  return code is int && code >= 200 && code < 600 ? '${code ~/ 100}xx' : '其他';
}

bool matchesNetworkRequest(
  Map<String, dynamic> data, {
  String query = '',
  Set<String> methods = const {},
  Set<String> statuses = const {},
}) {
  final method = data['method']?.toString().toUpperCase() ?? '';
  final response = data['response'] is Map ? data['response'] as Map : const {};
  return (methods.isEmpty || methods.contains(method)) &&
      (statuses.isEmpty || statuses.contains(networkStatusCategory(data))) &&
      '$method ${data['uri']} ${response['statusCode']}'.toLowerCase().contains(
        query.trim().toLowerCase(),
      );
}
