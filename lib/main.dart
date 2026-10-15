import 'package:flutter/material.dart';

import 'app.dart';
import 'core/bridge/workbench_bridge.dart';
import 'core/presentation/workbench_models.dart';
import 'core/presentation/workbench_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Bootstrap());
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late Future<WorkbenchBridge> _bridge = NativeWorkbenchBridge.initialize();

  @override
  Widget build(BuildContext context) => FutureBuilder<WorkbenchBridge>(
    future: _bridge,
    builder: (context, snapshot) {
      if (snapshot.hasData) return FlutterDevApp(bridge: snapshot.data!);
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
              child: snapshot.hasError
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Rust 核心加载失败'),
                        const SizedBox(height: 12),
                        SelectableText('${snapshot.error}'),
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: () => setState(() {
                            _bridge = NativeWorkbenchBridge.initialize();
                          }),
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
    },
  );
}
