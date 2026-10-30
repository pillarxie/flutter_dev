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
  bool _confirmingCleanup = false;
  bool _clearing = false;
  String? _error;
  String? _cleanupError;
  BuildCacheCleanupResult? _cleanupResult;

  Future<void> _clearCache() async {
    if (_confirmingCleanup || _clearing || _refreshing) return;
    setState(() => _confirmingCleanup = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除构建缓存？'),
        content: const SingleChildScrollView(
          child: Text(
            '将删除所有已导入项目的 build 目录，包括安装包及中间构建产物，'
            '并删除构建任务实际生成且已记录的自定义产物。\n\n'
            '此操作无法撤销。请先结束正在进行的构建、运行和测试任务。',
          ),
        ),
        actions: [
          TextButton(
            key: const Key('build-cache-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('build-cache-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除缓存'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _confirmingCleanup = false);
    if (confirmed != true) return;
    setState(() {
      _clearing = true;
      _cleanupError = null;
      _cleanupResult = null;
    });
    try {
      final result = await widget.bridge.clearBuildCache();
      if (!mounted) return;
      setState(() => _cleanupResult = result);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _cleanupError = '清除构建缓存失败：$error');
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

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
                    onPressed: _refreshing || _clearing ? null : _refresh,
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
              if (_refreshing || _clearing)
                const LinearProgressIndicator(minHeight: 2),
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
                          onTap: _clearing ? null : () => _open(task),
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              if (_cleanupError != null || _cleanupResult != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 140),
                    child: SingleChildScrollView(
                      key: const Key('build-cache-result'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_cleanupError != null)
                            Text(
                              _cleanupError!,
                              style: TextStyle(
                                color: colors.error,
                                fontSize: 12,
                              ),
                            ),
                          if (_cleanupResult case final result?) ...[
                            Text(
                              '已清除 ${result.deletedPaths.length} 个构建缓存路径。'
                              '${result.errors.isEmpty ? '' : ' ${result.errors.length} 项清理失败，可重试。'}',
                              style: TextStyle(
                                color: result.errors.isEmpty
                                    ? colors.onSurfaceVariant
                                    : colors.error,
                                fontSize: 12,
                              ),
                            ),
                            for (final error in result.errors)
                              SelectableText(
                                error,
                                style: TextStyle(
                                  color: colors.error,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              Row(
                children: [
                  TextButton.icon(
                    key: const Key('build-cache-clear'),
                    onPressed: _refreshing || _clearing || _confirmingCleanup
                        ? null
                        : _clearCache,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text(_clearing ? '正在清除构建缓存…' : '清除构建缓存'),
                  ),
                  const Spacer(),
                  TextButton(
                    key: const Key('build-tasks-close'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
