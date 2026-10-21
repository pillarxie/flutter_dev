import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/presentation/workbench_models.dart';
import 'embedded_devtools_view.dart';
import 'network_panel.dart';

typedef EmbeddedDevToolsBuilder =
    Widget Function(
      BuildContext context,
      String url,
      ValueChanged<String> onError,
    );

class DevToolsPanel extends StatefulWidget {
  const DevToolsPanel({
    super.key,
    required this.bridge,
    required this.session,
    this.embeddedViewBuilder,
    this.searchFocus,
  });

  final WorkbenchBridge bridge;
  final Session? session;
  final EmbeddedDevToolsBuilder? embeddedViewBuilder;
  final FocusNode? searchFocus;

  @override
  State<DevToolsPanel> createState() => _DevToolsPanelState();
}

class _DevToolsPanelState extends State<DevToolsPanel> {
  static const _modules = <String, String>{
    'network': '网络请求',
    'inspector': 'Inspector',
    'performance': '性能',
    'cpu': 'CPU',
    'memory': '内存',
    'logging': '日志',
  };
  // Bridge queues outlive an individual panel, including rapid close/reopen
  // of the same session while a server launch is still pending.
  static final _bridgeQueues = Expando<Future<void>>();

  String _module = 'network';
  String? _url, _error, _embeddedError, _openedSession;
  WorkbenchBridge? _openedBridge;
  bool _loading = false;
  int _revision = 0, _viewRevision = 0;
  Future<void> _operations = Future<void>.value();

  String? _unavailable(Session? session) {
    if (session == null) return '选择会话后使用 DevTools。';
    if (!session.active) return '会话已结束。选择运行中的会话后重新连接 DevTools。';
    if (session.mode == 'release') {
      return 'Release 模式不提供 DevTools，请运行 Debug 或 Profile 会话。';
    }
    if (_module == 'inspector' && session.mode != 'debug') {
      return 'Inspector 需要 Debug 会话。性能、CPU 和内存可用于 Profile 会话。';
    }
    if (session.operation == 'hotRestart') return '热重启中，等待 VM Service 重新连接…';
    if (!const ['running', 'paused'].contains(session.state) ||
        session.serviceUri?.isNotEmpty != true) {
      return '等待会话连接 VM Service…';
    }
    return null;
  }

  @override
  void didUpdateWidget(DevToolsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.session;
    final next = widget.session;
    final connectionChanged =
        oldWidget.bridge != widget.bridge ||
        previous?.id != next?.id ||
        previous?.generation != next?.generation ||
        previous?.serviceUri != next?.serviceUri ||
        previous?.operation == 'hotRestart' &&
            next?.operation != 'hotRestart' ||
        previous?.operation != 'hotRestart' &&
            next?.operation == 'hotRestart' ||
        _unavailable(previous) != _unavailable(next);
    if (connectionChanged && _module != 'network') {
      _url = null;
      _viewRevision++;
      _bind();
    }
  }

  void _select(String module) {
    if (_module == module) return;
    setState(() {
      _module = module;
      _error = _embeddedError = null;
      if (module == 'network') _url = null;
    });
    _bind();
  }

  Future<void> _closeOpened() async {
    final bridge = _openedBridge;
    final sessionId = _openedSession;
    if (bridge == null || sessionId == null) return;
    await bridge.closeDevTools(sessionId);
    _openedBridge = null;
    _openedSession = null;
  }

  void _enqueue(WorkbenchBridge bridge, Future<void> Function() operation) {
    final bridgePrevious = _bridgeQueues[bridge] ?? Future<void>.value();
    final ownPrevious = _operations;
    final next = Future.wait([
      bridgePrevious,
      ownPrevious,
    ]).then((_) => operation());
    _operations = next;
    _bridgeQueues[bridge] = next;
  }

  void _bind() {
    final revision = ++_revision;
    final session = widget.session;
    final bridge = widget.bridge;
    final module = _module;
    final available = module != 'network' && _unavailable(session) == null;
    setState(() {
      _loading = available;
      _error = _embeddedError = null;
    });
    // Opening and closing share one queue. A late open is closed before the
    // next binding starts, so its cleanup cannot stop a newly opened server.
    _enqueue(bridge, () async {
      if (revision != _revision) return;
      try {
        if (!available ||
            _openedBridge != bridge ||
            _openedSession != session!.id) {
          await _closeOpened();
        }
        if (!available || revision != _revision || !mounted) return;
        final url = await bridge.openDevTools(session!.id, module);
        _openedBridge = bridge;
        _openedSession = session.id;
        if (revision != _revision || !mounted) {
          await _closeOpened();
          return;
        }
        setState(() {
          _url = url;
          _loading = false;
        });
      } catch (e) {
        if (mounted && revision == _revision) {
          setState(() {
            _loading = false;
            _error = '$e';
          });
        }
      }
    });
  }

