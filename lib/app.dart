import 'package:flutter/material.dart';

import 'core/presentation/workbench_models.dart';
import 'core/presentation/workbench_theme.dart';
import 'features/workbench/workbench.dart';

class FlutterDevApp extends StatefulWidget {
  const FlutterDevApp({super.key, required this.bridge});
  final WorkbenchBridge bridge;

  @override
  State<FlutterDevApp> createState() => _FlutterDevAppState();
}

class _FlutterDevAppState extends State<FlutterDevApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  ThemeMode _themeMode = ThemeMode.light;
  ThemeMode _savedMode = ThemeMode.light;
  Future<void> _pendingSave = Future.value();
  late final Future<void> _initialAppearance;
  bool _hasSavedAppearance = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _initialAppearance = _loadAppearance();
  }

  Future<void> _loadAppearance() async {
    final revision = _revision;
    try {
      final settings = await widget.bridge.getAppSettings();
      if (!mounted) return;
      final mode = settings.themeMode == 'dark'
          ? ThemeMode.dark
          : ThemeMode.light;
      if (!_hasSavedAppearance) _savedMode = mode;
      if (revision != _revision) return;
      setState(() {
        _themeMode = mode;
      });
    } catch (_) {
      // SDK settings can still be repaired from the settings page.
    }
  }

  void _changeAppearance(ThemeMode mode) {
    if (mode == _themeMode) return;
    final revision = ++_revision;
    setState(() => _themeMode = mode);
    // Keep rapid toggles in submission order; native writes are atomic.
    _pendingSave = _pendingSave.then((_) async {
      try {
        await widget.bridge.setThemeMode(
          mode == ThemeMode.dark ? 'dark' : 'light',
        );
        _savedMode = mode;
        _hasSavedAppearance = true;
      } catch (error) {
        await _initialAppearance;
        if (!mounted || revision != _revision) return;
        setState(() => _themeMode = _savedMode);
        _messenger.currentState?.showSnackBar(
          SnackBar(content: Text('主题设置保存失败：$error')),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Flutter Dev',
    debugShowCheckedModeBanner: false,
    scaffoldMessengerKey: _messenger,
    theme: workbenchTheme(Brightness.light),
    darkTheme: workbenchTheme(Brightness.dark),
    themeMode: _themeMode,
    home: Workbench(
      bridge: widget.bridge,
      themeMode: _themeMode,
      onThemeChanged: _changeAppearance,
    ),
  );
}
