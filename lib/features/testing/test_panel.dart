import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/presentation/workbench_models.dart';

/// A bounded view of a core-owned test run. Closing this view leaves it running.
class TestPanel extends StatefulWidget {
  const TestPanel({
    super.key,
    required this.bridge,
    required this.project,
    this.sdkPreference,
  });

  final WorkbenchBridge bridge;
  final Project project;
  final String? sdkPreference;

  @override
  State<TestPanel> createState() => _TestPanelState();
}

class _TestPanelState extends State<TestPanel> {
  List<String> _files = [];
  TestRunSnapshot? _snapshot;
  final _logs = <LogEntry>[];
  Timer? _timer;
  int _revision = 0, _cursor = 0;
  int? _pollingRevision;
  bool _loading = true, _starting = false, _stopping = false;
  bool _logsDropped = false;
  String? _error;

  bool get _busy => _loading || _starting || (_snapshot?.active ?? false);

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didUpdateWidget(TestPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.path != widget.project.path ||
        oldWidget.bridge != widget.bridge) {
      _initialize();
    }
  }

  Future<void> _initialize() async {
    final revision = ++_revision;
    _timer?.cancel();
    setState(() {
      _files = [];
      _snapshot = null;
      _logs.clear();
      _cursor = 0;
      _logsDropped = false;
      _loading = true;
      _starting = false;
      _stopping = false;
      _error = null;
    });
    try {
      final results = await Future.wait<Object>([
        widget.bridge.discoverTestFiles(widget.project.path),
        widget.bridge.listTestRuns(),
      ]);
      if (!mounted || revision != _revision) return;
      final runs = (results[1] as List<TestRunSnapshot>)
          .where((run) => run.projectPath == widget.project.path)
          .toList();
      final active = runs.where((run) => run.active).firstOrNull;
      setState(() {
        _files = (results[0] as List<String>).toSet().toList()..sort();
        _snapshot = active ?? runs.firstOrNull;
      });
    } catch (error) {
      if (mounted && revision == _revision) {
        setState(() => _error = '读取测试失败：$error');
      }
    } finally {
      if (mounted && revision == _revision) {
        setState(() => _loading = false);
        if (_snapshot != null) _poll();
      }
    }
  }

  Future<void> _start([List<TestSelection> selections = const []]) async {
    if (_busy) return;
    final revision = ++_revision;
    _timer?.cancel();
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final snapshot = await widget.bridge.startTestRun(
        TestRunConfig(
          projectPath: widget.project.path,
          sdkPath: widget.sdkPreference,
          selections: selections,
        ),
      );
      if (!mounted || revision != _revision) return;
      setState(() {
        _snapshot = snapshot;
        _logs.clear();
        _cursor = 0;
        _logsDropped = false;
      });
      _poll();
    } catch (error) {
      if (mounted && revision == _revision) {
        setState(() => _error = '启动测试失败：$error');
      }
    } finally {
      if (mounted && revision == _revision) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _poll() async {
    final snapshot = _snapshot;
    final revision = _revision;
    if (!mounted || snapshot == null || _pollingRevision == revision) return;
    _pollingRevision = revision;
    bool more = false;
    bool failed = false;
    try {
      // Terminal snapshots are published after their final output. Read the
      // snapshot first so an earlier, short log page cannot hide the tail.
      final next = await widget.bridge.testRunSnapshot(snapshot.id);
      if (!mounted || revision != _revision) return;
      final page = await widget.bridge.readTestLogs(
        snapshot.id,
        afterId: _cursor,
        limit: 200,
      );
      if (!mounted || revision != _revision) return;
      more = page.entries.length == 200 && page.nextAfterId > _cursor;
      setState(() {
        _snapshot = next;
        _cursor = page.nextAfterId;
        _logs.addAll(page.entries);
        _logsDropped = _logsDropped || page.droppedBeforeId > 0;
        if (_logs.length > 1000) {
          _logs.removeRange(0, _logs.length - 1000);
          _logsDropped = true;
        }
        var characters = _logs.fold<int>(
          0,
          (sum, log) => sum + log.text.length,
        );
        while (characters > 512 * 1024 && _logs.isNotEmpty) {
          characters -= _logs.removeAt(0).text.length;
          _logsDropped = true;
        }
        _error = null;
      });
    } catch (error) {
      failed = true;
      if (mounted && revision == _revision) {
        setState(() => _error = '刷新测试状态失败：$error');
      }
    } finally {
      if (_pollingRevision == revision) _pollingRevision = null;
      if (mounted && revision == _revision) {
        _timer?.cancel();
        if (more || failed || (_snapshot?.active ?? false)) {
          _timer = Timer(
            Duration(
              milliseconds: more
                  ? 50
                  : failed
                  ? 1500
                  : 500,
            ),
            _poll,
          );
        }
      }
    }
  }

  Future<void> _stop() async {
    final snapshot = _snapshot;
    if (snapshot == null || !snapshot.active || _stopping) return;
    final revision = _revision;
    setState(() => _stopping = true);
    try {
      await widget.bridge.stopTestRun(snapshot.id);
      if (mounted && revision == _revision) await _poll();
    } catch (error) {
      if (mounted && revision == _revision) {
        setState(() => _error = '停止测试失败，可重试：$error');
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _stopping = false);
    }
  }

  String _relativePath(String path) {
    if (path.startsWith('file:')) {
      try {
        path = Uri.parse(path).toFilePath();
      } on FormatException {
        // Keep the original path if a machine event contains an invalid URI.
      }
    }
    path = path.replaceAll('\\', '/');
    final root = widget.project.path.replaceAll('\\', '/');
    return path.startsWith('$root/') ? path.substring(root.length + 1) : path;
  }

  String _status(String state) => switch (state) {
    'starting' => '准备中',
    'running' => '运行中',
    'stopping' => '停止中',
    'passed' || 'success' || 'succeeded' => '通过',
    'failed' || 'failure' || 'error' => '失败',
    'skipped' => '已跳过',
    'cancelled' => '已取消',
    _ => state,
  };

  bool _failed(TestResult result) =>
      const {'failed', 'failure', 'error'}.contains(result.status);

  Widget _testRow(TestResult result) {
    final colors = Theme.of(context).colorScheme;
    final detail = [
      result.error,
      result.stackTrace,
    ].whereType<String>().where((text) => text.isNotEmpty).join('\n');
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: ExpansionTile(
        key: ValueKey('test-result-${result.id}'),
        tilePadding: const EdgeInsets.only(left: 4),
        leading: Icon(
          _failed(result)
              ? Icons.error_outline
              : result.status == 'running'
              ? Icons.hourglass_top
              : result.status == 'skipped'
              ? Icons.skip_next_outlined
              : Icons.check_circle_outline,
          color: _failed(result) ? colors.error : colors.primary,
          size: 18,
        ),
        title: Text(result.name, style: const TextStyle(fontSize: 12)),
        subtitle: Text(
          _status(result.status),
          style: const TextStyle(fontSize: 11),
        ),
        trailing: IconButton(
          tooltip: '运行此测试',
          onPressed: _busy
              ? null
              : () => _start([
                  TestSelection(
                    path: _relativePath(result.path),
                    name: result.name,
                  ),
                ]),
          icon: const Icon(Icons.play_arrow, size: 20),
        ),
        children: [
          if (detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                detail,
                style: TextStyle(fontSize: 12, color: colors.error),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('此测试没有错误详情', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  List<Widget> _tree(
    List<String> files,
    String prefix,
    Map<String, List<TestResult>> testsByFile,
  ) {
    final children = <String, List<String>>{};
    for (final file in files) {
      final rest = file.substring(prefix.length);
      final name = rest.split('/').first;
      children.putIfAbsent(name, () => []).add(file);
    }
    return [
      for (final entry in children.entries)
        if (entry.value.any(
          (file) => file.substring(prefix.length).contains('/'),
        ))
          ExpansionTile(
            key: ValueKey('${widget.project.path}:$prefix${entry.key}/'),
            initiallyExpanded: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: const Icon(Icons.folder_outlined, size: 18),
            title: Text(entry.key, style: const TextStyle(fontSize: 13)),
            childrenPadding: const EdgeInsets.only(left: 12),
            children: _tree(entry.value, '$prefix${entry.key}/', testsByFile),
          )
        else
          _fileRow(
            entry.value.single,
            testsByFile[entry.value.single] ?? const [],
          ),
    ];
  }

  Widget _fileRow(String path, List<TestResult> tests) {
    return ExpansionTile(
      key: ValueKey('${widget.project.path}:$path'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const Icon(Icons.description_outlined, size: 18),
      title: Text(path.split('/').last, style: const TextStyle(fontSize: 13)),
      subtitle: tests.isEmpty
          ? null
          : Text('${tests.length} 项测试', style: const TextStyle(fontSize: 11)),
      trailing: IconButton(
        key: ValueKey('test-file-run-$path'),
        tooltip: '运行 $path',
        onPressed: _busy ? null : () => _start([TestSelection(path: path)]),
        icon: const Icon(Icons.play_arrow, size: 20),
      ),
      children: tests.isEmpty
          ? const [
              Padding(
                padding: EdgeInsets.all(12),
                child: Text('运行后显示实际测试用例', style: TextStyle(fontSize: 12)),
              ),
            ]
          : tests.map(_testRow).toList(),
    );
  }

  @override
  void dispose() {
    _revision++;
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final snapshot = _snapshot;
    final testsByFile = <String, List<TestResult>>{};
    for (final test in snapshot?.tests ?? const <TestResult>[]) {
      testsByFile.putIfAbsent(_relativePath(test.path), () => []).add(test);
    }
    final files = {..._files.map(_relativePath), ...testsByFile.keys}.toList()
      ..sort();
    final failures = snapshot?.tests.where(_failed).toList() ?? <TestResult>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                key: const Key('test-run-all'),
                onPressed: _busy || files.isEmpty ? null : () => _start(),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(_starting ? '启动中…' : '运行全部'),
              ),
              OutlinedButton.icon(
                key: const Key('test-rerun-failed'),
                onPressed: _busy || failures.isEmpty
                    ? null
                    : () => _start([
                        for (final result in failures)
                          TestSelection(
                            path: _relativePath(result.path),
                            name: result.name,
                          ),
                      ]),
                icon: const Icon(Icons.replay, size: 18),
                label: const Text('重跑失败'),
              ),
              if (snapshot?.active ?? false)
                OutlinedButton.icon(
                  key: const Key('test-stop'),
                  onPressed: _stopping || snapshot?.state == 'stopping'
                      ? null
                      : _stop,
                  icon: const Icon(Icons.stop, size: 18),
                  label: Text(_stopping ? '停止中…' : '停止'),
                ),
              IconButton(
                key: const Key('test-refresh'),
                tooltip: '刷新测试',
                onPressed: _loading || _starting
                    ? null
                    : () {
                        if (snapshot?.active ?? false) {
                          _poll();
                        } else {
                          _initialize();
                        }
                      },
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
        ),
        if (_loading || _starting || (snapshot?.active ?? false))
          const LinearProgressIndicator(minHeight: 2),
        if (snapshot != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '${_status(snapshot.state)} · 通过 ${snapshot.passed} · 失败 ${snapshot.failed} · 跳过 ${snapshot.skipped}${snapshot.exitCode == null ? '' : ' · 退出码 ${snapshot.exitCode}'}',
              style: TextStyle(
                fontSize: 12,
                color: snapshot.state == 'failed'
                    ? colors.error
                    : colors.onSurfaceVariant,
              ),
            ),
          ),
        for (final error in [_error, snapshot?.error])
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SelectableText(
                error,
                style: TextStyle(fontSize: 12, color: colors.error),
              ),
            ),
        Expanded(
          child: _loading
              ? const Center(child: Text('正在读取测试文件…'))
              : files.isEmpty
              ? const Center(child: Text('未发现测试文件'))
              : ListView(
                  key: const Key('test-file-tree'),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    ..._tree(files, '', testsByFile),
                    if (_logs.isNotEmpty)
                      ExpansionTile(
                        key: const Key('test-output'),
                        tilePadding: EdgeInsets.zero,
                        title: const Text(
                          '测试输出',
                          style: TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          _logsDropped
                              ? '仅展示最近 1000 条 / 512 Ki 字符'
                              : '${_logs.length} 条输出',
                          style: const TextStyle(fontSize: 11),
                        ),
                        children: [
                          for (final entry in _logs)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: SelectableText(
                                entry.text,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: entry.category == 'stderr'
                                      ? colors.error
                                      : colors.onSurface,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '关闭面板后测试继续运行',
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