  void _retry() {
    _viewRevision++;
    _url = null;
    _bind();
  }

  Future<void> _openExternal() async {
    final url = _url;
    if (url == null) return;
    try {
      final opened = await launchUrl(
        Uri.parse(_themedUrl(url)),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) {
        setState(() => _embeddedError = '系统浏览器未能打开 DevTools，请重试。');
      }
    } catch (e) {
      if (mounted) setState(() => _embeddedError = '系统浏览器打开失败：$e');
    }
  }

  @override
  void dispose() {
    _revision++;
    // The queue owns cleanup even after this widget has left the workbench.
    _enqueue(_openedBridge ?? widget.bridge, () async {
      try {
        await _closeOpened();
      } catch (_) {
        // Backend session cleanup also owns server termination.
      }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.outlineVariant)),
          ),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        for (final entry in _modules.entries)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: TextButton(
                              key: ValueKey('devtools-module-${entry.key}'),
                              style: TextButton.styleFrom(
                                foregroundColor: _module == entry.key
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                                backgroundColor: _module == entry.key
                                    ? colors.primaryContainer
                                    : null,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                minimumSize: const Size(0, 32),
                              ),
                              onPressed: () => _select(entry.key),
                              child: Text(
                                entry.value,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_module != 'network')
                IconButton(
                  key: const ValueKey('devtools-open-browser'),
                  tooltip: '在浏览器中打开',
                  onPressed:
                      _url != null &&
                          !_loading &&
                          _unavailable(widget.session) == null
                      ? _openExternal
                      : null,
                  icon: const Icon(Icons.open_in_new, size: 18),
                ),
              if (_module != 'network')
                IconButton(
                  key: const ValueKey('devtools-reconnect'),
                  tooltip: '重新连接 DevTools',
                  onPressed: !_loading && _unavailable(widget.session) == null
                      ? _retry
                      : null,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
            ],
          ),
        ),
        Expanded(
          child: _module == 'network'
              ? NetworkPanel(
                  searchFocus: widget.searchFocus,
                  key: ValueKey('devtools-network-${widget.session?.id}'),
                  bridge: widget.bridge,
                  session: widget.session,
                )
              : _officialView(context),
        ),
      ],
    );
  }

  Widget _officialView(BuildContext context) {
    final unavailable = _unavailable(widget.session);
    if (unavailable != null) return _message(unavailable);
    if (_error != null) return _message('DevTools 启动失败：$_error', retry: true);
    if (_embeddedError != null) {
      return _message(
        'DevTools 内嵌页面加载失败：$_embeddedError',
        retry: true,
        external: true,
      );
    }
    final url = _url == null ? null : _themedUrl(_url!);
    final revision = _revision;
    return Stack(
      children: [
        if (url != null)
          Positioned.fill(
            child: KeyedSubtree(
              key: ValueKey('devtools-webview-$_viewRevision'),
              child: (widget.embeddedViewBuilder ?? _embeddedView)(context, url, (
                message,
              ) {
                if (!mounted || revision != _revision) return;
                // Native load callbacks can arrive during a frame; report them after it.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && revision == _revision) {
                    setState(() => _embeddedError = message);
                  }
                });
              }),
            ),
          ),
        if (_loading || url == null)
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('正在连接 DevTools…'),
              ],
            ),
          ),
      ],
    );
  }

  String _themedUrl(String url) {
    final uri = Uri.parse(url);
    return uri
        .replace(
          queryParameters: {
            ...uri.queryParametersAll,
            'theme': [Theme.of(context).brightness.name],
          },
        )
        .toString();
  }

  static Widget _embeddedView(
    BuildContext context,
    String url,
    ValueChanged<String> onError,
  ) => EmbeddedDevToolsView(url: url, onError: onError);

  Widget _message(
    String message, {
    bool retry = false,
    bool external = false,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.developer_mode, size: 32),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (retry || external)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (retry)
                    OutlinedButton(
                      onPressed: _retry,
                      child: const Text('重试内嵌页面'),
                    ),
                  if (external)
                    OutlinedButton.icon(
                      onPressed: _openExternal,
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('在浏览器中打开'),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
