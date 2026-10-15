import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/presentation/workbench_models.dart';
import '../../core/presentation/workbench_select.dart';

class DebuggerPanel extends StatefulWidget {
  const DebuggerPanel({super.key, required this.bridge, required this.session});
  final WorkbenchBridge bridge;
  final Session? session;
  @override
  State<DebuggerPanel> createState() => _DebuggerPanelState();
}

class _DebuggerPanelState extends State<DebuggerPanel> {
  final _path = TextEditingController();
  final _arguments = TextEditingController(text: '{}');
  final _lines = TextEditingController();
  final _thread = TextEditingController();
  final _expression = TextEditingController();
  String _command = 'threads';
  String? _error, _result;
  List<String> _source = [];
  bool _busy = false;
  int _revision = 0;
  ColorScheme get _colors => Theme.of(context).colorScheme;
  bool get _canDebug =>
      widget.session?.mode == 'debug' &&
      widget.session?.active == true &&
      widget.session?.capabilities['debugger'] == true;

  Future<void> _run(Future<void> Function() action) async {
    final revision = ++_revision;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted && revision == _revision) setState(() => _error = '$e');
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
    }
  }

  Future<void> _request(String command, Map<String, dynamic> arguments) async {
    final session = widget.session!;
    final result = await widget.bridge.debuggerRequest(
      session.id,
      command,
      arguments,
    );
    if (mounted &&
        widget.session?.id == session.id &&
        widget.session?.generation == session.generation) {
      setState(
        () => _result = const JsonEncoder.withIndent('  ').convert(result),
      );
    }
  }

  Future<void> _sourceFile() => _run(() async {
    if (_path.text.trim().isEmpty) throw const FormatException('请输入源文件绝对路径');
    final path = _path.text.trim();
    final source = await widget.bridge.readSource(path);
    if (mounted && path == _path.text.trim()) {
      setState(() => _source = source.split('\n'));
    }
  });

  @override
  void didUpdateWidget(DebuggerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session?.generation != widget.session?.generation) {
      _revision++;
      _busy = false;
      _result = null;
      _error = null;
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _path,
      _arguments,
      _lines,
      _thread,
      _expression,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final source = _sourcePanel();
      final controls = _controls();
      return constraints.maxWidth >= 1000
          ? Row(
              children: [
                Expanded(flex: 3, child: source),
                const VerticalDivider(width: 1),
                Expanded(
                  flex: 2,
                  child: ColoredBox(
                    color: _colors.surfaceContainerLow,
                    child: controls,
                  ),
                ),
              ],
            )
          : Column(
              children: [
                Expanded(child: source),
                const Divider(height: 1),
                SizedBox(
                  height: constraints.maxHeight * .52,
                  child: ColoredBox(
                    color: _colors.surfaceContainerLow,
                    child: controls,
                  ),
                ),
              ],
            );
    },
  );

  Widget _sourcePanel() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _path,
                decoration: const InputDecoration(
                  labelText: '源文件路径',
                  hintText: '输入绝对路径以读取源码',
                ),
                onSubmitted: (_) => _sourceFile(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
              tooltip: '读取源码',
              onPressed: _busy ? null : _sourceFile,
              icon: const Icon(Icons.folder_open_outlined, size: 19),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '显示当前磁盘文件；暂停时请核对运行版本。',
            style: TextStyle(fontSize: 11, color: _colors.onSurfaceVariant),
          ),
        ),
      ),
      Expanded(
        child: _source.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.code,
                      size: 32,
                      color: _colors.onSurfaceVariant.withValues(alpha: .5),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '按需读取源码',
                      style: TextStyle(color: _colors.onSurfaceVariant),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 18,
                ),
                itemCount: _source.length,
                itemBuilder: (context, i) => Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        '${i + 1}',
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontFamilyFallback: const [
                            '.AppleSystemUIFont',
                            'PingFang SC',
                            'Segoe UI',
                            'Arial',
                          ],
                          fontSize: 12,
                          color: _colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: SelectableText(
                        _source[i],
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontFamilyFallback: const [
                            '.AppleSystemUIFont',
                            'PingFang SC',
                            'Segoe UI',
                            'Arial',
                          ],
                          fontSize: 12,
                          height: 1.6,
                          color: _colors.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    ],
  );

  Widget _controls() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text('调试操作', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Text(
        _canDebug ? '请求结果按需读取，适配器负责运行状态。' : '选择可调试的 Debug 会话后使用调试操作。',
        style: TextStyle(
          fontSize: 12,
          color: _colors.onSurfaceVariant,
          height: 1.6,
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _thread,
        decoration: const InputDecoration(
          labelText: 'Thread ID（从 threads 结果读取）',
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          _action('暂停', 'pause', paused: false),
          _action('继续', 'continue', paused: true),
          _action('单步跳过', 'next', paused: true),
          _action('进入', 'stepIn', paused: true),
          _action('跳出', 'stepOut', paused: true),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _lines,
        decoration: const InputDecoration(labelText: '断点行号（逗号分隔，空白清除）'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: _canDebug && !_busy
            ? () => _run(() async {
                if (_path.text.trim().isEmpty) {
                  throw const FormatException('请先输入源文件路径');
                }
                final lines = _lines.text
                    .split(',')
                    .where((s) => s.trim().isNotEmpty)
                    .map((s) {
                      final line = int.parse(s.trim());
                      if (line <= 0) throw const FormatException('断点行号必须大于 0');
                      return {'line': line};
                    })
                    .toList();
                await _request('setBreakpoints', {
                  'source': {'path': _path.text.trim()},
                  'breakpoints': lines,
                });
              })
            : null,
        child: const Text('设置断点 · 结果含 verified 状态'),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _expression,
        decoration: const InputDecoration(labelText: '表达式（Evaluate）'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed:
            _canDebug &&
                !_busy &&
                widget.session?.capabilities['supportsEvaluateForHovers'] ==
                    true
            ? () => _run(
                () => _request('evaluate', {
                  'expression': _expression.text,
                  'context': 'repl',
                }),
              )
            : null,
        child: const Text('求值'),
      ),
      const SizedBox(height: 20),
      const Divider(),
      Text('协议请求', style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 12),
      WorkbenchSelect<String>(
        key: const ValueKey('debugger-command-select'),
        label: '请求',
        value: _command,
        menuWidth: 320,
        options:
            const [
                  'threads',
                  'stackTrace',
                  'scopes',
                  'variables',
                  'evaluate',
                  'setExceptionBreakpoints',
                ]
                .map(
                  (c) => WorkbenchOption(
                    value: c,
                    label: c,
                    icon: Icons.code_outlined,
                  ),
                )
                .toList(),
        onChanged: (c) => setState(() => _command = c),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _arguments,
        minLines: 2,
        maxLines: 5,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: [
            '.AppleSystemUIFont',
            'PingFang SC',
            'Segoe UI',
            'Arial',
          ],
          fontSize: 12,
        ),
        decoration: const InputDecoration(
          labelText: '参数 JSON（threadId / frameId / variablesReference）',
        ),
      ),
      const SizedBox(height: 8),
      FilledButton.tonal(
        onPressed: _canDebug && !_busy
            ? () => _run(() async {
                final decoded = jsonDecode(_arguments.text);
                if (decoded is! Map<String, dynamic>) {
                  throw const FormatException('参数必须是 JSON 对象');
                }
                await _request(_command, decoded);
              })
            : null,
        child: Text(_busy ? '请求中…' : '发送请求'),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: SelectableText(
            _error!,
            style: TextStyle(color: _colors.error),
          ),
        ),
      if (_result != null)
        Container(
          margin: const EdgeInsets.only(top: 16),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _colors.surfaceContainer,
            border: Border.all(color: _colors.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SelectableText(
            _result!,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontFamilyFallback: [
                '.AppleSystemUIFont',
                'PingFang SC',
                'Segoe UI',
                'Arial',
              ],
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ),
    ],
  );

  Widget _action(String label, String command, {required bool paused}) {
    final allowed =
        _canDebug &&
        !_busy &&
        widget.session?.state == (paused ? 'paused' : 'running');
    return OutlinedButton(
      onPressed: allowed
          ? () => _run(() async {
              final thread = int.tryParse(_thread.text);
              if (thread == null) {
                throw const FormatException('请输入有效 Thread ID');
              }
              await _request(command, {'threadId': thread});
            })
          : null,
      child: Text(label),
    );
  }
}
