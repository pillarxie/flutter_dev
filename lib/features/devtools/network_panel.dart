import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/presentation/workbench_models.dart';
import 'network_request_details.dart';
import 'network_format.dart';

class NetworkPanel extends StatefulWidget {
  const NetworkPanel({
    super.key,
    required this.bridge,
    required this.session,
    this.searchFocus,
  });
  final FocusNode? searchFocus;
  final WorkbenchBridge bridge;
  final Session? session;

  @override
  State<NetworkPanel> createState() => _NetworkPanelState();
}

class _NetworkPanelState extends State<NetworkPanel> {
  final _query = TextEditingController();
  final _methods = <String>{};
  final _statuses = <String>{};
  final _requests = <String, Map<String, dynamic>>{};
  final _enabled = <String>{};
  final _cursors = <String, int>{};
  final _clearedBefore = <String, int>{};
  Timer? _timer;
  int _epoch = 0, _selection = 0;
  int? _baselineEpoch;
  bool _loading = false, _paused = false, _detailLoading = false;
  String? _error, _detailError, _selected;
  Map<String, dynamic>? _detail;

  bool get _live => _isLive(widget.session);

  bool _isLive(Session? session) =>
      session?.mode == 'debug' &&
      const ['running', 'paused'].contains(session?.state) &&
      session?.operation != 'hotRestart' &&
      session?.serviceUri?.isNotEmpty == true &&
      session?.capabilities['debugger'] != false;

  @override
  void initState() {
    super.initState();
    _query.addListener(_searchChanged);
    unawaited(_refresh());
  }

  void _searchChanged() => setState(() {});

  @override
  void didUpdateWidget(NetworkPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.session;
    final next = widget.session;
    final changed =
        oldWidget.bridge != widget.bridge ||
        old?.id != next?.id ||
        old?.generation != next?.generation ||
        old?.serviceUri != next?.serviceUri ||
        (old?.operation != 'hotRestart' && next?.operation == 'hotRestart');
    if (changed) {
      _epoch++;
      _selection++;
      _timer?.cancel();
      _requests.clear();
      _enabled.clear();
      _cursors.clear();
      _clearedBefore.clear();
      _baselineEpoch = null;
      _selected = null;
      _detail = null;
      _detailLoading = false;
      _detailError = _error = null;
    }
    if (_live && !_loading && !_paused && (changed || !_isLive(old))) {
      unawaited(_refresh());
    }
    if (!_live) _timer?.cancel();
  }

  Future<Map<String, dynamic>> _rpc(
    int epoch,
    String sessionId,
    String method,
    Map<String, dynamic> args,
  ) async {
    if (!mounted || epoch != _epoch || !_live) throw const _StaleRequest();
    final result = await widget.bridge.networkRequest(sessionId, method, args);
    if (!mounted || epoch != _epoch || !_live) throw const _StaleRequest();
    if (result['type'] == 'Sentinel') throw StateError('Isolate 已退出，请重试。');
    return result;
  }

