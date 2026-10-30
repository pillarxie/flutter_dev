import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/bridge/generated/api/core.dart' as api;
import 'package:flutter_dev/core/bridge/generated/frb_generated.dart';
import 'package:flutter_dev/core/bridge/generated/session.dart' show EnvVar;
import 'package:flutter_dev/core/bridge/generated/test_runner.dart';
import 'package:flutter_dev/core/bridge/generated/workspace.dart';

void main() {
  const library = String.fromEnvironment('FLUTTER_DEV_NATIVE_LIBRARY');
  const sdk = String.fromEnvironment('FLUTTER_DEV_SMOKE_SDK');
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real FFI persists profiles, opens a source location and runs Flutter tests with exact failure retry',
    () async {
      expect(Platform.environment['FLUTTER_DEV_SETTINGS_PATH'], isNotEmpty);
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      final directory = await Directory.systemTemp.createTemp(
        'flutter-dev-productivity-',
      );
      final root = await directory.resolveSymbolicLinks();
      try {
        await File('$root/pubspec.yaml').writeAsString(
          'name: productivity_sample\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\ndependencies:\n  flutter:\n    sdk: flutter\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n',
        );
        await Directory('$root/lib').create();
        await Directory('$root/test').create();
        final source = File('$root/lib/100%😀.dart');
        await source.writeAsString('// 😀\nvoid main() {}\n');
        final fixture = File('$root/test/smoke_test.dart');
        const testCode = '''import 'package:flutter_test/flutter_test.dart';
void main() {
  test('通过', () => expect(1, 1));
  test('失败后重跑 [精确]', () => expect(2, 3));
}
''';
        await fixture.writeAsString(testCode);
        final pub = await Process.run('$sdk/bin/flutter', [
          'pub',
          'get',
        ], workingDirectory: root);
        expect(pub.exitCode, 0, reason: '${pub.stdout}\n${pub.stderr}');

        final argumentsFile = File('$root/editor-arguments.txt');
        final editor = File('$root/editor');
        await editor.writeAsString(
          '#!/bin/sh\nprintf \'%s\\n\' "\$@" > "${argumentsFile.path}"\n',
        );
        expect((await Process.run('chmod', ['755', editor.path])).exitCode, 0);
        final profile = RunProfile(
          id: 'dev',
          name: '开发环境',
          projectPath: root,
          sdkPath: sdk,
          deviceId: 'macos',
          entrypoint: 'lib/main.dart',
          mode: 'debug',
          dartDefines: ['环境=测试'],
          environment: const [EnvVar(name: 'MESSAGE', value: '中文 value')],
          environmentText: 'MESSAGE=中文 value',
          toolArgsText: '["--verbose"]',
          toolArgs: ['--verbose'],
          noDebug: false,
        );
        final preferences = WorkspacePreferences(
          runProfiles: [profile],
          projectStates: [
            ProjectRunState(
              projectPath: root,
              draft: profile,
              lastRun: profile,
              selectedProfileId: 'dev',
              autoReload: true,
            ),
          ],
          editorExecutable: editor.path,
          editorArguments: [
            '--goto',
            '{file}:{line}:{column}',
            r'literal $(touch never)',
          ],
        );
        final saved = await api.setWorkspacePreferences(
          preferences: preferences,
        );
        expect(saved.workspacePreferences.runProfiles.single.name, '开发环境');
        await api.setThemeMode(mode: 'dark');
        final restored = (await api.getAppSettings()).workspacePreferences;
        expect(restored.projectStates.single.autoReload, isTrue);
        expect(
          restored.runProfiles.single.environment.single.value,
          '中文 value',
        );
        expect(restored.runProfiles.single.toolArgsText, '["--verbose"]');
        await api.openSourceLocation(
          projectPath: root,
          path: source.path,
          line: 1,
          column: 6,
        );
        final editorDeadline = DateTime.now().add(const Duration(seconds: 5));
        while (!await argumentsFile.exists() &&
            DateTime.now().isBefore(editorDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(await argumentsFile.readAsLines(), [
          '--goto',
          '${source.path}:1:6',
          r'literal $(touch never)',
        ]);
        expect(await api.discoverTestFiles(projectPath: root), [
          'test/smoke_test.dart',
        ]);

        Future<TestRunSnapshot> finish(TestRunSnapshot snapshot) async {
          final deadline = DateTime.now().add(const Duration(seconds: 90));
          while (['starting', 'running', 'stopping'].contains(snapshot.state) &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            snapshot = await api.testRunSnapshot(runId: snapshot.id);
          }
          expect(
            ['starting', 'running', 'stopping'],
            isNot(contains(snapshot.state)),
            reason: 'Test runner timed out',
          );
          return snapshot;
        }

        final failed = await finish(
          await api.startTestRun(
            config: TestRunConfig(
              projectPath: root,
              sdkPath: sdk,
              selections: const [],
            ),
          ),
        );
        expect(failed.state, 'failed');
        expect(failed.failed, 1);
        final failedTest = failed.tests.singleWhere(
          (t) => t.status == 'failed',
        );
        expect(failedTest.name, '失败后重跑 [精确]');
        expect(failedTest.error, isNotEmpty);
        final logs = await api.readTestLogs(
          runId: failed.id,
          afterId: 0,
          limit: 200,
        );
        expect(logs.entries, isNotEmpty);
        await fixture.writeAsString(
          testCode.replaceFirst('expect(2, 3)', 'expect(2, 2)'),
        );
        final retry = await finish(
          await api.startTestRun(
            config: TestRunConfig(
              projectPath: root,
              sdkPath: sdk,
              selections: [
                TestSelection(
                  path: 'test/smoke_test.dart',
                  name: failedTest.name,
                ),
              ],
            ),
          ),
        );
        expect(retry.state, 'succeeded');
        expect(retry.failed, 0);
        expect(
          retry.tests.where((t) => t.name == '失败后重跑 [精确]').single.status,
          'passed',
        );
        expect(retry.tests.where((t) => t.name == '通过'), isEmpty);
        final retained = await api.listTestRuns();
        expect(retained.map((r) => r.id), containsAll([failed.id, retry.id]));
        expect(
          jsonDecode(
            await File(
              Platform.environment['FLUTTER_DEV_SETTINGS_PATH']!,
            ).readAsString(),
          ),
          isA<Map>(),
        );
      } finally {
        await api.shutdownCore();
        RustLib.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: library.isEmpty || sdk.isEmpty || !Platform.isMacOS
        ? 'Requires rebuilt native library, isolated settings and FLUTTER_DEV_SMOKE_SDK on macOS.'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
