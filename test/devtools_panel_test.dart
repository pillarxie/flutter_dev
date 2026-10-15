import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';
import 'package:flutter_dev/core/presentation/workbench_theme.dart';
import 'package:flutter_dev/features/devtools/devtools_panel.dart';
import 'package:flutter_dev/features/devtools/embedded_devtools_view.dart';
import 'package:flutter_dev/features/devtools/network_panel.dart';

import 'network_panel_test.dart' show NetworkFake;

Session session({
  String id = 'one',
  int generation = 1,
  String state = 'running',
  String mode = 'debug',
  String? uri = 'ws://localhost:123/ws',
  String? operation,
  Map<String, bool> capabilities = const {},
}) => Session(
  id: id,
  generation: generation,
  state: state,
  projectPath: '/app',
  deviceId: 'macos',
  mode: mode,
  serviceUri: uri,
  operation: operation,
  capabilities: capabilities,
);

class DevToolsFake extends NetworkFake {
  final lifecycle = <String>[];
  final liveServers = <String>{};
  Future<String> Function(String, String)? open;
  Future<void> Function(String)? close;
  @override
  Future<String> openDevTools(String id, String module) async {
    lifecycle.add('open:$id:$module');
    final url = open == null
        ? 'http://localhost:9100/$module?compiler=js&uri=$id'
        : await open!(id, module);
    liveServers.add(id);
    return url;
  }

  @override
  Future<void> closeDevTools(String id) async {
    lifecycle.add('close:$id');
    await close?.call(id);
    liveServers.remove(id);
  }
}

class ViewTracker {
  int created = 0, disposed = 0;
  ValueChanged<String>? error;
  Widget build(BuildContext context, String url, ValueChanged<String> onError) {
    error = onError;
    return _TestView(url: url, tracker: this);
  }
}

class _TestView extends StatefulWidget {
  const _TestView({required this.url, required this.tracker});
  final String url;
  final ViewTracker tracker;
  @override
  State<_TestView> createState() => _TestViewState();
}

class _TestViewState extends State<_TestView> {
  @override
  void initState() {
    super.initState();
    widget.tracker.created++;
  }

  @override
  void dispose() {
    widget.tracker.disposed++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Center(child: Text('embedded:${widget.url}'));
}

class _WebViewPlatformFake extends InAppWebViewPlatform {
  late _PlatformViewFake last;
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    return last = _PlatformViewFake(params);
  }
}

class _PlatformViewFake extends PlatformInAppWebViewWidget {
  _PlatformViewFake(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      (params.controllerFromPlatform?.call(controller) ?? controller) as T;
  @override
  void dispose() {}
}

class _PlatformControllerFake extends PlatformInAppWebViewController {
  _PlatformControllerFake()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'test'),
      );
  final navigated = <String>[];
  @override
  Future<void> loadUrl({
    required URLRequest urlRequest,
    Uri? iosAllowingReadAccessTo,
    WebUri? allowingReadAccessTo,
  }) async {
    navigated.add(urlRequest.url.toString());
  }
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

Future<void> mount(
  WidgetTester tester,
  DevToolsFake bridge,
  ViewTracker tracker, {
  Session? selected,
  Size size = const Size(1000, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await update(tester, bridge, tracker, selected ?? session());
}

Future<void> update(
  WidgetTester tester,
  DevToolsFake bridge,
  ViewTracker tracker,
  Session? selected,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: workbenchTheme(Brightness.light),
      home: Scaffold(
        body: DevToolsPanel(
          bridge: bridge,
          session: selected,
          embeddedViewBuilder: tracker.build,
        ),
      ),
    ),
  );
  await frames(tester);
}

