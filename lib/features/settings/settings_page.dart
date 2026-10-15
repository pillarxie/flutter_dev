import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/presentation/workbench_models.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.bridge,
    required this.onSaved,
    required this.themeMode,
    required this.onThemeChanged,
  });

  final WorkbenchBridge bridge;
  final ValueChanged<AppSettings> onSaved;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _sdkPath = TextEditingController();
  AppSettings? _settings;
  bool _loading = true;
  bool _saving = false;
  bool _choosing = false;
  String? _error;
  String? _message;
  int _request = 0;
  bool get _busy => _loading || _saving || _choosing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await widget.bridge.getAppSettings();
      if (!mounted || request != _request) return;
      setState(() {
        _settings = settings;
        _sdkPath.text = settings.defaultSdkPath ?? '';
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _error = '读取应用设置失败：$e');
    } finally {
      if (mounted && request == _request) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _chooseDirectory() async {
    final request = ++_request;
    setState(() {
      _choosing = true;
      _error = null;
      _message = null;
    });
    try {
      final path = await getDirectoryPath(confirmButtonText: '选择 SDK');
      if (!mounted || request != _request || path == null) return;
      setState(() => _sdkPath.text = path);
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _error = '选择 SDK 目录失败：$e');
    } finally {
      if (mounted && request == _request) {
        setState(() => _choosing = false);
      }
    }
  }

  Future<void> _save({bool clear = false}) async {
    final path = _sdkPath.text.trim();
    if (!clear && path.isEmpty) {
      setState(() {
        _error = '请选择或输入 Flutter SDK 根目录。';
        _message = null;
      });
      return;
    }
    final request = ++_request;
    setState(() {
      _saving = true;
      _error = null;
      _message = null;
    });
    try {
      final settings = await widget.bridge.setDefaultSdk(clear ? null : path);
      // Saving may finish after the user returns to a project. Notify the
      // workbench so its cached SDK is invalidated even when this page closed.
      widget.onSaved(settings);
      if (!mounted || request != _request) return;
      setState(() {
        _settings = settings;
        _sdkPath.text = settings.defaultSdkPath ?? '';
        _message = clear ? '已清除全局默认 SDK。' : 'SDK 已验证，全局默认设置已保存。';
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _error = '保存失败，原有设置保持不变：$e');
    } finally {
      if (mounted && request == _request) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  void dispose() {
    _request++;
    _sdkPath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selectedMode = widget.themeMode == ThemeMode.system
        ? theme.brightness == Brightness.dark
              ? ThemeMode.dark
              : ThemeMode.light
        : widget.themeMode;
    final cardDecoration = BoxDecoration(
      color: colors.surface,
      border: Border.all(color: colors.outlineVariant),
      borderRadius: BorderRadius.circular(12),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final padding = compact ? 20.0 : 32.0;
        return SingleChildScrollView(
          key: const ValueKey('sdk-settings-page'),
          padding: EdgeInsets.fromLTRB(padding, 8, padding, 24),
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SettingsSectionHeading(
                    icon: Icons.light_mode_outlined,
                    title: '外观',
                    subtitle: '选择适合你的工作方式',
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(compact ? 12 : 20),
                    decoration: cardDecoration,
                    child: Row(
                      children: [
                        Expanded(
                          child: _ThemeOption(
                            key: const ValueKey('settings-theme-light'),
                            dark: false,
                            selected: selectedMode == ThemeMode.light,
                            onTap: () => widget.onThemeChanged(ThemeMode.light),
                          ),
                        ),
                        SizedBox(width: compact ? 10 : 18),
                        Expanded(
                          child: _ThemeOption(
                            key: const ValueKey('settings-theme-dark'),
                            dark: true,
                            selected: selectedMode == ThemeMode.dark,
                            onTap: () => widget.onThemeChanged(ThemeMode.dark),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  const _SettingsSectionHeading(
                    icon: Icons.code_rounded,
                    title: 'Flutter SDK',
                    subtitle: '设置全局默认开发环境',
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(compact ? 16 : 22),
                    decoration: cardDecoration,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('全局默认 SDK', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 6),
                        Text(
                          '项目优先使用独立配置或自动发现的 SDK；项目 SDK 异常时，自动使用这里的全局默认 SDK。',
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 13,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (_loading) const LinearProgressIndicator(),
                        if (!_loading) ...[
                          Text('SDK 路径', style: theme.textTheme.labelLarge),
                          const SizedBox(height: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: TextField(
                                  key: const ValueKey('default-sdk-path'),
                                  controller: _sdkPath,
                                  enabled: !_busy,
                                  style: const TextStyle(fontSize: 13),
                                  onChanged: (_) => setState(() {
                                    _error = null;
                                    _message = null;
                                  }),
                                  decoration: const InputDecoration(
                                    hintText: 'Flutter SDK 根目录',
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 13,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              SizedBox(
                                width: 44,
                                height: 44,
                                child: IconButton.outlined(
                                  key: const ValueKey('default-sdk-browse'),
                                  onPressed: _busy ? null : _chooseDirectory,
                                  tooltip: '选择目录',
                                  style: IconButton.styleFrom(
                                    side: BorderSide(
                                      color: colors.outlineVariant,
                                    ),
                                    backgroundColor: colors.surfaceContainer,
                                  ),
                                  icon: const Icon(
                                    Icons.folder_open_outlined,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '选择包含 bin/flutter 的 SDK 根目录',
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 12,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 18),
                          LayoutBuilder(
                            builder: (context, buttonConstraints) {
                              final clearButton = TextButton(
                                key: const ValueKey('default-sdk-clear'),
                                style: TextButton.styleFrom(
                                  foregroundColor: colors.onSurface,
                                  backgroundColor: colors.surfaceContainer,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    side: BorderSide(
                                      color: colors.outlineVariant,
                                    ),
                                  ),
                                ),
                                onPressed:
                                    !_busy &&
                                        (_settings?.defaultSdkPath != null ||
                                            _sdkPath.text.isNotEmpty ||
                                            _settings == null)
                                    ? () => _save(clear: true)
                                    : null,
                                child: const Text('清除默认 SDK'),
                              );
                              final saveButton = FilledButton(
                                key: const ValueKey('default-sdk-save'),
                                onPressed: _busy ? null : _save,
                                child: Text(_saving ? '验证并保存中…' : '验证并保存'),
                              );
                              if (buttonConstraints.maxWidth < 290) {
                                return Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: [clearButton, saveButton],
                                );
                              }
                              return Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [clearButton, saveButton],
                              );
                            },
                          ),
                          const SizedBox(height: 18),
                          Divider(color: colors.outlineVariant, height: 1),
                          const SizedBox(height: 17),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                _settings?.defaultSdkPath != null
                                    ? Icons.folder_outlined
                                    : Icons.info_outline_rounded,
                                size: 20,
                                color: colors.onSurfaceVariant,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '当前已保存的默认 SDK',
                                      style: theme.textTheme.labelLarge,
                                    ),
                                    const SizedBox(height: 4),
                                    SelectableText(
                                      _settings == null
                                          ? '读取失败，原有设置尚未确认'
                                          : _settings!.defaultSdkPath ?? '尚未设置',
                                      style: TextStyle(
                                        fontSize: 12,
                                        height: 1.6,
                                        fontFamily: 'monospace',
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _error!,
                            style: TextStyle(color: colors.error, height: 1.6),
                          ),
                          if (!_loading && _settings == null)
                            TextButton(
                              onPressed: _load,
                              child: const Text('重新读取'),
                            ),
                        ],
                        if (_message != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _message!,
                            style: TextStyle(
                              color: colors.primary,
                              height: 1.6,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 17,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '修改后在下一次检查或启动项目时生效，已运行的会话继续使用原 SDK。',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Flutter Dev',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SettingsSectionHeading extends StatelessWidget {
  const _SettingsSectionHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 29),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    super.key,
    required this.dark,
    required this.selected,
    required this.onTap,
  });

  final bool dark;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: dark ? '深色主题' : '浅色主题',
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: .025)
            : colors.surface,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? colors.primary : colors.outlineVariant,
                width: selected ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: selected ? colors.primary : colors.outline,
                    size: 20,
                  ),
                ),
                const SizedBox(height: 2),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 224),
                  child: AspectRatio(
                    aspectRatio: 1.75,
                    child: CustomPaint(
                      painter: _ThemePreviewPainter(dark: dark),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  dark ? '深色' : '浅色',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemePreviewPainter extends CustomPainter {
  const _ThemePreviewPainter({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final frame = RRect.fromRectAndRadius(
      rect.deflate(.5),
      const Radius.circular(8),
    );
    final background = dark ? const Color(0xff232325) : const Color(0xfffefefe);
    final sidebar = dark ? const Color(0xff303033) : const Color(0xffe9ebef);
    final bar = dark ? const Color(0xff4c4c50) : const Color(0xffd8dbe2);
    final muted = dark ? const Color(0xff343437) : const Color(0xfff0f1f4);
    canvas.save();
    canvas.clipRRect(frame);
    canvas.drawRect(rect, Paint()..color = background);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * .28, size.height),
      Paint()..color = sidebar,
    );
    void block(double x, double y, double w, double h, Color color) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            size.width * x,
            size.height * y,
            size.width * w,
            size.height * h,
          ),
          const Radius.circular(3),
        ),
        Paint()..color = color,
      );
    }

    block(.035, .07, .2, .065, bar);
    block(.035, .205, .2, .075, const Color(0xff007aff));
    block(.035, .365, .11, .055, bar);
    block(.035, .485, .11, .055, bar);
    block(.035, .605, .11, .055, bar);
    canvas.drawLine(
      Offset(size.width * .28, size.height * .18),
      Offset(size.width, size.height * .18),
      Paint()
        ..color = muted
        ..strokeWidth = 1,
    );
    block(.35, .285, .42, .065, bar);
    block(.35, .425, .27, .06, muted);
    block(.35, .61, .58, .235, muted);
    block(.38, .67, .17, .1, bar.withValues(alpha: .6));
    canvas.restore();
    canvas.drawRRect(
      frame,
      Paint()
        ..color = (dark ? const Color(0xff45454a) : const Color(0xffdcdfe5))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_ThemePreviewPainter oldDelegate) =>
      oldDelegate.dark != dark;
}
