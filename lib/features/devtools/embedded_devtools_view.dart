import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'windows_webview_data.dart';

/// One ordinary platform view, disposed with the selected DevTools tab.
class EmbeddedDevToolsView extends StatefulWidget {
  const EmbeddedDevToolsView({
    super.key,
    required this.url,
    required this.onError,
    this.windowsUserDataFolder,
  });
  final String url;
  final ValueChanged<String> onError;
  @visibleForTesting
  final Future<String> Function()? windowsUserDataFolder;

  @override
  State<EmbeddedDevToolsView> createState() => _EmbeddedDevToolsViewState();
}

class _EmbeddedDevToolsViewState extends State<EmbeddedDevToolsView> {
  InAppWebViewController? _controller;
  late final String _initialUrl = widget.url;
  int _navigation = 0, _progress = 0;
  bool _loading = true;
  bool _windowsReady = false;
  WebViewEnvironment? _windowsEnvironment;

  bool get _supported =>
      !kIsWeb &&
      const [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.iOS,
        TargetPlatform.android,
      ].contains(defaultTargetPlatform);

  @override
  void initState() {
    super.initState();
    if (_supported && defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(_checkWindowsRuntime());
    }
    if (!_supported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onError('当前平台不支持内嵌 WebView，可在系统浏览器中打开。');
      });
    }
  }

  Future<void> _checkWindowsRuntime() async {
    try {
      final version = await WebViewEnvironment.getAvailableVersion();
      if (!mounted) return;
      if (version == null || version.isEmpty) {
        widget.onError(
          '未找到 Microsoft Edge WebView2 Runtime。安装运行库后重试，或在系统浏览器中打开。',
        );
        return;
      }
      final folder =
          await (widget.windowsUserDataFolder ??
              windowsWebViewUserDataFolder)();
      if (!mounted) return;
      final environment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: folder),
      );
      if (!mounted) {
        await _disposeWindowsEnvironment(environment);
        return;
      }
      setState(() {
        _windowsEnvironment = environment;
        _windowsReady = true;
      });
    } catch (e) {
      if (mounted) widget.onError('WebView2 初始化失败：$e');
    }
  }

  Future<void> _disposeWindowsEnvironment(
    WebViewEnvironment environment,
  ) async {
    try {
      try {
        await environment.dispose();
      } on MissingPluginException {
        // flutter_inappwebview_windows 0.6.0 assigns the static factory's ID to
        // the Dart disposal channel. Native environments use their own ID.
        MethodChannel(
          'com.pichillilorenzo/flutter_webview_environment_${PlatformWebViewEnvironment.static().id}',
        ).setMethodCallHandler(null);
        await MethodChannel(
          'com.pichillilorenzo/flutter_webview_environment_${environment.id}',
        ).invokeMethod<void>('dispose');
      }
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Flutter Dev',
          context: ErrorDescription('while disposing a WebView2 environment'),
        ),
      );
    }
  }

  @override
  void didUpdateWidget(EmbeddedDevToolsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _navigation++;
      _progress = 0;
      _loading = true;
      unawaited(_navigate());
    }
  }

  Future<void> _navigate() async {
    final controller = _controller;
    if (controller == null) return;
    final navigation = _navigation;
    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(widget.url)));
    } catch (e) {
      if (mounted && navigation == _navigation) widget.onError('$e');
    }
  }

  bool _sameOrigin(WebUri? url) {
    final candidate = Uri.tryParse(url?.toString() ?? '');
    final expected = Uri.parse(widget.url);
    return candidate?.scheme == expected.scheme &&
        candidate?.host == expected.host &&
        candidate?.port == expected.port;
  }

  bool _current(WebUri? url) {
    if (!_sameOrigin(url)) return false;
    final candidate = Uri.tryParse(url?.toString() ?? '');
    final expected = Uri.parse(widget.url);
    try {
      return candidate?.path == expected.path &&
          candidate?.queryParameters['uri'] == expected.queryParameters['uri'];
    } on FormatException {
      return false;
    }
  }

  bool _userNavigation(NavigationAction action) =>
      action.hasGesture == true ||
      action.navigationType == NavigationType.LINK_ACTIVATED;

  Future<void> _openHelp(WebUri? value) async {
    final url = Uri.tryParse(value?.toString() ?? '');
    if (url == null || !const ['http', 'https'].contains(url.scheme)) return;
    try {
      final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('系统浏览器未能打开链接。')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('链接打开失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return const SizedBox();
    if (defaultTargetPlatform == TargetPlatform.windows && !_windowsReady) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        Positioned.fill(
          child: InAppWebView(
            webViewEnvironment: _windowsEnvironment,
            initialUrlRequest: URLRequest(url: WebUri(_initialUrl)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              transparentBackground: false,
              useShouldOverrideUrlLoading: true,
            ),
            shouldOverrideUrlLoading: (controller, action) async {
              if (!action.isForMainFrame || _sameOrigin(action.request.url)) {
                return NavigationActionPolicy.ALLOW;
              }
              if (_userNavigation(action)) await _openHelp(action.request.url);
              return NavigationActionPolicy.CANCEL;
            },
            onCreateWindow: (controller, action) async {
              if (_userNavigation(action)) await _openHelp(action.request.url);
              return false;
            },
            onWebViewCreated: (controller) {
              _controller = controller;
              if (_initialUrl != widget.url) unawaited(_navigate());
            },
            onLoadStart: (controller, url) {
              if (mounted && _current(url)) {
                setState(() {
                  _loading = true;
                  _progress = 0;
                });
              }
            },
            onLoadStop: (controller, url) {
              if (mounted && _current(url)) {
                setState(() {
                  _loading = false;
                  _progress = 100;
                });
              }
            },
            onProgressChanged: (controller, progress) {
              if (mounted) setState(() => _progress = progress);
            },
            onReceivedError: (controller, request, error) {
              if (error.type == WebResourceErrorType.CANCELLED ||
                  error.description == 'net::ERR_ABORTED') {
                return;
              }
              if (request.isForMainFrame == true &&
                  mounted &&
                  _current(request.url)) {
                widget.onError(error.description);
              }
            },
            onReceivedHttpError: (controller, request, response) {
              if (request.isForMainFrame == true &&
                  mounted &&
                  _current(request.url)) {
                widget.onError(
                  'HTTP ${response.statusCode ?? ''} ${response.reasonPhrase ?? ''}'
                      .trim(),
                );
              }
            },
          ),
        ),
        if (_loading)
          Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(
              minHeight: 2,
              value: _progress == 0 ? null : _progress / 100,
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _navigation++;
    _controller = null;
    // No keepAlive token: removing InAppWebView disposes its native platform view.
    final environment = _windowsEnvironment;
    _windowsEnvironment = null;
    if (environment != null) unawaited(_disposeWindowsEnvironment(environment));
    super.dispose();
  }
}
