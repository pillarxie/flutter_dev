import 'package:flutter/material.dart';
import '../../core/presentation/workbench_models.dart';
import '../../core/presentation/workbench_select.dart';

class RunProfileControls extends StatelessWidget {
  const RunProfileControls({
    super.key,
    required this.profiles,
    required this.selectedId,
    required this.onSelected,
    required this.onSaveAs,
    required this.onAction,
    required this.autoReload,
    required this.onAutoReload,
    required this.enabled,
  });
  final List<RunProfile> profiles;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final VoidCallback onSaveAs;
  final ValueChanged<String> onAction;
  final bool autoReload, enabled;
  final ValueChanged<bool> onAutoReload;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: WorkbenchSelect<String>(
              key: const ValueKey('run-profile-select'),
              label: '运行配置',
              value: selectedId ?? '',
              compact: true,
              options: [
                const WorkbenchOption(
                  value: '',
                  label: '当前草稿',
                  icon: Icons.edit_note,
                ),
                for (final profile in profiles)
                  WorkbenchOption(
                    value: profile.id,
                    label: profile.name,
                    icon: Icons.tune,
                  ),
              ],
              onChanged: enabled ? onSelected : null,
            ),
          ),
          TextButton.icon(
            key: const ValueKey('run-profile-save-as'),
            onPressed: enabled ? onSaveAs : null,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('另存为'),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('run-profile-actions'),
            tooltip: '管理运行配置',
            enabled: enabled && selectedId != null,
            onSelected: onAction,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'update', child: Text('更新当前配置')),
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'delete', child: Text('删除配置')),
            ],
            icon: const Icon(Icons.more_horiz, size: 19),
          ),
        ],
      ),
      Row(
        children: [
          Switch(
            key: const ValueKey('auto-reload'),
            value: autoReload,
            onChanged: enabled ? onAutoReload : null,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Tooltip(
              message: '保存 Dart 文件后自动热重载 Debug 会话',
              child: Text('自动热重载', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    ],
  );
}

class RunProfileNameDialog extends StatefulWidget {
  const RunProfileNameDialog({
    super.key,
    required this.initialName,
    required this.title,
  });
  final String initialName, title;
  @override
  State<RunProfileNameDialog> createState() => _RunProfileNameDialogState();
}

class _RunProfileNameDialogState extends State<RunProfileNameDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('run-profile-name'),
      controller: _name,
      autofocus: true,
      maxLength: 80,
      decoration: const InputDecoration(labelText: '配置名称'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('run-profile-confirm'),
        onPressed: () {
          if (_name.text.trim().isNotEmpty) {
            Navigator.pop(context, _name.text.trim());
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}
