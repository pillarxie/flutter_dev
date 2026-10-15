import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'network_format.dart';
import 'network_payload_tree.dart';

class NetworkRequestDetails extends StatefulWidget {
  const NetworkRequestDetails({
    super.key,
    required this.data,
    required this.requestKey,
  });
  final Map<String, dynamic> data;
  final String requestKey;

  @override
  State<NetworkRequestDetails> createState() => _NetworkRequestDetailsState();
}

class _NetworkRequestDetailsState extends State<NetworkRequestDetails> {
  static const _tabs = ['headers', 'parameters', 'response'];
  static const _labels = ['请求头', '参数', '响应'];
  static const _mono = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['PingFang SC', 'Arial'],
    fontSize: 12,
    height: 1.6,
  );
  final _scrolls = List.generate(3, (_) => ScrollController());
  final _raw = <String, bool>{};
  final _payloadExpanded = <String, bool>{};
  int _tab = 1;
  late NetworkContent _query,
      _requestBody,
      _requestHeaders,
      _responseBody,
      _responseHeaders;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(NetworkRequestDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.requestKey != widget.requestKey) {
      _tab = 1;
      _raw.clear();
      _payloadExpanded.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final scroll in _scrolls) {
          if (scroll.hasClients) scroll.jumpTo(0);
        }
      });
    }
    if (oldWidget.data != widget.data ||
        oldWidget.requestKey != widget.requestKey) {
      _prepare();
    }
  }

  void _prepare() {
    final request = _map(widget.data['request']);
    final response = _map(widget.data['response']);
    _query = formatNetworkQuery(widget.data['uri']?.toString() ?? '');
    _requestBody = formatNetworkBody(
      widget.data['requestBody'],
      networkContentType(request),
    );
    _responseBody = formatNetworkBody(
      widget.data['responseBody'],
      networkContentType(response),
    );
    _requestHeaders = _headers(request);
    _responseHeaders = _headers(response);
  }

  String _preview(String value) => value.length > networkPreviewLimit
      ? value.substring(0, networkPreviewLimit)
      : value;

  NetworkContent _headers(Map<String, dynamic> data) {
    final headers = data['headers'];
    if (headers is! Map || headers.isEmpty) {
      return const NetworkContent(raw: '', formatted: '');
    }
    final raw = const JsonEncoder.withIndent('  ').convert(headers);
    final fields = <NetworkField>[];
    var remaining = networkPreviewLimit;
    final totalFields = headers.values.fold<int>(
      0,
      (count, value) => count + (value is List ? math.max(1, value.length) : 1),
    );
    var limited = raw.length > networkPreviewLimit || totalFields > 500;
    for (final entry in headers.entries) {
      final values = entry.value is List ? entry.value as List : [entry.value];
      for (final value in values.isEmpty ? [''] : values) {
        if (remaining <= 0 || fields.length == 500) {
          limited = true;
          break;
        }
        final name = entry.key.toString();
        final text = value?.toString() ?? '';
        final row = '$name: $text';
        final preview = row.length > remaining
            ? row.substring(0, remaining)
            : row;
        limited = limited || preview.length < row.length;
        final separator = preview.indexOf(': ');
        fields.add(
          separator < 0
              ? NetworkField(preview, '')
              : NetworkField(
                  preview.substring(0, separator),
                  preview.substring(separator + 2),
                ),
        );
        remaining -= preview.length + 1;
      }
      if (remaining <= 0 || fields.length == 500) break;
    }
    return NetworkContent(
      raw: _preview(raw),
      formatted: fields.map((f) => '${f.name}: ${f.value}').join('\n'),
      fields: fields,
      note: limited ? 'Headers 较多，仅展示和复制前 128 Ki 字符 / 500 个字段。' : null,
    );
  }

  @override
  void dispose() {
    for (final controller in _scrolls) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: ValueKey('network-details-${widget.requestKey}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _summary(context),
        Row(
          children: [
            for (var index = 0; index < _tabs.length; index++)
              Expanded(
                child: InkWell(
                  key: ValueKey('network-detail-tab-${_tabs[index]}'),
                  onTap: () => setState(() => _tab = index),
                  child: Semantics(
                    selected: _tab == index,
                    button: true,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: _tab == index
                                ? colors.primary
                                : colors.outlineVariant,
                            width: _tab == index ? 2 : 1,
                          ),
                        ),
                      ),
                      child: Text(
                        _labels[index],
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: _tab == index
                              ? colors.primary
                              : colors.onSurfaceVariant,
                          fontWeight: _tab == index
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              _tabContent(0, [
                _section(
                  'request-headers',
                  '请求 Headers',
                  _requestHeaders,
                  empty: '没有请求 Headers',
                ),
              ]),
              _tabContent(1, [
                _section('query', 'Query 参数', _query, empty: '没有 Query 参数'),
                _section('request-body', '请求正文', _requestBody, empty: '没有请求正文'),
                if (_map(widget.data['request'])['error'] != null)
                  _failure(_map(widget.data['request'])['error']),
              ]),
              _tabContent(2, [
                _section(
                  'response-body',
                  '响应正文',
                  _responseBody,
                  empty: '响应正文为空',
                ),
                _section(
                  'response-headers',
                  '响应 Headers',
                  _responseHeaders,
                  empty: '尚未收到响应 Headers',
                ),
                if (_map(widget.data['response'])['error'] != null)
                  _failure(_map(widget.data['response'])['error']),
              ]),
            ],
          ),
        ),
      ],
    );
  }

  Widget _summary(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final data = widget.data;
    final response = _map(data['response']);
    final error = _map(data['request'])['error'] ?? response['error'];
    final original = data['uri']?.toString() ?? '';
    var endpoint = original.split('?').first.split('#').first;
    final parsed = Uri.tryParse(original);
    if (parsed != null && parsed.hasAuthority) {
      endpoint = Uri(
        scheme: parsed.scheme,
        host: parsed.host,
        port: parsed.hasPort ? parsed.port : null,
        path: parsed.path,
      ).toString();
    }
    final code = response['statusCode'];
    final failed = error != null || code is int && code >= 400;
    final status = code == null
        ? error != null
              ? '请求失败'
              : '等待响应'
        : '$code${response['reasonPhrase'] == null ? '' : ' ${response['reasonPhrase']}'}';
    final start = data['startTime'];
    final end = response['endTime'];
    final duration = start is int && end is int
        ? '${(math.max(0, end - start) / 1000).toStringAsFixed(0)} ms'
        : '进行中';
    final length = response['contentLength'];
    final bytes = length is int && length >= 0
        ? length
        : data['responseBody'] is List
        ? (data['responseBody'] as List).length
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 3),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 64),
                  child: Text(
                    data['method']?.toString() ?? 'HTTP',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: colors.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Tooltip(
                    message: original,
                    child: Text(
                      endpoint.isEmpty ? '未知请求地址' : endpoint,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '复制完整请求 URL',
                onPressed: original.isEmpty
                    ? null
                    : () => Clipboard.setData(ClipboardData(text: original)),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.copy_outlined, size: 15),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: failed
                          ? colors.error
                          : code == null
                          ? colors.onSurfaceVariant
                          : colors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: failed ? colors.error : colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                duration,
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
              if (bytes != null)
                Text(
                  _size(bytes),
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _size(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';

  Widget _tabContent(int tab, List<Widget> children) => ListView(
    key: ValueKey('network-details-scroll-${widget.requestKey}-${_tabs[tab]}'),
    controller: _scrolls[tab],
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
    children: children,
  );

  Widget _failure(dynamic error) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: SelectableText(
      _preview(error.toString()),
      style: _mono.copyWith(color: Theme.of(context).colorScheme.error),
    ),
  );

  Widget _section(
    String id,
    String title,
    NetworkContent content, {
    required String empty,
  }) {
    final colors = Theme.of(context).colorScheme;
    final raw = _raw[id] == true;
    final originalText = raw ? content.raw : content.formatted;
    final text = _preview(originalText);
    final truncated = originalText.length > networkPreviewLimit;
    var fields = content.fields;
    var jsonBody = false;
    if (id == 'request-body' && fields.isEmpty && !raw) {
      try {
        final body = jsonDecode(content.formatted);
        if (body is Map &&
            (body['payload'] is Map || body['payload'] is List)) {
          fields = [
            for (final entry in body.entries)
              NetworkField(
                entry.key.toString(),
                const JsonEncoder.withIndent('  ').convert(entry.value),
              ),
          ];
          jsonBody = true;
        }
      } on FormatException {
        // Invalid or preview-truncated JSON remains ordinary selectable text.
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (content.fields.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          '${content.fields.length}',
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              TextButton(
                key: ValueKey('network-detail-raw-$id'),
                onPressed: text.isEmpty
                    ? null
                    : () => setState(() => _raw[id] = !raw),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(
                  raw ? '格式化' : '原始',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              IconButton(
                tooltip: '复制$title${raw ? '原始' : '格式化'}内容',
                onPressed: text.isEmpty
                    ? null
                    : () => Clipboard.setData(ClipboardData(text: text)),
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.copy_outlined, size: 15),
              ),
            ],
          ),
          if (content.note != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Text(
                content.note!,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.6,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          if (truncated)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '格式化内容较长，仅展示和复制前 128 Ki 字符。',
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
            ),
          if (!raw && fields.isNotEmpty)
            _fields(fields, payload: id == 'request-body', jsonBody: jsonBody)
          else if (text.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                content.note == null ? empty : '（无可展示的文本）',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(text, style: _mono),
            ),
        ],
      ),
    );
  }

  Widget _fieldValue(
    NetworkField field, {
    required String identity,
    required bool payload,
  }) {
    if (payload && field.name == 'payload') {
      try {
        final value = jsonDecode(field.value);
        if (value is Map || value is List) {
          return NetworkPayloadTree(
            value: value as Object,
            identity: identity,
            expanded: _payloadExpanded,
            onToggle: (id) => setState(
              () => _payloadExpanded[id] =
                  !(_payloadExpanded[id] ?? _defaultExpanded(id)),
            ),
          );
        }
      } on FormatException {
        // No additional decoding: malformed JSON is shown exactly as text.
      }
    }
    return SelectableText(
      field.value.isEmpty ? '(空值)' : field.value,
      style: _mono,
    );
  }

  bool _defaultExpanded(String id) =>
      '/'.allMatches(id.substring(id.indexOf(r'$') + 1)).length <= 1;

  Widget _fields(
    List<NetworkField> fields, {
    bool payload = false,
    bool jsonBody = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    var remaining = networkPreviewLimit;
    final visible = <NetworkField>[];
    for (final field in fields.take(500)) {
      if (remaining <= 0) break;
      final name = field.name.length > remaining
          ? field.name.substring(0, remaining)
          : field.name;
      remaining -= name.length;
      final value = field.value.length > remaining
          ? field.value.substring(0, remaining)
          : field.value;
      remaining -= value.length + 1;
      visible.add(NetworkField(name, value));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final nameWidth = (constraints.maxWidth * .3)
            .clamp(66.0, 140.0)
            .toDouble();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < visible.length; index++)
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: colors.outlineVariant.withValues(alpha: .65),
                    ),
                  ),
                ),
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: nameWidth,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: SelectableText(
                          visible[index].name.isEmpty
                              ? '(空参数名)'
                              : visible[index].name,
                          style: _mono.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _fieldValue(
                        visible[index],
                        identity: jsonBody ? 'json-payload' : 'form-$index',
                        payload: payload,
                      ),
                    ),
                  ],
                ),
              ),
            if (visible.length < fields.length)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '字段较多，仅展示前 500 个 / 128 Ki 字符。',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

Map<String, dynamic> _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
