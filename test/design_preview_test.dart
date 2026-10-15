// Opt-in local visual review using macOS system fonts and fixture data:
// flutter test test/design_preview_test.dart --dart-define=DESIGN_PREVIEW=true
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/app.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';

import 'build_dialog_test.dart' show BuildBridge;

const _enabled = bool.fromEnvironment('DESIGN_PREVIEW');

Future<void> _loadFont(String family, String path) async {
  final loader = FontLoader(family);
  loader.addFont(
    Future.value(ByteData.sublistView(await File(path).readAsBytes())),
  );
  await loader.load();
}

void main() {
  setUpAll(() async {
    if (!_enabled) return;
    await _loadFont('.AppleSystemUIFont', '/System/Library/Fonts/SFNS.ttf');
    await _loadFont('monospace', '/System/Library/Fonts/SFNSMono.ttf');
    final materialIcons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await materialIcons.load();
    final fonts = Directory(
      '/System/Library/AssetsV2/com_apple_MobileAsset_Font8',
    );
    final pingFang = fonts
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) => file.path.endsWith('/PingFang.ttc'));
    await _loadFont('PingFang SC', pingFang.path);
  });

  for (final mode in ['light', 'dark']) {
    testWidgets('capture $mode settings and build layouts', (tester) async {
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = true);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 960);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const project = Project(
        name: 'Clerk Platform',
        path: '/sample',
        platforms: ['android'],
      );
      final bridge = BuildBridge()
        ..appSettings = AppSettings(
          themeMode: mode,
          defaultSdkPath: '/Users/developer/flutter',
          projects: const [project],
          selectedProjectPath: project.path,
          buildPresets: const [
            BuildPreset(
              id: 'android',
              name: 'Android Release',
              target: 'apk',
              args: ['--release'],
            ),
          ],
        );
      addTearDown(bridge.controller.close);
      final captureKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: FlutterDevApp(bridge: bridge),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => precacheImage(
            const AssetImage('assets/branding/app-icon-128.png'),
            tester.element(find.byType(FlutterDevApp)),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            captureKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/design/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await tester.tap(find.byKey(const ValueKey('app-settings')));
      await capture('settings-$mode-implemented-v1');
      tester.view.physicalSize = const Size(560, 500);
      await capture('settings-$mode-narrow-v1');
      tester.view.physicalSize = const Size(1280, 960);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clerk Platform').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('build-project')));
      await capture('build-$mode-implemented-v1');
      tester.view.physicalSize = const Size(560, 500);
      await capture('build-$mode-narrow-v1');
      await tester.pumpWidget(const SizedBox());
      debugDisableShadows = true;
    }, skip: !_enabled);
  }
}
