import 'package:flutter/material.dart';

import 'app.dart';
import 'core/bridge/workbench_bridge.dart';
import 'core/presentation/workbench_models.dart';
import 'core/presentation/workbench_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FlutterDevBootstrap());
}

class FlutterDevBootstrap extends StatefulWidget {
  const FlutterDevBootstrap({
    super.key,
    this.initialize = NativeWorkbenchBridge.initialize,
  });

  final Future<WorkbenchBridge> Function() initialize;

  @override
  State<FlutterDevBootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<FlutterDevBootstrap> {
  WorkbenchBridge? _bridge;
  Object? _error;
  bool _initializing = false;

  @override
  void initState() {
    super.initState();
    // Loading the native DLL is synchronous even inside RustLib.init(). Let the
    // loading shell paint first so Windows can show its first-frame window.
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    if (!mounted || _initializing) return;
    setState(() {
      _initializing = true;
      _error = null;
    });
    WorkbenchBridge? bridge;
    Object? error;
    try {
      bridge = await widget.initialize();
    } catch (failure) {
      error = failure;
    }
    if (!mounted) return;
    setState(() {
      _initializing = false;
      _bridge = bridge;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bridge = _bridge;
    if (bridge != null) return FlutterDevApp(bridge: bridge);
    return MaterialApp(
      title: 'Flutter Dev',
      debugShowCheckedModeBanner: false,
      theme: workbenchTheme(Brightness.light),
      darkTheme: workbenchTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: _error != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Rust 核心加载失败'),
                      const SizedBox(height: 12),
                      SelectableText('$_error'),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _initializing ? null : _initialize,
                        child: const Text('重试'),
                      ),
                    ],
                  )
                : const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('正在加载运行核心…'),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
