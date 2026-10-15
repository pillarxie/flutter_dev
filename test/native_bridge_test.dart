import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/bridge/generated/api/core.dart' as api;
import 'package:flutter_dev/core/bridge/generated/build.dart' as build;
import 'package:flutter_dev/core/bridge/generated/frb_generated.dart';
import 'package:flutter_dev/core/bridge/generated/project.dart' as project;
import 'package:flutter_dev/core/bridge/generated/session.dart';

void main() {
  const library = String.fromEnvironment('FLUTTER_DEV_NATIVE_LIBRARY');
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'actual FFI preserves typed data, Unicode and terminal session events',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      final directory = await Directory.systemTemp.createTemp(
        'flutter-dev-bridge-',
      );
      StreamSubscription<CoreEvent>? subscription;
      try {
        await File('${directory.path}/pubspec.yaml').writeAsString(
          'name: bridge_sample\ndependencies:\n  flutter:\n    sdk: flutter\n',
        );
        await Directory('${directory.path}/lib').create();
        final source = File('${directory.path}/lib/main.dart');
        await source.writeAsString('void main() {\n  print("你好 🦀");\n}\n');
        final projects = await api.discoverProjects(root: directory.path);
        expect(projects.single.name, 'bridge_sample');
        await expectLater(
          api.openDevtools(sessionId: 'missing', module: 'memory'),
          throwsA(predicate((error) => '$error'.contains('Unknown session'))),
        );
        await api.closeDevtools(sessionId: 'missing');
        await expectLater(
          api.networkRequest(
            sessionId: 'missing',
            method: 'getVM',
            paramsJson: '{}',
          ),
          throwsA(predicate((error) => '$error'.contains('Unknown session'))),
        );
        await expectLater(
          api.networkRequest(
            sessionId: 'missing',
            method: 'evaluate',
            paramsJson: '{}',
          ),
          throwsA(
            predicate((error) => '$error'.contains('Unsupported network')),
          ),
        );
        final page = await api.readSource(
          path: source.path,
          startLine: 2,
          limit: 1,
        );
        expect(page.lines.single, contains('你好 🦀'));
        expect(page.totalLines, 3);

        // All native tests use a dedicated settings file, never personal settings.
        expect(Platform.environment['FLUTTER_DEV_SETTINGS_PATH'], isNotEmpty);
        await api.setDefaultSdk(path: null);
        final dark = await api.setThemeMode(mode: 'dark');
        expect(dark.themeMode, 'dark');
        expect((await api.getAppSettings()).themeMode, 'dark');
        await expectLater(api.setThemeMode(mode: 'system'), throwsA(anything));
        expect((await api.getAppSettings()).themeMode, 'dark');
        final sdkDirectory = Directory('${directory.path}/sdk');
        await Directory('${sdkDirectory.path}/bin').create(recursive: true);
        final program = File(
          '${sdkDirectory.path}/bin/${Platform.isWindows ? 'flutter.bat' : 'flutter'}',
        );
        const version =
            '{"frameworkVersion":"3.bridge","dartSdkVersion":"3.dart"}';
        await program.writeAsString(
          Platform.isWindows
              ? '@echo off\r\necho $version\r\n'
              : '#!/bin/sh\nprintf \'%s\\n\' \'$version\'\n',
        );
        if (!Platform.isWindows) {
          final chmod = await Process.run('chmod', ['755', program.path]);
          expect(chmod.exitCode, 0);
        }
        final saved = await api.setDefaultSdk(path: sdkDirectory.path);
        expect(saved.defaultSdkPath, await sdkDirectory.resolveSymbolicLinks());
        expect(saved.themeMode, 'dark');
        final light = await api.setThemeMode(mode: 'light');
        expect(light.themeMode, 'light');
        expect(light.defaultSdkPath, saved.defaultSdkPath);
        expect(
          (await api.getAppSettings()).defaultSdkPath,
          saved.defaultSdkPath,
        );
        await expectLater(
          api.setDefaultSdk(path: '${directory.path}/missing'),
          throwsA(anything),
        );
        expect(
          (await api.getAppSettings()).defaultSdkPath,
          saved.defaultSdkPath,
        );
        final fallback = await api.resolveSdk(
          projectPath: directory.path,
          explicitPath: '${directory.path}/missing-sdk',
        );
        expect(fallback.path, saved.defaultSdkPath);
        expect(fallback.source, 'globalFallback');
        expect(fallback.fallbackReason, isNotEmpty);
        final independent = await api.resolveSdk(
          projectPath: directory.path,
          explicitPath: sdkDirectory.path,
        );
        expect(independent.source, 'explicit');
        expect(independent.fallbackReason, isNull);

        final presets = await api.setBuildPresets(
          presets: const [
            build.BuildPreset(
              id: 'unicode-build',
              name: '测试构建 🦀',
              target: 'bundle',
              args: ['--debug', '--dart-define=NAME=你好 世界'],
              outputDirectory: '自定义产物',
            ),
          ],
        );
        expect(presets.buildPresets.single.name, '测试构建 🦀');
        expect(presets.defaultSdkPath, saved.defaultSdkPath);
        expect(
          (await api.setThemeMode(mode: 'light')).buildPresets.single.args,
          ['--debug', '--dart-define=NAME=你好 世界'],
        );
        expect(
          (await api.getAppSettings()).buildPresets.single.outputDirectory,
          '自定义产物',
        );

        final missingProject = project.ProjectInfo(
          name: '已移动的项目 🦀',
          path: '${directory.path}/missing-project',
          entrypoint: 'lib/custom.dart',
          platforms: const ['macos', 'web'],
        );
        final workspace = await api.setWorkspaceProjects(
          projects: [projects.single, missingProject, projects.single],
          selectedProjectPath: missingProject.path,
        );
        expect(workspace.projects, hasLength(2));
        expect(workspace.projects.last.name, missingProject.name);
        expect(workspace.projects.last.entrypoint, 'lib/custom.dart');
        expect(workspace.projects.last.platforms, ['macos', 'web']);
        expect(workspace.selectedProjectPath, missingProject.path);
        expect(workspace.defaultSdkPath, saved.defaultSdkPath);
        expect(workspace.buildPresets.single.name, '测试构建 🦀');
        final workspaceAfterTheme = await api.setThemeMode(mode: 'light');
        expect(workspaceAfterTheme.projects, hasLength(2));
        expect(workspaceAfterTheme.selectedProjectPath, missingProject.path);
        await expectLater(
          api.setWorkspaceProjects(
            projects: [projects.single],
            selectedProjectPath: '${directory.path}/not-imported',
          ),
          throwsA(anything),
        );
        final restoredWorkspace = await api.getAppSettings();
        expect(restoredWorkspace.projects.last.path, missingProject.path);
        expect(restoredWorkspace.selectedProjectPath, missingProject.path);

        // The build fixture fails deliberately, avoiding an actual desktop opener.
        await program.writeAsString(
          Platform.isWindows
              ? '@echo off\r\nif "%1"=="--version" (\r\necho $version\r\nexit /b 0\r\n)\r\necho build fixture failed 1>&2\r\nexit /b 23\r\n'
              : '#!/bin/sh\nif [ "\$1" = "--version" ]; then\nprintf \'%s\\n\' \'$version\'\nexit 0\nfi\nprintf \'%s\\n\' \'build fixture failed\' >&2\nexit 23\n',
        );
        final startedBuild = await api.startBuild(
          config: build.BuildConfiguration(
            projectPath: directory.path,
            sdkPath: sdkDirectory.path,
            target: 'bundle',
            args: const ['--debug'],
            outputDirectory: null,
          ),
        );
        final failedBuild = await waitForBuildTerminal(startedBuild.id);
        expect(failedBuild.state, 'failed');
        expect(failedBuild.exitCode, 23);
        final buildLogs = await api.readBuildLogs(
          buildId: startedBuild.id,
          afterId: 0,
          limit: 100,
        );
        expect(
          buildLogs.entries.any(
            (entry) => entry.text.contains('build fixture failed'),
          ),
          isTrue,
        );
        await expectLater(
          api.openBuildOutput(buildId: startedBuild.id),
          throwsA(anything),
        );
        await api.stopBuild(buildId: startedBuild.id);

        final fallbackSession = await api.startSession(
          config: RunConfiguration(
            projectPath: directory.path,
            sdkPath: '${directory.path}/missing-sdk',
            program: 'lib/main.dart',
            deviceId: 'bridge-test',
            mode: RunMode.debug,
            noDebug: false,
            attachUri: null,
            env: const [],
            toolArgs: const [],
            args: const [],
            flavor: null,
            dartDefines: const [],
          ),
        );
        final resolvedSession = await waitForTerminal(
          fallbackSession.sessionId,
        );
        // This fixture SDK implements version probing only, so its adapter exits.
        expect(resolvedSession.sdkPath, saved.defaultSdkPath);
        final fallbackLogs = await api.readLogs(
          sessionId: fallbackSession.sessionId,
          afterId: 0,
          limit: 100,
          query: 'global SDK',
        );
        expect(
          fallbackLogs.entries.any((entry) => entry.category == 'warning'),
          isTrue,
        );
        await api.shutdownCore();
        await api.setDefaultSdk(path: null);
        expect((await api.getAppSettings()).defaultSdkPath, isNull);
        expect((await api.getAppSettings()).themeMode, 'light');
        expect((await api.getAppSettings()).projects, hasLength(2));
        expect(
          (await api.getAppSettings()).selectedProjectPath,
          missingProject.path,
        );

        final terminal = Completer<CoreEvent>();
        subscription = api.subscribeEvents().listen((event) {
          if (event.kind == CoreEventKind.state &&
              event.payload.contains('Failed') &&
              !terminal.isCompleted) {
            terminal.complete(event);
          }
        });
        final session = await api.startSession(
          config: RunConfiguration(
            projectPath: directory.path,
            sdkPath: '${directory.path}/missing-sdk',
            program: 'lib/main.dart',
            deviceId: 'bridge-test',
            mode: RunMode.debug,
            noDebug: false,
            attachUri: null,
            env: const [],
            toolArgs: const [],
            args: const [],
            flavor: null,
            dartDefines: const [],
          ),
        );
        expect(session.state, SessionState.preparing);
        final event = await terminal.future.timeout(
          const Duration(seconds: 10),
        );
        expect(event.sessionId, session.sessionId);
        expect(event.generation, session.generation);
        expect(event.sequence, greaterThan(session.sequence));
        final snapshots = await api.sessionSnapshots();
        expect(snapshots.single.state, SessionState.failed);
        expect(snapshots.single.error, contains('SDK'));
        await api.stopSession(sessionId: session.sessionId);
        await api.cancelEventSubscription();
      } finally {
        await subscription?.cancel();
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

Future<SessionSnapshot> waitForTerminal(String id) async {
  return Future<SessionSnapshot>(() async {
    while (true) {
      final snapshot = (await api.sessionSnapshots()).firstWhere(
        (value) => value.sessionId == id,
      );
      if (snapshot.state == SessionState.failed ||
          snapshot.state == SessionState.ended) {
        return snapshot;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }).timeout(const Duration(seconds: 10));
}

Future<build.BuildSnapshot> waitForBuildTerminal(String id) async {
  return Future<build.BuildSnapshot>(() async {
    while (true) {
      final snapshot = await api.buildSnapshot(buildId: id);
      if (const ['succeeded', 'failed', 'cancelled'].contains(snapshot.state)) {
        return snapshot;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }).timeout(const Duration(seconds: 10));
}
