import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_dev/core/bridge/workbench_bridge.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';

// Opt-in test: runs a test-owned target project and real desktop WebViews.
// Pass absolute SDK and disposable sample paths using the two dart defines.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const sdk = String.fromEnvironment('FLUTTER_DEV_SMOKE_SDK');
  const project = String.fromEnvironment('FLUTTER_DEV_SMOKE_PROJECT');
  const artifactDir = String.fromEnvironment('FLUTTER_DEV_SMOKE_ARTIFACT_DIR');
  testWidgets(
    'official DevTools modules load and connect in a desktop WebView',
    (tester) async {
      final bridge = await NativeWorkbenchBridge.initialize();
      Session? session;
      try {
        session = await bridge.startSession(
          const RunConfig(
            sdkPath: sdk,
            projectPath: project,
            deviceId: 'macos',
            sdkPreference: sdk,
          ),
        );
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        while (DateTime.now().isBefore(deadline)) {
          final current = (await bridge.listSessions()).firstWhere(
            (s) => s.id == session!.id,
          );
          if (current.state == 'failed' || current.state == 'ended') {
            fail('Sample did not start: ${current.error}');
          }
          if (current.state == 'running' && current.serviceUri != null) {
            session = current;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        final target = session!;
        expect(target.serviceUri, isNotNull);
        for (final module in [
          'inspector',
          'performance',
          'cpu',
          'memory',
          'logging',
        ]) {
          final url = await bridge.openDevTools(target.id, module);
          expect(Uri.parse(url).host, '127.0.0.1');
          InAppWebViewController? controller;
          String? loadError;
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              home: Scaffold(
                body: InAppWebView(
                  key: ValueKey(module),
                  initialUrlRequest: URLRequest(url: WebUri(url)),
                  initialUserScripts: UnmodifiableListView([
                    UserScript(
                      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                      source: r'''
                window.__devtoolsSocketCount = 0;
                window.__devtoolsHasVM = false;
                window.__devtoolsResponseMethods = [];
                const NativeSocket = window.WebSocket;
                window.WebSocket = class extends NativeSocket {
                  constructor(...args) {
                    super(...args);
                    this.__pending = new Map();
                    this.addEventListener('open', () => window.__devtoolsSocketCount++);
                    this.addEventListener('message', event => {
                      try {
                        const packet = JSON.parse(event.data);
                        if (packet.result && packet.result.type === 'VM') window.__devtoolsHasVM = true;
                        if (packet.result && this.__pending.has(packet.id)) {
                          window.__devtoolsResponseMethods.push(this.__pending.get(packet.id));
                          this.__pending.delete(packet.id);
                        }
                      } catch (_) {}
                    });
                  }
                  send(data) {
                    try {
                      const packet = JSON.parse(data);
                      if (packet.id && packet.method) this.__pending.set(packet.id, packet.method);
                    } catch (_) {}
                    return super.send(data);
                  }
                };
              ''',
                    ),
                  ]),
                  onWebViewCreated: (value) => controller = value,
                  onReceivedError: (_, request, error) {
                    if (request.isForMainFrame == true) {
                      loadError = error.description;
                    }
                  },
                ),
              ),
            ),
          );
          final loadedBy = DateTime.now().add(const Duration(seconds: 60));
          var ready = false;
          while (DateTime.now().isBefore(loadedBy)) {
            await tester.pump(const Duration(milliseconds: 250));
            if (loadError != null) {
              fail('WebView main frame failed: $loadError');
            }
            final web = controller;
            if (web == null) continue;
            final state = await web.evaluateJavascript(
              source: '''JSON.stringify({
            rendered: !!document.querySelector('flutter-view'),
            connected: window.__devtoolsHasVM === true,
            sockets: window.__devtoolsSocketCount || 0,
              route: window.location.pathname + window.location.hash
          })''',
            );
            if (state is! String) continue;
            final result = jsonDecode(state) as Map<String, dynamic>;
            if (result['rendered'] == true &&
                result['connected'] == true &&
                (result['sockets'] as int) > 0) {
              final route = module == 'cpu' ? 'cpu-profiler' : module;
              expect(result['route'], contains(route));
              ready = true;
              break;
            }
          }
          expect(
            ready,
            isTrue,
            reason: '$module did not render and receive VM data',
          );
          await tester.pump(const Duration(seconds: 3));
          final methods = await controller!.evaluateJavascript(
            source: 'JSON.stringify(window.__devtoolsResponseMethods)',
          );
          final completedMethods = jsonDecode(methods as String) as List;
          expect(completedMethods, contains('getIsolate'));
          if (module == 'inspector') {
            expect(
              completedMethods.any(
                (method) => '$method'.startsWith('ext.flutter.inspector.'),
              ),
              isTrue,
              reason: 'Inspector did not receive its Flutter extension data',
            );
          }
          if (module == 'memory') {
            expect(
              completedMethods.any(
                (method) =>
                    '$method' == 'getMemoryUsage' ||
                    '$method' == 'getAllocationProfile',
              ),
              isTrue,
              reason: 'Memory did not receive profiling data',
            );
          }
          if (artifactDir.isNotEmpty) {
            final screenshot = await controller!.takeScreenshot();
            expect(screenshot, isNotNull);
            await Directory(artifactDir).create(recursive: true);
            await File(
              '$artifactDir/official-devtools-$module.png',
            ).writeAsBytes(screenshot!);
          }
          // Remove the platform view before closing the test-owned service.
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        }
        await bridge.closeDevTools(target.id);
        await bridge.stopSession(target.id);
        expect(
          (await bridge.listSessions())
              .firstWhere((s) => s.id == session!.id)
              .state,
          'ended',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (session != null) await bridge.closeDevTools(session.id);
        await bridge.shutdown();
      }
    },
    skip: !Platform.isMacOS || sdk.isEmpty || project.isEmpty,
  );
}
