import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/presentation/workbench_models.dart';

class EditorSettingsCard extends StatefulWidget {
  const EditorSettingsCard({super.key, required this.bridge, this.onSave});
  final WorkbenchBridge bridge;
  final Future<void> Function(String executable, List<String> arguments)?
  onSave;
  @override
  State<EditorSettingsCard> createState() => _EditorSettingsCardState();
}

class _EditorSettingsCardState extends State<EditorSettingsCard> {
  final _executable = TextEditingController();
  final _arguments = TextEditingController();
  bool _loading = true, _saving = false;
  String? _error, _message;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prefs = (await widget.bridge.getAppSettings()).workspacePreferences;
      if (!mounted) return;
      _executable.text = prefs.editorExecutable;
      _arguments.text = jsonEncode(prefs.editorArguments);
    } catch (error) {
      if (mounted) setState(() => _error = '读取编辑器设置失败：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = _message = null;
    });
    try {
      if (_executable.text.trim().isEmpty) {
        throw const FormatException('请输入编辑器可执行文件路径或命令');
      }
      final value = jsonDecode(_arguments.text);
      if (value is! List || value.any((v) => v is! String)) {
        throw const FormatException('编辑器参数应为 JSON 字符串数组');
      }
      final args = value.cast<String>();
      if (widget.onSave != null) {
        await widget.onSave!(_executable.text.trim(), args);
      } else {
        final prefs =
            (await widget.bridge.getAppSettings()).workspacePreferences;
        await widget.bridge.setWorkspacePreferences(
          WorkspacePreferences(
            runProfiles: prefs.runProfiles,
            projectStates: prefs.projectStates,
            editorExecutable: _executable.text.trim(),
            editorArguments: args,
          ),
        );
      }
      if (mounted) setState(() => _message = '编辑器设置已保存');
    } catch (error) {
      if (mounted) setState(() => _error = '保存编辑器设置失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _executable.dispose();
    _arguments.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '源码编辑器',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            border: Border.all(color: colors.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading)
                const LinearProgressIndicator()
              else ...[
                TextField(
                  key: const ValueKey('editor-executable'),
                  controller: _executable,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: '编辑器命令或可执行文件',
                    hintText: 'code',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const ValueKey('editor-arguments'),
                  controller: _arguments,
                  enabled: !_saving,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '参数（JSON 字符串数组）',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '支持 {file}、{line}、{column} 占位符。点击日志中的源码位置时使用这些参数打开文件。',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    key: const ValueKey('editor-save'),
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? '保存中…' : '保存编辑器'),
                  ),
                ),
              ],
              if (_error != null)
                Text(_error!, style: TextStyle(color: colors.error)),
              if (_error != null && _executable.text.isEmpty)
                TextButton(onPressed: _load, child: const Text('重新读取编辑器设置')),
              if (_message != null)
                Text(_message!, style: TextStyle(color: colors.primary)),
            ],
          ),
        ),
      ],
    );
  }
}
