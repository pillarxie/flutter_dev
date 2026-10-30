import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/bridge/generated/api/core.dart' as api;
import 'package:flutter_dev/core/bridge/generated/build.dart';
import 'package:flutter_dev/core/bridge/generated/frb_generated.dart';
import 'package:flutter_dev/core/bridge/generated/project.dart';

void main() {
  const library = String.fromEnvironment('FLUTTER_DEV_NATIVE_LIBRARY');
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'actual FFI clears imported project builds and preserves source and unrelated output',
    () async {
      expect(Platform.environment['FLUTTER_DEV_SETTINGS_PATH'], isNotEmpty);
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      final directory = await Directory.systemTemp.createTemp(
        'flutter-dev-build-cache-',
      );
      final root = await directory.resolveSymbolicLinks();
      try {
        final imported = <ProjectInfo>[];
        for (final name in ['导入项目一', 'imported project two', 'unimported']) {
          final project = Directory('$root/$name');
          await Directory('${project.path}/lib').create(recursive: true);
          await File('${project.path}/pubspec.yaml').writeAsString(
            'name: cache_sample\ndependencies:\n  flutter:\n    sdk: flutter\n',
          );
          await File(
            '${project.path}/lib/main.dart',
          ).writeAsString('void main() {}\n');
          await Directory(
            '${project.path}/build/app/assets',
          ).create(recursive: true);
          await File(
            '${project.path}/build/app/app.apk',
          ).writeAsString('owned build package');
          await File(
            '${project.path}/build/app/assets/asset.txt',
          ).writeAsString('owned nested build asset');
          if (name != 'unimported') {
            imported.add(
              ProjectInfo(
                name: name,
                path: project.path,
                entrypoint: 'lib/main.dart',
                platforms: const ['android'],
              ),
            );
          }
        }
        final revealDirectory = Directory('$root/reveal-only');
        await revealDirectory.create();
        final unrelated = File('${revealDirectory.path}/personal.txt');
        await unrelated.writeAsString('not produced by a build task');
        await api.setWorkspaceProjects(
          projects: imported,
          selectedProjectPath: imported.first.path,
        );
        await api.setBuildPresets(
          projectPath: imported.first.path,
          presets: [
            BuildPreset(
              id: 'reveal-only',
              name: 'Reveal directory is not a build output',
              target: 'apk',
              args: const ['--release'],
              outputDirectory: revealDirectory.path,
            ),
          ],
        );

        String? stoppedBuildId;
        if (!Platform.isWindows) {
          final sdk = Directory('$root/sdk');
          await Directory('${sdk.path}/bin').create(recursive: true);
          final flutter = File('${sdk.path}/bin/flutter');
          await flutter.writeAsString('''#!/bin/sh
if [ "\$1" = "--version" ]; then
  printf '%s\\n' '{"frameworkVersion":"3.cache","dartSdkVersion":"3.dart"}'
  exit 0
fi
printf '%s\\n' 'build-cache-busy-marker'
while :; do sleep 1; done
''');
          expect(
            (await Process.run('chmod', ['755', flutter.path])).exitCode,
            0,
          );
          var active = await api.startBuild(
            config: BuildConfiguration(
              projectPath: imported.first.path,
              sdkPath: sdk.path,
              target: 'apk',
              args: const ['--release'],
            ),
          );
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          var hasMarker = false;
          while (DateTime.now().isBefore(deadline)) {
            active = await api.buildSnapshot(buildId: active.id);
            final logs = await api.readBuildLogs(
              buildId: active.id,
              afterId: 0,
              limit: 100,
            );
            hasMarker = logs.entries.any(
              (entry) => entry.text.contains('build-cache-busy-marker'),
            );
            if (active.state == 'running' && hasMarker) break;
            if (const [
              'failed',
              'succeeded',
              'cancelled',
            ].contains(active.state)) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(active.state, 'running', reason: active.error);
          expect(hasMarker, isTrue);
          await expectLater(
            api.clearBuildCache(),
            throwsA(
              predicate((error) => '$error'.contains('Stop all build tasks')),
            ),
          );
          for (final project in imported) {
            expect(
              await File('${project.path}/build/app/app.apk').readAsString(),
              'owned build package',
            );
          }
          expect(await unrelated.exists(), isTrue);
          await api.stopBuild(buildId: active.id);
          expect(
            (await api.buildSnapshot(buildId: active.id)).state,
            'cancelled',
          );
          stoppedBuildId = active.id;
        }

        final result = await api.clearBuildCache();
        expect(result.errors, isEmpty);
        expect(
          result.deletedPaths,
          unorderedEquals(imported.map((project) => '${project.path}/build')),
        );
        for (final project in imported) {
          expect(await Directory('${project.path}/build').exists(), isFalse);
          expect(await File('${project.path}/pubspec.yaml').exists(), isTrue);
          expect(
            await File('${project.path}/lib/main.dart').readAsString(),
            'void main() {}\n',
          );
        }
        expect(
          await File('$root/unimported/build/app/app.apk').readAsString(),
          'owned build package',
        );
        expect(await unrelated.readAsString(), 'not produced by a build task');
        expect((await api.getAppSettings()).projects, hasLength(2));
        expect(
          (await api.getBuildPresets(
            projectPath: imported.first.path,
          )).single.outputDirectory,
          revealDirectory.path,
        );
        expect(
          (await api.getBuildPresets(
            projectPath: imported.last.path,
          )).any((preset) => preset.id == 'reveal-only'),
          isFalse,
        );
        if (stoppedBuildId != null) {
          final logs = await api.readBuildLogs(
            buildId: stoppedBuildId,
            afterId: 0,
            limit: 100,
          );
          expect(
            logs.entries.any(
              (entry) => entry.text.contains('build-cache-busy-marker'),
            ),
            isTrue,
          );
        }

        final repeated = await api.clearBuildCache();
        expect(repeated.errors, isEmpty);
        expect(repeated.deletedPaths, isEmpty);
      } finally {
        await api.shutdownCore();
        RustLib.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip:
        library.isEmpty ||
            Platform.environment['FLUTTER_DEV_SETTINGS_PATH'] == null
        ? 'Run with FLUTTER_DEV_NATIVE_LIBRARY and an isolated FLUTTER_DEV_SETTINGS_PATH.'
        : false,
  );
}
