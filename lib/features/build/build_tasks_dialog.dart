import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/presentation/workbench_models.dart';
import 'build_dialog.dart';

/// A projection of the workbench's core-owned build list. Log pages are only
/// loaded by a task's detail window, so the task list stays bounded and cheap.
class BuildTasksDialog extends StatefulWidget {
  const BuildTasksDialog({
    super.key,
    required this.bridge,
    required this.builds,
    required this.onRefresh,
  });

  final WorkbenchBridge bridge;
  final ValueListenable<List<BuildSnapshot>> builds;
  final Future<void> Function() onRefresh;

  @override
  State<BuildTasksDialog> createState() => _BuildTasksDialogState();
}

class _BuildTasksDialogState extends State<BuildTasksDialog> {
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted || _refreshing) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      await widget.onRefresh();
    } catch (error) {
      if (mounted) setState(() => _error = '刷新构建任务失败：$error');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String _projectName(String path) =>
      path
          .split(RegExp(r'[/\\]'))
          .where((part) => part.isNotEmpty)
          .lastOrNull ??
      path;

  String _status(String state) => switch (state) {
    'starting' => '正在准备',
    'running' => '正在构建',
    'stopping' => '正在停止',
    'succeeded' => '构建成功',
    'failed' => '构建失败',
    'cancelled' => '已停止',
    _ => state,
  };

  Future<void> _open(BuildSnapshot task) async {
    await showDialog<void>(
      context: context,
      builder: (_) => BuildDialog(
        bridge: widget.bridge,
        project: Project(
          name: _projectName(task.projectPath),
          path: task.projectPath,
        ),
        initialBuild: task,
      ),
    );
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    return Dialog(
      key: const Key('build-tasks-dialog'),
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
        width: math.min(760, viewport.width - 40),
        height: math.min(680, viewport.height - 40),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.inventory_2_outlined, size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '构建任务',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('build-tasks-refresh'),
                    tooltip: '刷新构建任务',
                    onPressed: _refreshing ? null : _refresh,
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '关闭窗口后构建继续运行，点击任务查看日志和产物。',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              if (_refreshing) const LinearProgressIndicator(minHeight: 2),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    style: TextStyle(color: colors.error, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: ValueListenableBuilder<List<BuildSnapshot>>(
                  valueListenable: widget.builds,
                  builder: (context, builds, _) {
                    if (builds.isEmpty) {
                      return Center(
                        child: Text(
                          _refreshing ? '正在读取构建任务' : '暂无构建任务',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      );
                    }
                    return ListView.separated(
                      key: const Key('build-tasks-list'),
                      itemCount: builds.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final task = builds[index];
                        return ListTile(
                          key: ValueKey('build-task-${task.id}'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          leading: Icon(
                            task.active
                                ? Icons.hourglass_top_rounded
                                : task.state == 'succeeded'
                                ? Icons.check_circle_outline
                                : Icons.inventory_2_outlined,
                            color: task.state == 'failed'
                                ? colors.error
                                : colors.primary,
                            size: 22,
                          ),
                          title: Text(
                            _projectName(task.projectPath),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${task.target} · ${_status(task.state)}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              Text(
                                '构建版本：${task.version?.label ?? '未读取'}',
                                key: ValueKey('build-task-version-${task.id}'),
                                style: const TextStyle(fontSize: 12),
                              ),
                              Text(
                                task.projectPath,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 20),
                          onTap: () => _open(task),
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('build-tasks-close'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
