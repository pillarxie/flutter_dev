import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/presentation/workbench_models.dart';
import '../../core/presentation/workbench_select.dart';

/// Build configuration and progress belong to this window, independently of a
/// running device session. Keep the window open while the build is active.
class BuildDialog extends StatefulWidget {
  const BuildDialog({
    super.key,
    required this.bridge,
    required this.project,
    this.sdkPreference,
  });

  final WorkbenchBridge bridge;
  final Project project;
  final String? sdkPreference;

  @override
  State<BuildDialog> createState() => _BuildDialogState();
}

class _BuildDialogState extends State<BuildDialog> {
  static const _targets = [
    'apk',
    'appbundle',
    'ios',
    'ipa',
    'web',
    'macos',
    'windows',
    'linux',
    'aar',
    'bundle',
  ];
  static String _targetLabel(String target) => switch (target) {
    'apk' => 'Android APK (apk)',
    'appbundle' => 'Android App Bundle (appbundle)',
    'ios' => 'iOS 应用 (ios)',
    'ipa' => 'iOS IPA (ipa)',
    'web' => 'Web (web)',
    'macos' => 'macOS (macos)',
    'windows' => 'Windows (windows)',
    'linux' => 'Linux (linux)',
    'aar' => 'Android AAR (aar)',
    _ => 'Flutter 资源包 (bundle)',
  };
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  final _args = TextEditingController(text: '[]');
  final _output = TextEditingController();
  final _logScroll = ScrollController();
  final _logs = <LogEntry>[];
  List<BuildPreset> _presets = [];
  String? _selectedId;
  String _target = 'apk';
  BuildSnapshot? _snapshot;
  Timer? _timer;
  int _cursor = 0;
  bool _loading = true, _saving = false, _starting = false;
  bool _polling = false, _stopping = false, _opening = false;
  bool _logsDropped = false, _draining = false;
  String? _error, _pollError, _argsError, _nameError;

  bool get _active => _starting || (_snapshot?.active ?? false);
  bool get _locked => _loading || _saving || _opening || _active;
  bool get _succeeded => _snapshot?.state == 'succeeded';

  @override
  void initState() {
    super.initState();
    _args.addListener(_updatePreview);
    _loadPresets();
  }

  void _updatePreview() {
    if (mounted) setState(() => _argsError = null);
  }

