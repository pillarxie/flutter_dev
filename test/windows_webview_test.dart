import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/features/devtools/embedded_devtools_view.dart';
import 'package:flutter_dev/features/devtools/windows_webview_data.dart';

class _Environment extends PlatformWebViewEnvironment {
  _Environment({this.id = 'profile', WebViewEnvironmentSettings? settings})
    : super.implementation(
        PlatformWebViewEnvironmentCreationParams(settings: settings),
      );

  @override
  final String id;
  int disposals = 0;
  bool wrongDisposalChannel = false;
  Object? disposalFailure;
  List<String>? lifecycle;

  @override
  Future<void> dispose() async {
    disposals++;
    lifecycle?.add('environment');
    if (wrongDisposalChannel) throw MissingPluginException('wrong factory ID');
    if (disposalFailure != null) throw disposalFailure!;
  }
}

class _EnvironmentFactory extends _Environment {
  _EnvironmentFactory() : super(id: 'factory');
  String? version = '120.0';
  final created = <_Environment>[];
  Completer<PlatformWebViewEnvironment>? pending;

  @override
  Future<String?> getAvailableVersion({
    String? browserExecutableFolder,
  }) async => version;

  @override
  Future<PlatformWebViewEnvironment> create({
    WebViewEnvironmentSettings? settings,
  }) async {
    final environment = _Environment(settings: settings);
    created.add(environment);
    return pending?.future ?? environment;
  }
}

class _Platform extends InAppWebViewPlatform {
  final environment = _EnvironmentFactory();
  final views = <_View>[];

  @override
  PlatformWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      environment;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = _View(params);
    views.add(view);
    return view;
  }
}

class _View extends PlatformInAppWebViewWidget {
  _View(super.params) : super.implementation();
  List<String>? lifecycle;

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      controller as T;
  @override
  void dispose() => lifecycle?.add('view');
}

void main() {
  test(
    'WebView profile is created under the local application data root',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'flutter-dev-webview-',
      );
      addTearDown(() => root.delete(recursive: true));
      final folder = await windowsWebViewUserDataFolder(
        environment: {'LOCALAPPDATA': root.path},
      );
      expect(Directory(folder).uri, root.uri.resolve('flutter_dev/WebView2/'));
      expect(await Directory(folder).exists(), isTrue);
      expect(
        await windowsWebViewUserDataFolder(
          environment: {'LOCALAPPDATA': root.path},
        ),
        folder,
      );
    },
  );

  test(
    'missing, empty or relative local data roots never use the install folder',
    () async {
      for (final environment in <Map<String, String>>[
        {},
        {'LOCALAPPDATA': ' '},
        {'LOCALAPPDATA': 'relative'},
      ]) {
        await expectLater(
          windowsWebViewUserDataFolder(environment: environment),
          throwsStateError,
        );
      }
    },
  );

  test(
    'profile creation failures propagate without an install-directory fallback',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'flutter-dev-webview-',
      );
      addTearDown(() => root.delete(recursive: true));
      await File.fromUri(
        root.uri.resolve('flutter_dev'),
      ).writeAsString('blocked');
      await expectLater(
        windowsWebViewUserDataFolder(environment: {'LOCALAPPDATA': root.path}),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  group('Windows embedded environment', () {
    late _Platform platform;
    late List<String> errors;
    setUp(() {
      platform = _Platform();
      errors = [];
      final previous = InAppWebViewPlatform.instance;
      InAppWebViewPlatform.instance = platform;
      addTearDown(() {
        if (previous != null) InAppWebViewPlatform.instance = previous;
      });
    });

    Future<void> show(
      WidgetTester tester, {
      Future<String> Function()? folder,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: EmbeddedDevToolsView(
            url: 'http://localhost:9100/inspector',
            onError: errors.add,
            windowsUserDataFolder:
                folder ?? () async => '/local/flutter_dev/WebView2',
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets(
      'explicit profile environment reaches the view and is disposed',
      (tester) async {
        await show(tester);
        final environment = platform.environment.created.single;
        expect(
          environment.settings!.userDataFolder,
          '/local/flutter_dev/WebView2',
        );
        expect(
          platform.views.single.params.webViewEnvironment!.id,
          environment.id,
        );
        final lifecycle = <String>[];
        environment.lifecycle = lifecycle;
        platform.views.single.lifecycle = lifecycle;
        await tester.pumpWidget(const SizedBox());
        expect(environment.disposals, 1);
        expect(lifecycle, ['view', 'environment']);
        expect(errors, isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'a late created environment is disposed after its view is removed',
      (tester) async {
        final pending = Completer<PlatformWebViewEnvironment>();
        platform.environment.pending = pending;
        await show(tester);
        final environment = platform.environment.created.single;
        await tester.pumpWidget(const SizedBox());
        pending.complete(environment);
        await tester.pump();
        expect(environment.disposals, 1);
        expect(platform.views, isEmpty);
        expect(errors, isEmpty);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'leaving during directory creation does not create an environment',
      (tester) async {
        final folder = Completer<String>();
        await show(tester, folder: () => folder.future);
        await tester.pumpWidget(const SizedBox());
        folder.complete('/local/flutter_dev/WebView2');
        await tester.pump();
        expect(platform.environment.created, isEmpty);
        expect(errors, isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'a late initialization failure does not report to a removed view',
      (tester) async {
        final pending = Completer<PlatformWebViewEnvironment>();
        platform.environment.pending = pending;
        await show(tester);
        await tester.pumpWidget(const SizedBox());
        pending.completeError(StateError('late environment failure'));
        await tester.pump();
        expect(errors, isEmpty);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'environment disposal errors remain visible to Flutter error reporting',
      (tester) async {
        await show(tester);
        platform.environment.created.single.disposalFailure = StateError(
          'environment disposal failed',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(tester.takeException(), isA<StateError>());
        expect(errors, isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'missing runtime or unwritable profile reports a usable failure',
      (tester) async {
        platform.environment.version = null;
        await show(tester);
        expect(errors.single, contains('WebView2 Runtime'));
        expect(platform.environment.created, isEmpty);
        await tester.pumpWidget(const SizedBox());
        errors.clear();
        platform.environment.version = '120.0';
        await show(
          tester,
          folder: () async => throw const FileSystemException('denied'),
        );
        expect(errors.single, contains('denied'));
        expect(platform.environment.created, isEmpty);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('0.6.0 disposal fallback targets the created environment ID', (
      tester,
    ) async {
      await show(tester);
      final environment = platform.environment.created.single;
      environment.wrongDisposalChannel = true;
      final calls = <String>[];
      final channel = MethodChannel(
        'com.pichillilorenzo/flutter_webview_environment_${environment.id}',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final factoryChannel = MethodChannel(
        'com.pichillilorenzo/flutter_webview_environment_${platform.environment.id}',
      );
      var dartCallbacks = 0;
      factoryChannel.setMethodCallHandler((call) async {
        dartCallbacks++;
        return null;
      });
      addTearDown(() => factoryChannel.setMethodCallHandler(null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls, ['dispose']);
      expect(environment.disposals, 1);
      expect(tester.takeException(), isNull);
      final response = await messenger.handlePlatformMessage(
        factoryChannel.name,
        factoryChannel.codec.encodeMethodCall(const MethodCall('probe')),
        null,
      );
      expect(response, isNull);
      expect(dartCallbacks, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });
}