  Future<void> _refresh() async {
    _timer?.cancel();
    if (_loading || !_live || !mounted) return;
    setState(() => _loading = true);
    final epoch = _epoch;
    final sessionId = widget.session!.id;
    try {
      final vm = await _rpc(epoch, sessionId, 'getVM', {});
      final isolates = (vm['isolates'] as List? ?? []).whereType<Map>();
      final present = <String>{};
      String? isolateError;
      var supported = 0;
      for (final isolateRef in isolates) {
        final isolateId = isolateRef['id']?.toString();
        if (isolateId == null) continue;
        present.add(isolateId);
        try {
          if (!_enabled.contains(isolateId)) {
            final isolate = await _rpc(epoch, sessionId, 'getIsolate', {
              'isolateId': isolateId,
            });
            final extensions =
                isolate['extensionRPCs'] ??
                isolate['serviceExtensionRPCs'] ??
                [];
            if (extensions is! List ||
                !extensions.contains('ext.dart.io.getHttpProfile')) {
              continue;
            }
            final version = await _rpc(
              epoch,
              sessionId,
              'ext.dart.io.getVersion',
              {'isolateId': isolateId},
            );
            final major = version['major'] as int? ?? 0;
            final minor = version['minor'] as int? ?? 0;
            await _rpc(
              epoch,
              sessionId,
              'ext.dart.io.httpEnableTimelineLogging',
              {
                'isolateId': isolateId,
                (major >= 2 || major == 1 && minor >= 4) ? 'enabled' : 'enable':
                    true,
              },
            );
            _enabled.add(isolateId);
          }
          final profile =
              await _rpc(epoch, sessionId, 'ext.dart.io.getHttpProfile', {
                'isolateId': isolateId,
                if (_cursors[isolateId] != null)
                  'updatedSince': _cursors[isolateId],
              });
          supported++;
          final timestamp = profile['timestamp'];
          if (timestamp is int) {
            _cursors[isolateId] = timestamp;
            if (_baselineEpoch == epoch) _clearedBefore[isolateId] = timestamp;
          }
          for (final value
              in (profile['requests'] as List? ?? []).whereType<Map>()) {
            final request = Map<String, dynamic>.from(value);
            final id = request['id']?.toString();
            if (id == null) continue;
            final startTime = request['startTime'] as int? ?? 0;
            if (startTime <= (_clearedBefore[isolateId] ?? -1)) continue;
            request['isolateId'] = isolateId;
            _requests['$isolateId/$id'] = request;
          }
        } on _StaleRequest {
          rethrow;
        } catch (e) {
          // An isolate can disappear during hot restart; other isolates remain usable.
          _enabled.remove(isolateId);
          _cursors.remove(isolateId);
          isolateError = '$e';
        }
      }
      if (_baselineEpoch == epoch && supported > 0) _baselineEpoch = null;
      _enabled.removeWhere((id) => !present.contains(id));
      _cursors.removeWhere((id, _) => !present.contains(id));
      _clearedBefore.removeWhere((id, _) => !present.contains(id));
      _requests.removeWhere(
        (_, request) => !present.contains(request['isolateId']),
      );
      final sorted = _requests.entries.toList()
        ..sort((a, b) => _start(b.value).compareTo(_start(a.value)));
      for (final entry in sorted.skip(500)) {
        _requests.remove(entry.key);
      }
      if (_selected != null && !_requests.containsKey(_selected)) {
        _selection++;
        _selected = null;
        _detail = null;
        _detailLoading = false;
      }
      setState(
        () => _error = supported == 0
            ? isolateError ??
                  '等待 dart:io 网络扩展注册；Flutter Web 和未接入 profiling 的网络库不支持此面板。'
            : isolateError,
      );
      if (_selected != null &&
          !_detailLoading &&
          _detail != null &&
          _map(_detail!['response'])['endTime'] == null) {
        unawaited(_loadDetail(_selected!));
      }
    } on _StaleRequest {
      // Results from the previous session must never enter the current view.
    } catch (e) {
      if (mounted && epoch == _epoch) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (epoch != _epoch && _live && !_paused) {
          unawaited(_refresh());
        } else if (_live && !_paused) {
          _timer = Timer(const Duration(seconds: 1), _refresh);
        }
      }
    }
  }

  static int _start(Map<String, dynamic> request) =>
      request['startTime'] as int? ?? 0;

  Future<void> _loadDetail(String key) async {
    final request = _requests[key];
    if (request == null || !_live) return;
    final token = ++_selection;
    final epoch = _epoch;
    final sameSelection = _selected == key;
    setState(() {
      _selected = key;
      _detailLoading = true;
      _detailError = null;
      if (!sameSelection) _detail = null;
    });
    try {
      final value = await _rpc(
        epoch,
        widget.session!.id,
        'ext.dart.io.getHttpProfileRequest',
        {'isolateId': request['isolateId'], 'id': request['id']},
      );
      if (mounted && token == _selection && epoch == _epoch) {
        setState(() => _detail = value);
      }
    } on _StaleRequest {
      // Selection or session has changed while the body was fetched.
    } catch (e) {
      if (mounted && token == _selection && epoch == _epoch) {
        setState(() => _detailError = '$e');
      }
    } finally {
      if (mounted && token == _selection && epoch == _epoch) {
        setState(() => _detailLoading = false);
      }
    }
  }

  void _clear() {
    _selection++;
    _epoch++;
    // If a profile is already in flight, the next accepted profile establishes
    // the clear boundary using the VM clock, including the first refresh.
    if (_loading) _baselineEpoch = _epoch;
    setState(() {
      for (final entry in _cursors.entries) {
        _clearedBefore[entry.key] = entry.value;
      }
      _requests.clear();
      _selected = null;
      _detail = null;
      _detailError = null;
      _detailLoading = false;
    });
  }

  @override
  void dispose() {
    _epoch++;
    _timer?.cancel();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final query = _query.text.trim().toLowerCase();
    final requests =
        _requests.entries
            .where(
              (e) => matchesNetworkRequest(
                e.value,
                query: query,
                methods: _methods,
                statuses: _statuses,
              ),
            )
            .toList()
          ..sort((a, b) => _start(b.value).compareTo(_start(a.value)));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('network-search'),
                  controller: _query,
                  focusNode: widget.searchFocus,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: '搜索请求 URL、方法、状态码…',
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('network-pause'),
                tooltip: _paused ? '继续自动刷新' : '暂停自动刷新',
                color: _paused ? colors.primary : null,
                onPressed: () {
                  setState(() => _paused = !_paused);
                  if (_paused) {
                    _timer?.cancel();
                  } else {
                    unawaited(_refresh());
                  }
                },
                icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
              ),
              IconButton(
                key: const ValueKey('network-refresh'),
                tooltip: '刷新网络请求',
                onPressed: _live && !_loading ? _refresh : null,
                icon: const Icon(Icons.refresh),
              ),
              Tooltip(
                message: '清空全部本地请求（保留筛选条件）',
                child: TextButton.icon(
                  key: const ValueKey('network-clear'),
                  onPressed: _clear,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.onSurfaceVariant,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('清空', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _filter(
                'method',
                '方法',
                _methods,
                {
                  'GET',
                  'POST',
                  'PUT',
                  'PATCH',
                  'DELETE',
                  'HEAD',
                  'OPTIONS',
                  for (final request in _requests.values)
                    if (request['method'] != null)
                      request['method'].toString().toUpperCase(),
                }.toList()..sort(),
              ),
              _filter('status', '状态', _statuses, const [
                '2xx',
                '3xx',
                '4xx',
                '5xx',
                '进行中',
                '失败',
                '其他',
              ]),
              if (_methods.isNotEmpty ||
                  _statuses.isNotEmpty ||
                  query.isNotEmpty)
                TextButton(
                  key: const ValueKey('network-reset-filters'),
                  onPressed: () => setState(() {
                    _methods.clear();
                    _statuses.clear();
                    _query.clear();
                  }),
                  child: const Text('重置筛选'),
                ),
            ],
          ),
        ),
        // Refreshing must not move the request list or the selected details.
        SizedBox(
          height: 2,
          child: _loading ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _error!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.error, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: _live && !_loading ? _refresh : null,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        Expanded(
          child: !_live && _requests.isEmpty
              ? const Center(child: Text('选择已连接 VM Service 的 Debug 会话以查看网络请求。'))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final list = _requestList(requests);
                    final details = _details();
                    if (constraints.maxWidth < 720) {
                      if (_selected != null) {
                        return Column(
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () => setState(() {
                                  _selection++;
                                  _selected = null;
                                  _detail = null;
                                  _detailLoading = false;
                                }),
                                icon: const Icon(Icons.arrow_back, size: 16),
                                label: const Text('返回请求列表'),
                              ),
                            ),
                            Expanded(child: details),
                          ],
                        );
                      }
                      return list;
                    }
                    return Row(
                      children: [
                        SizedBox(
                          width: constraints.maxWidth * .38,
                          child: list,
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: details),
                      ],
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _paused
                      ? '自动刷新已暂停'
                      : _live
                      ? '每秒刷新 · dart:io HTTP'
                      : '等待连接',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ),
              Text(
                '${requests.length == _requests.length ? '' : '匹配 ${requests.length} · '}${_requests.length} / 500 条',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _requestList(List<MapEntry<String, Map<String, dynamic>>> requests) {
    if (requests.isEmpty) {
      return Center(
        child: Text(_requests.isEmpty ? '暂无请求；发起请求后会自动显示。' : '没有匹配的请求'),
      );
    }
    return ListView.builder(
      itemCount: requests.length,
      itemBuilder: (context, index) {
        final entry = requests[index];
        final request = entry.value;
        final response = _map(request['response']);
        final code = response['statusCode'];
        final failed =
            request['request'] is Map &&
                _map(request['request'])['error'] != null ||
            response['error'] != null ||
            code is int && code >= 400;
        final end = response['endTime'];
        final duration = end is int
            ? '${((end - _start(request)) / 1000).toStringAsFixed(0)} ms'
            : '进行中';
        final size = response['contentLength'];
        return GestureDetector(
          onSecondaryTapDown: (event) =>
              _requestMenu(entry.key, event.globalPosition),
          child: ListTile(
            key: ValueKey('network-request-${entry.key}'),
            selected: entry.key == _selected,
            onTap: () => _loadDetail(entry.key),
            title: Text(
              '${request['method'] ?? ''}  ${request['uri'] ?? ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            subtitle: Text(
              '${code ?? (failed ? '失败' : '等待响应')} · $duration${size is int && size >= 0 ? ' · $size bytes' : ''}',
              style: TextStyle(
                fontSize: 11,
                color: failed ? Theme.of(context).colorScheme.error : null,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _filter(
    String id,
    String label,
    Set<String> selected,
    List<String> values,
  ) => PopupMenuButton<String>(
    key: ValueKey('network-filter-$id'),
    tooltip: '筛选$label，可多选',
    onSelected: (value) => setState(() {
      if (!selected.remove(value)) selected.add(value);
    }),
    itemBuilder: (_) => [
      for (final value in values)
        CheckedPopupMenuItem(
          value: value,
          checked: selected.contains(value),
          child: Text(value),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Text(
        '$label：${selected.isEmpty ? '全部' : selected.join('、')}',
        style: const TextStyle(fontSize: 12),
      ),
    ),
  );

  Future<void> _requestMenu(String key, Offset position) async {
    final epoch = _epoch;
    final request = _requests[key];
    if (request == null || !_live) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: const [PopupMenuItem(value: 'curl', child: Text('复制 cURL'))],
    );
    if (action != 'curl' ||
        !mounted ||
        epoch != _epoch ||
        !_live ||
        !_requests.containsKey(key)) {
      return;
    }
    try {
      final detail = await _rpc(
        epoch,
        widget.session!.id,
        'ext.dart.io.getHttpProfileRequest',
        {'isolateId': request['isolateId'], 'id': request['id']},
      );
      final command = networkCurl(detail);
      await Clipboard.setData(ClipboardData(text: command));
      if (mounted && epoch == _epoch) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已复制 cURL（POSIX Shell）')));
      }
    } on _StaleRequest {
      // A menu action cannot change selection or copy an old session capture.
    } catch (error) {
      if (mounted && epoch == _epoch) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException ? error.message : '获取请求详情失败：$error',
            ),
          ),
        );
      }
    }
  }

  Widget _details() {
    if (_selected == null) {
      return const Center(child: Text('选择请求，查看解码后的参数和正文。'));
    }
    if (_detailLoading && _detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_detailError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_detailError!),
              TextButton(
                onPressed: _live ? () => _loadDetail(_selected!) : null,
                child: const Text('重试详情'),
              ),
            ],
          ),
        ),
      );
    }
    final data = _detail;
    if (data == null) return const SizedBox();
    return NetworkRequestDetails(
      key: ValueKey('network-detail-view-$_selected'),
      requestKey: _selected!,
      data: data,
    );
  }
}

Map<String, dynamic> _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

class _StaleRequest implements Exception {
  const _StaleRequest();
}
