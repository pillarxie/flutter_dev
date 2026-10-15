import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/presentation/workbench_models.dart';

class LogPanel extends StatefulWidget {
  const LogPanel({super.key, required this.bridge, required this.session});
  final WorkbenchBridge bridge;
  final Session? session;
  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  final _entries = <LogEntry>[];
  StreamSubscription<WorkbenchEvent>? _subscription;
  Timer? _timer;
  int _cursor = 0, _revision = 0, _dropped = 0;
  int _generation = 0, _sequence = -1;
  bool _loading = false, _pending = false, _follow = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _generation = widget.session?.generation ?? 0;
    _subscription = widget.bridge.events.listen((e) {
      if (e.sessionId != widget.session?.id || e.kind != 'logs') return;
      if (e.generation < _generation ||
          (e.generation == _generation && e.sequence <= _sequence)) {
        return;
      }
      if (e.generation > _generation) _reset();
      _generation = e.generation;
      _sequence = e.sequence;
      _schedule();
    });
    _query.addListener(() => _schedule(reset: true));
    _schedule();
  }

  @override
  void didUpdateWidget(LogPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session?.generation != widget.session?.generation) {
      _generation = widget.session?.generation ?? 0;
      _sequence = -1;
      _reset();
      _schedule();
    }
  }

  void _reset() {
    _revision++;
    _entries.clear();
    _cursor = 0;
    _dropped = 0;
    _error = null;
  }

  void _schedule({bool reset = false}) {
    if (reset) {
      setState(_reset);
    }
    _pending = true;
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: reset ? 250 : 80), _load);
  }

  Future<void> _load() async {
    if (_loading || widget.session == null || !mounted) return;
    _loading = true;
    _pending = false;
    final revision = _revision;
    try {
      final page = await widget.bridge.readLogs(
        widget.session!.id,
        afterId: _cursor,
        limit: 200,
        query: _query.text.trim(),
      );
      if (!mounted || revision != _revision) return;
      setState(() {
        _entries.addAll(page.entries);
        _cursor = page.nextAfterId;
        _dropped = page.droppedBeforeId;
        // A display window, independent from the core's bounded retention.
        if (_entries.length > 1000) {
          _entries.removeRange(0, _entries.length - 1000);
        }
        var characters = _entries.fold<int>(
          0,
          (sum, entry) => sum + entry.text.length,
        );
        while (characters > 512 * 1024 && _entries.isNotEmpty) {
          characters -= _entries.removeAt(0).text.length;
        }
        _error = null;
      });
      if (page.entries.length == 200) _pending = true;
      if (_follow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    } catch (e) {
      if (mounted && revision == _revision) setState(() => _error = '$e');
    } finally {
      _loading = false;
      if (_pending && mounted) _schedule();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _timer?.cancel();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final session = widget.session;
    final stateLabel = switch (session?.state) {
      'running' => '运行中',
      'paused' => '已暂停',
      'starting' => '启动中',
      'stopping' => '停止中',
      'ended' => '已结束',
      'failed' => '启动失败',
      _ => '等待会话',
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
        return Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 18, padding, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search, size: 19),
                        hintText: '搜索日志内容…',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: _follow ? '关闭跟随输出' : '跟随输出',
                    onPressed: () => setState(() => _follow = !_follow),
                    color: _follow ? colors.primary : colors.onSurfaceVariant,
                    icon: Icon(
                      _follow ? Icons.vertical_align_bottom : Icons.pause,
                      size: 19,
                    ),
                  ),
                  IconButton.outlined(
                    tooltip: '复制可见日志',
                    onPressed: _entries.isEmpty
                        ? null
                        : () => Clipboard.setData(
                            ClipboardData(
                              text: _entries.map((e) => e.text).join('\n'),
                            ),
                          ),
                    icon: const Icon(Icons.copy_outlined, size: 18),
                  ),
                  const SizedBox(width: 6),
                  IconButton.outlined(
                    tooltip: '重新读取日志',
                    onPressed: session == null
                        ? null
                        : () => _schedule(reset: true),
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
                ],
              ),
            ),
            if (session?.error != null || _error != null)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: padding, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    session?.error ?? _error!,
                    style: TextStyle(color: colors.error, height: 1.6),
                  ),
                ),
              ),
            Expanded(
              child: _entries.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.terminal_outlined,
                            size: 36,
                            color: colors.onSurfaceVariant.withValues(
                              alpha: .5,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            session == null ? '等待第一个会话' : '暂时没有匹配的日志',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                          if (session == null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                '选择项目、SDK 和设备后点击运行。',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: EdgeInsets.symmetric(
                        horizontal: padding,
                        vertical: 8,
                      ),
                      itemCount: _entries.length,
                      itemBuilder: (context, i) {
                        final entry = _entries[i];
                        final error = entry.category == 'stderr';
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 9),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 76,
                                child: Text(
                                  entry.category,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontFamilyFallback: const [
                                      '.AppleSystemUIFont',
                                      'PingFang SC',
                                      'Segoe UI',
                                      'Arial',
                                    ],
                                    fontSize: 11,
                                    height: 1.8,
                                    color: error
                                        ? colors.error
                                        : colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: SelectableText(
                                  entry.text,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontFamilyFallback: const [
                                      '.AppleSystemUIFont',
                                      'PingFang SC',
                                      'Segoe UI',
                                      'Arial',
                                    ],
                                    fontSize: 13,
                                    height: 1.65,
                                    color: error
                                        ? colors.error
                                        : colors.onSurface,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            Divider(height: 1, color: colors.outlineVariant),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: padding, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: session?.state == 'failed'
                          ? colors.error
                          : session?.active == true
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Text(
                    stateLabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Tooltip(
                    message: _dropped > 0
                        ? '最多展示 1000 条 / 512 Ki 字符；核心缓冲已轮转至 #$_dropped'
                        : '最多展示最近 1000 条 / 512 Ki 字符',
                    child: Text(
                      '${_entries.length} 条日志',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