  Future<void> _loadPresets() async {
    try {
      final settings = await widget.bridge.getAppSettings();
      if (!mounted) return;
      setState(() {
        _presets = List.of(settings.buildPresets);
        if (_presets.isNotEmpty) {
          String platformFor(String target) => switch (target) {
            'apk' || 'appbundle' || 'aar' => 'android',
            'ipa' => 'ios',
            _ => target,
          };
          _applyPreset(
            _presets
                    .where(
                      (preset) => widget.project.platforms.contains(
                        platformFor(preset.target),
                      ),
                    )
                    .firstOrNull ??
                _presets.first,
          );
        }
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '读取构建预设失败：$error';
        });
      }
    }
  }

  void _applyPreset(BuildPreset preset) {
    _selectedId = preset.id;
    _name.text = preset.name;
    _target = preset.target;
    _args.text = jsonEncode(preset.args);
    _output.text = preset.outputDirectory ?? '';
    _argsError = null;
    _nameError = null;
    _error = null;
  }

  List<String>? _validatedArgs() {
    try {
      final value = jsonDecode(_args.text.trim().isEmpty ? '[]' : _args.text);
      if (value is! List || value.any((argument) => argument is! String)) {
        throw const FormatException();
      }
      return value.cast<String>();
    } catch (_) {
      setState(() => _argsError = '参数应为 JSON 字符串数组，例如 ["--release"]');
      return null;
    }
  }

  String? get _outputDirectory =>
      _output.text.trim().isEmpty ? null : _output.text.trim();

  Future<void> _savePreset() async {
    final args = _validatedArgs();
    final name = _name.text.trim();
    if (name.isEmpty) setState(() => _nameError = '请输入预设名称');
    if (args == null || name.isEmpty) return;
    final id = _selectedId ?? 'custom-${DateTime.now().microsecondsSinceEpoch}';
    final preset = BuildPreset(
      id: id,
      name: name,
      target: _target,
      args: args,
      outputDirectory: _outputDirectory,
    );
    final updated = List<BuildPreset>.of(_presets);
    final index = updated.indexWhere((item) => item.id == id);
    if (index < 0) {
      updated.add(preset);
    } else {
      updated[index] = preset;
    }
    await _persistPresets(updated, selectedId: id);
  }

  Future<void> _persistPresets(
    List<BuildPreset> presets, {
    String? selectedId,
  }) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final settings = await widget.bridge.setBuildPresets(presets);
      if (!mounted) return;
      setState(() {
        _presets = List.of(settings.buildPresets);
        _selectedId = selectedId;
        _nameError = null;
        if (selectedId == null) _name.clear();
      });
    } catch (error) {
      if (mounted) setState(() => _error = '保存构建预设失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _start() async {
    if (_locked || _polling || _draining) return;
    final args = _validatedArgs();
    if (args == null) return;
    _timer?.cancel();
    setState(() {
      _starting = true;
      _snapshot = null;
      _error = null;
      _logs.clear();
      _cursor = 0;
      _logsDropped = false;
      _pollError = null;
    });
    try {
      final snapshot = await widget.bridge.startBuild(
        BuildConfig(
          projectPath: widget.project.path,
          sdkPath: widget.sdkPreference,
          target: _target,
          args: args,
          outputDirectory: _outputDirectory,
        ),
      );
      if (!mounted) return;
      setState(() => _snapshot = snapshot);
      await _poll();
    } catch (error) {
      if (mounted) setState(() => _error = '启动构建失败：$error');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _poll() async {
    final id = _snapshot?.id;
    if (!mounted || id == null || _polling) return;
    _polling = true;
    var moreLogs = false;
    var retryLogs = false;
    String? pollError;
    try {
      try {
        final snapshot = await widget.bridge.buildSnapshot(id);
        if (!mounted) return;
        setState(() => _snapshot = snapshot);
      } catch (error) {
        pollError = '读取构建状态失败：$error';
      }
      try {
        final page = await widget.bridge.readBuildLogs(id, afterId: _cursor);
        if (!mounted) return;
        setState(() {
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
          moreLogs = page.entries.length == 200;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _logScroll.hasClients) {
            _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
          }
        });
      } catch (error) {
        retryLogs = true;
        pollError = '读取构建日志失败：$error';
      }
    } finally {
      _polling = false;
      if (mounted) {
        setState(() {
          _draining = moreLogs || retryLogs;
          _pollError = pollError;
        });
        if ((_snapshot?.active ?? false) || _draining) {
          _timer = Timer(Duration(milliseconds: moreLogs ? 50 : 500), _poll);
        }
      }
    }
  }

  Future<void> _stop() async {
    setState(() => _stopping = true);
    try {
      await widget.bridge.stopBuild(_snapshot!.id);
      await _poll();
    } catch (error) {
      if (mounted) setState(() => _error = '停止构建失败：$error');
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  Future<void> _openOutput() async {
    setState(() => _opening = true);
    try {
      final id = _snapshot!.id;
      await widget.bridge.openBuildOutput(id);
      if (!mounted) return;
      setState(() => _error = null);
      try {
        final snapshot = await widget.bridge.buildSnapshot(id);
        if (!mounted) return;
        setState(() {
          _snapshot = snapshot;
          _pollError = null;
        });
      } catch (error) {
        if (mounted) setState(() => _pollError = '刷新构建状态失败：$error');
      }
    } catch (error) {
      if (mounted) setState(() => _error = '打开产物目录失败：$error');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  String get _command {
    try {
      final args = jsonDecode(_args.text.trim().isEmpty ? '[]' : _args.text);
      if (args is! List || args.any((item) => item is! String)) {
        return 'flutter build $_target';
      }
      String quote(String value) =>
          RegExp(r'^[a-zA-Z0-9_./:=+-]+$').hasMatch(value)
          ? value
          : jsonEncode(value);
      return [
        'flutter',
        'build',
        _target,
        ...args.cast<String>(),
      ].map(quote).join(' ');
    } catch (_) {
      return 'flutter build $_target';
    }
  }

  String get _status => switch (_snapshot?.state) {
    'starting' => '正在准备构建',
    'running' => '正在构建',
    'stopping' => '正在停止构建',
    'succeeded' => '构建成功',
    'failed' => '构建失败',
    'cancelled' => '构建已停止',
    _ => _starting ? '正在准备构建' : '等待构建',
  };

  @override
  void dispose() {
    _timer?.cancel();
    _name.dispose();
    _nameFocus.dispose();
    _args.removeListener(_updatePreview);
    _args.dispose();
    _output.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  Widget _section({
    required String title,
    Widget? trailing,
    required Widget child,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }

  Widget _presetSelect() => WorkbenchSelect<String>(
    key: const Key('build-preset'),
    label: '构建预设',
    value: _selectedId ?? '',
    options: [
      const WorkbenchOption(value: '', label: '自定义构建'),
      for (final preset in _presets)
        WorkbenchOption(
          value: preset.id,
          label: preset.name,
          detail: 'flutter build ${preset.target}',
        ),
    ],
    onChanged: _locked
        ? null
        : (id) => setState(() {
            if (id.isEmpty) {
              _selectedId = null;
              _name.clear();
            } else {
              _applyPreset(_presets.firstWhere((p) => p.id == id));
            }
          }),
  );

  Widget _presetActions() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      OutlinedButton.icon(
        key: const Key('build-new-preset'),
        onPressed: _locked
            ? null
            : () => setState(() {
                _selectedId = null;
                _name.clear();
                _nameError = null;
              }),
        icon: const Icon(Icons.add, size: 16),
        label: const Text('新增预设'),
      ),
      OutlinedButton.icon(
        key: const Key('build-save-preset'),
        onPressed: _locked ? null : _savePreset,
        icon: const Icon(Icons.save_outlined, size: 16),
        label: Text(_selectedId == null ? '保存为预设' : '保存预设'),
      ),
      if (_selectedId != null)
        OutlinedButton.icon(
          key: const Key('build-delete-preset'),
          onPressed: _locked
              ? null
              : () => _persistPresets(
                  _presets.where((p) => p.id != _selectedId).toList(),
                ),
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('删除预设'),
        ),
    ],
  );

  Widget _configuration() => _section(
    title: '构建配置',
    child: LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 600;
        final name = TextField(
          key: const Key('build-preset-name'),
          controller: _name,
          focusNode: _nameFocus,
          enabled: !_locked,
          onChanged: (_) => setState(() => _nameError = null),
          decoration: InputDecoration(
            labelText: '预设名称',
            hintText: '例如 Android 生产环境',
            errorText: _nameError,
          ),
        );
        final target = WorkbenchSelect<String>(
          key: const Key('build-target'),
          label: '构建平台 / 产物类型',
          value: _target,
          options: [
            for (final target in _targets)
              WorkbenchOption(value: target, label: _targetLabel(target)),
          ],
          onChanged: _locked
              ? null
              : (value) => setState(() => _target = value),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loading) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 16),
            ],
            if (wide && _selectedId == null)
              Row(
                children: [
                  Expanded(child: _presetSelect()),
                  const SizedBox(width: 12),
                  _presetActions(),
                ],
              )
            else ...[
              _presetSelect(),
              const SizedBox(height: 12),
              _presetActions(),
            ],
            const SizedBox(height: 20),
            Wrap(
              key: const ValueKey('build-name-target-fields'),
              spacing: 14,
              runSpacing: 18,
              children: [
                SizedBox(
                  width: wide
                      ? (constraints.maxWidth - 14) / 2
                      : constraints.maxWidth,
                  child: name,
                ),
                SizedBox(
                  width: wide
                      ? (constraints.maxWidth - 14) / 2
                      : constraints.maxWidth,
                  child: target,
                ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('build-args'),
              controller: _args,
              enabled: !_locked,
              minLines: 2,
              maxLines: 5,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: InputDecoration(
                labelText: '构建参数（JSON 数组）',
                hintText: '["--release", "--flavor", "production"]',
                errorText: _argsError,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('build-output-directory'),
              controller: _output,
              enabled: !_locked,
              decoration: const InputDecoration(
                labelText: '产物目录（可选）',
                hintText: '例如 build/app/outputs/flutter-apk',
                suffixIcon: Icon(Icons.folder_open_outlined, size: 18),
                helperText: '相对于项目路径，只指定成功后打开的位置；实际输出路径请在构建参数中配置。留空使用默认目录。',
                helperMaxLines: 4,
              ),
            ),
          ],
        );
      },
    ),
  );

  Widget _commandPreview() {
    final colors = Theme.of(context).colorScheme;
    return _section(
      title: '命令预览',
      trailing: Text(
        'Flutter SDK：${widget.sdkPreference ?? '自动选择'}',
        style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Text(
              r'$',
              style: TextStyle(
                fontFamily: 'monospace',
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SelectableText(
                _command,
                key: const Key('build-command'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOutput() {
    final colors = Theme.of(context).colorScheme;
    final statusColor = _snapshot?.state == 'failed'
        ? colors.error
        : _succeeded
        ? (Theme.of(context).brightness == Brightness.dark
              ? const Color(0xff65c58a)
              : const Color(0xff27834b))
        : _active
        ? colors.primary
        : colors.onSurfaceVariant;
    return _section(
      title: '构建输出',
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: statusColor.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _succeeded ? Icons.check_circle_rounded : Icons.circle,
              size: 9,
              color: statusColor,
            ),
            const SizedBox(width: 7),
            Text(
              _status,
              key: const Key('build-status'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: statusColor,
              ),
            ),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_active) ...[
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 12),
          ],
          for (final error in [_snapshot?.error, _pollError, _error])
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SelectableText(
                  error,
                  style: TextStyle(fontSize: 12, color: colors.error),
                ),
              ),
          if (_snapshot?.outputDirectory != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SelectableText(
                '产物位置：${_snapshot!.outputDirectory}',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          if (_logsDropped)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '仅显示最近的构建日志',
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
            ),
          Container(
            height: 176,
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: _logs.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      '构建日志将在这里显示',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  )
                : ListView.builder(
                    key: const Key('build-logs'),
                    controller: _logScroll,
                    padding: const EdgeInsets.all(14),
                    itemCount: _logs.length,
                    itemBuilder: (context, index) => SelectableText(
                      _logs[index].text,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.6,
                        color: _logs[index].category == 'stderr'
                            ? colors.error
                            : colors.onSurface,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final viewport = MediaQuery.sizeOf(context);
    final compact = viewport.width < 600;
    final padding = compact ? 16.0 : 24.0;
    return PopScope(
      canPop: !_active,
      child: Dialog(
        key: const ValueKey('build-dialog'),
        insetPadding: EdgeInsets.all(compact ? 12 : 24),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: SizedBox(
          width: math.min(900, viewport.width - (compact ? 24 : 48)),
          height: math.min(980, viewport.height - (compact ? 24 : 48)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.all(padding),
                child: Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.inventory_2_outlined,
                        size: 26,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '构建应用',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${widget.project.name} · 配置并生成发布产物',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(padding, 0, padding, padding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _configuration(),
                      const SizedBox(height: 14),
                      _commandPreview(),
                      const SizedBox(height: 14),
                      _buildOutput(),
                    ],
                  ),
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: padding,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.outlineVariant)),
                ),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_succeeded)
                      OutlinedButton.icon(
                        key: const Key('build-open-output'),
                        onPressed: _opening ? null : _openOutput,
                        icon: const Icon(Icons.folder_open, size: 17),
                        label: const Text('打开产物目录'),
                      ),
                    TextButton(
                      key: const Key('build-close'),
                      onPressed: _active || _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('关闭'),
                    ),
                    if (_active)
                      FilledButton.icon(
                        key: const Key('build-stop'),
                        onPressed:
                            _snapshot == null ||
                                _stopping ||
                                _snapshot?.state == 'stopping'
                            ? null
                            : _stop,
                        icon: const Icon(Icons.stop, size: 17),
                        label: Text(
                          _stopping || _snapshot?.state == 'stopping'
                              ? '正在停止'
                              : '停止构建',
                        ),
                      )
                    else
                      FilledButton.icon(
                        key: const Key('build-start'),
                        onPressed: _locked || _polling || _draining
                            ? null
                            : _start,
                        icon: const Icon(Icons.play_arrow_rounded, size: 17),
                        label: const Text('开始构建'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