Future<void> choose(WidgetTester tester, String module) async {
  final button = find.byKey(ValueKey('devtools-module-$module'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await frames(tester);
}

Future<void> dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await frames(tester);
}

void main() {
  testWidgets(
    'network remains native and official tabs open lazily using one embedded view',
    (tester) async {
      final bridge = DevToolsFake();
      final tracker = ViewTracker();
      await mount(tester, bridge, tracker);
      expect(find.byType(NetworkPanel), findsOneWidget);
      expect(bridge.lifecycle, isEmpty);
      await choose(tester, 'inspector');
      expect(bridge.lifecycle, ['open:one:inspector']);
      expect(
        find.textContaining('embedded:http://localhost:9100/inspector'),
        findsOneWidget,
      );
      expect(tracker.created, 1);
      for (final module in ['performance', 'cpu', 'memory', 'logging']) {
        await choose(tester, module);
        expect(
          find.textContaining('embedded:http://localhost:9100/$module'),
          findsOneWidget,
        );
        expect(tracker.created, 1);
        expect(find.byType(_TestView), findsOneWidget);
      }
      await choose(tester, 'network');
      expect(bridge.lifecycle.last, 'close:one');
      expect(bridge.liveServers, isEmpty);
      expect(tracker.disposed, 1);
      expect(find.byType(NetworkPanel), findsOneWidget);
      await dispose(tester);
    },
  );

  testWidgets(
    'stale module launch closes before newest launch and never displays its URL',
    (tester) async {
      final bridge = DevToolsFake();
      final tracker = ViewTracker();
      final pending = Completer<String>();
      bridge.open = (id, module) async => module == 'inspector'
          ? pending.future
          : 'http://localhost:9100/$module';
      await mount(tester, bridge, tracker);
      await choose(tester, 'inspector');
      await choose(tester, 'performance');
      expect(bridge.lifecycle, ['open:one:inspector']);
      pending.complete('http://stale.test/inspector');
      await frames(tester);
      expect(bridge.lifecycle, [
        'open:one:inspector',
        'close:one',
        'open:one:performance',
      ]);
      expect(find.textContaining('stale.test'), findsNothing);
      expect(
        find.textContaining('embedded:http://localhost:9100/performance'),
        findsOneWidget,
      );
      expect(bridge.liveServers, {'one'});
      await dispose(tester);
      expect(bridge.liveServers, isEmpty);
    },
  );

  testWidgets(
    'pending old panel disposal cannot close newly reopened same session server',
    (tester) async {
      final bridge = DevToolsFake();
      final tracker = ViewTracker();
      final pending = Completer<String>();
      var launches = 0;
      bridge.open = (id, module) async => ++launches == 1
          ? pending.future
          : 'http://localhost:9100/$module/new';
      await mount(tester, bridge, tracker);
      await choose(tester, 'inspector');
      await dispose(tester);
      await update(tester, bridge, tracker, session());
      await choose(tester, 'memory');
      expect(launches, 1);
      pending.complete('http://stale.test/');
      await frames(tester);
      expect(bridge.lifecycle, [
        'open:one:inspector',
        'close:one',
        'open:one:memory',
      ]);
      expect(bridge.liveServers, {'one'});
      expect(find.textContaining('/memory/new'), findsOneWidget);
      await dispose(tester);
    },
  );

  testWidgets(
    'session URI and generation changes rebind and hot restart waits for connection',
    (tester) async {
      final bridge = DevToolsFake();
      final tracker = ViewTracker();
      final pending = Completer<String>();
      bridge.open = (id, module) async =>
          id == 'one' ? pending.future : 'http://localhost:9100/$module/$id';
      await mount(tester, bridge, tracker);
      await choose(tester, 'cpu');
      await update(
        tester,
        bridge,
        tracker,
        session(id: 'two', uri: 'ws://localhost:234/ws'),
      );
      pending.complete('http://stale.test/one');
      await frames(tester);
      expect(find.textContaining('stale.test'), findsNothing);
      expect(bridge.lifecycle, ['open:one:cpu', 'close:one', 'open:two:cpu']);
      await update(
        tester,
        bridge,
        tracker,
        session(id: 'two', generation: 2, uri: 'ws://localhost:345/ws'),
      );
      expect(bridge.lifecycle.last, 'open:two:cpu');
      expect(tracker.created, 2);
      await update(
        tester,
        bridge,
        tracker,
        session(
          id: 'two',
          generation: 2,
          operation: 'hotRestart',
          uri: 'ws://localhost:345/ws',
        ),
      );
      expect(find.textContaining('热重启中'), findsOneWidget);
      expect(bridge.lifecycle.last, 'close:two');
      final count = bridge.lifecycle.length;
      await tester.pump(const Duration(seconds: 2));
      expect(bridge.lifecycle.length, count);
      await update(
        tester,
        bridge,
        tracker,
        session(id: 'two', generation: 2, uri: 'ws://localhost:345/ws'),
      );
      expect(bridge.lifecycle.last, 'open:two:cpu');
      await update(
        tester,
        bridge,
        tracker,
        session(
          id: 'two',
          generation: 2,
          state: 'ended',
          uri: 'ws://localhost:345/ws',
        ),
      );
      expect(find.textContaining('会话已结束'), findsOneWidget);
      expect(bridge.lifecycle.last, 'close:two');
      await dispose(tester);
    },
  );

  testWidgets(
    'profile and noDebug service connections allow profiling, inspector remains debug only',
    (tester) async {
      final bridge = DevToolsFake();
      final tracker = ViewTracker();
      await mount(
        tester,
        bridge,
        tracker,
        selected: session(mode: 'profile', capabilities: {'debugger': false}),
      );
      await choose(tester, 'inspector');
      expect(find.textContaining('Inspector 需要 Debug'), findsOneWidget);
      expect(bridge.lifecycle, isEmpty);
      await choose(tester, 'memory');
      expect(bridge.lifecycle.last, 'open:one:memory');
      await update(
        tester,
        bridge,
        tracker,
        session(capabilities: {'debugger': false}),
      );
      expect(find.textContaining('embedded:'), findsOneWidget);
      await update(tester, bridge, tracker, session(mode: 'release'));
      expect(find.textContaining('Release 模式'), findsOneWidget);
      expect(bridge.lifecycle.last, 'close:one');
      await dispose(tester);
    },
  );

  testWidgets(
    'connection unavailable state reconnects and launch/embed failures offer appropriate retry',
    (tester) async {
      final bridge = DevToolsFake();
      final tracker = ViewTracker();
      await mount(tester, bridge, tracker, selected: session(uri: null));
      await choose(tester, 'performance');
      expect(find.textContaining('等待会话连接'), findsOneWidget);
      expect(bridge.lifecycle, isEmpty);
      bridge.open = (id, module) async => throw StateError('SDK 启动失败');
      await update(tester, bridge, tracker, session());
      expect(find.textContaining('SDK 启动失败'), findsOneWidget);
      expect(find.text('在浏览器中打开'), findsNothing);
      bridge.open = null;
      await tester.tap(find.text('重试内嵌页面'));
      await frames(tester);
      expect(find.textContaining('embedded:'), findsOneWidget);
      tracker.error!('WebView 不可用');
      await frames(tester);
      expect(find.textContaining('WebView 不可用'), findsOneWidget);
      expect(find.text('在浏览器中打开'), findsOneWidget);
      expect(tracker.disposed, 1);
      await tester.tap(find.text('重试内嵌页面'));
      await frames(tester);
      expect(find.textContaining('embedded:'), findsOneWidget);
      await dispose(tester);
    },
  );

  testWidgets(
    'native old-module callbacks and canceled loads do not fail the active embedded module',
    (tester) async {
      final previousPlatform = InAppWebViewPlatform.instance;
      final platform = _WebViewPlatformFake();
      InAppWebViewPlatform.instance = platform;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        if (previousPlatform != null) {
          InAppWebViewPlatform.instance = previousPlatform;
        }
      });
      try {
        const oldUrl =
            'http://127.0.0.1:9100/inspector?uri=ws%3A%2F%2Flocalhost%2Fa%2526%2Fws&compiler=js';
        const currentUrl =
            'http://127.0.0.1:9100/memory?uri=ws%3A%2F%2Flocalhost%2Fa%2526%2Fws&compiler=js';
        final errors = <String>[];
        Future<void> show(String url) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: EmbeddedDevToolsView(url: url, onError: errors.add),
              ),
            ),
          );
          await tester.pump();
        }

        await show(oldUrl);
        final oldParams = platform.last.params;
        final nativeController = _PlatformControllerFake();
        final controller = InAppWebViewController.fromPlatform(
          platform: nativeController,
        );
        oldParams.onWebViewCreated!(controller);
        await show(currentUrl);
        expect(nativeController.navigated, [currentUrl]);
        final params = platform.last.params;
        void error(
          String url,
          WebResourceErrorType type, {
          bool mainFrame = true,
        }) {
          params.onReceivedError!(
            controller,
            WebResourceRequest(url: WebUri(url), isForMainFrame: mainFrame),
            WebResourceError(type: type, description: 'load failed'),
          );
        }

        error(oldUrl, WebResourceErrorType.BAD_URL);
        error(
          currentUrl.replaceAll('a%2526', 'different'),
          WebResourceErrorType.BAD_URL,
        );
        error(currentUrl, WebResourceErrorType.CANCELLED);
        error(currentUrl, WebResourceErrorType.BAD_URL, mainFrame: false);
        expect(errors, isEmpty);
        oldParams.onLoadStop!(controller, WebUri(oldUrl));
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        final bootstrapUrl = '$currentUrl&wasm=false';
        params.onLoadStop!(controller, WebUri(bootstrapUrl));
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsNothing);
        error(bootstrapUrl, WebResourceErrorType.BAD_URL);
        expect(errors, ['load failed']);
        final policy = await params.shouldOverrideUrlLoading!(
          controller,
          NavigationAction(
            isForMainFrame: true,
            request: URLRequest(url: WebUri(oldUrl)),
          ),
        );
        expect(policy, NavigationActionPolicy.ALLOW);
        await dispose(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        if (previousPlatform != null) {
          InAppWebViewPlatform.instance = previousPlatform;
        }
      }
    },
  );

  testWidgets(
    'official embedded URL follows workbench theme without reopening its server',
    (tester) async {
      final bridge = DevToolsFake();
      final tracker = ViewTracker();
      const original =
          'http://localhost:9100/memory?uri=ws%3A%2F%2Flocalhost%2Ftoken%252B%2Fws&compiler=js&hide=debugger&hide=network';
      bridge.open = (id, module) async => original;
      await mount(tester, bridge, tracker);
      await choose(tester, 'memory');
      String renderedUrl() =>
          tester.widget<_TestView>(find.byType(_TestView)).url;
      final light = Uri.parse(renderedUrl());
      expect(light.queryParameters['theme'], 'light');
      expect(light.queryParameters['uri'], 'ws://localhost/token%2B/ws');
      expect(light.queryParameters['compiler'], 'js');
      expect(light.queryParametersAll['hide'], ['debugger', 'network']);
      await tester.pumpWidget(
        MaterialApp(
          theme: workbenchTheme(Brightness.dark),
          home: Scaffold(
            body: DevToolsPanel(
              bridge: bridge,
              session: session(),
              embeddedViewBuilder: tracker.build,
            ),
          ),
        ),
      );
      await frames(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(Uri.parse(renderedUrl()).queryParameters['theme'], 'dark');
      expect(bridge.lifecycle, ['open:one:memory']);
      expect(tracker.created, 1);
      await dispose(tester);
    },
  );

  testWidgets(
    '312px module bar scrolls to every module without layout overflow',
    (tester) async {
      final bridge = DevToolsFake();
      final tracker = ViewTracker();
      await mount(tester, bridge, tracker, size: const Size(312, 700));
      await choose(tester, 'logging');
      expect(
        find.textContaining('embedded:http://localhost:9100/logging'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await choose(tester, 'network');
      expect(find.byType(NetworkPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await dispose(tester);
    },
  );
}
