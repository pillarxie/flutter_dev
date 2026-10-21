import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/bridge/generated/api/core.dart' as api;
import 'package:flutter_dev/core/bridge/generated/frb_generated.dart';

void main() {
  const library = String.fromEnvironment('FLUTTER_DEV_NATIVE_LIBRARY');
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'actual Git FFI detects repositories and switches Unicode local branches',
    () async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(library));
      final directory = await Directory.systemTemp.createTemp(
        'flutter-dev-git-ffi-',
      );
      Future<void> git(List<String> args) async {
        final result = await Process.run(
          'git',
          ['-c', 'core.hooksPath=', ...args],
          workingDirectory: directory.path,
          environment: {
            'GIT_CONFIG_NOSYSTEM': '1',
            'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
          },
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      try {
        expect(await api.projectGitInfo(projectPath: directory.path), isNull);
        await git(['init', '--initial-branch=main']);
        final unborn = await api.projectGitInfo(projectPath: directory.path);
        expect(unborn!.currentBranch, 'main');
        expect(unborn.headCommit, isNull);
        final source = File('${directory.path}/sample.txt');
        await source.writeAsString('main content\n');
        await git(['add', '--', 'sample.txt']);
        await git([
          '-c',
          'user.name=Git Test',
          '-c',
          'user.email=git-test@example.invalid',
          '-c',
          'commit.gpgSign=false',
          'commit',
          '-m',
          'fixture',
        ]);
        await git(['branch', 'feature/中文']);
        final nested = await Directory(
          '${directory.path}/apps/sample',
        ).create(recursive: true);
        final initial = await api.projectGitInfo(projectPath: nested.path);
        expect(initial!.repositoryRoot, await directory.resolveSymbolicLinks());
        expect(initial.branches, containsAll(['main', 'feature/中文']));
        expect(initial.headCommit, isNotEmpty);

        final switched = await api.switchProjectBranch(
          projectPath: nested.path,
          branch: 'feature/中文',
        );
        expect(switched.currentBranch, 'feature/中文');
        expect(
          (await api.projectGitInfo(
            projectPath: directory.path,
          ))!.currentBranch,
          'feature/中文',
        );
        await expectLater(
          api.switchProjectBranch(
            projectPath: directory.path,
            branch: '--discard-changes',
          ),
          throwsA(anything),
        );
        expect(await source.readAsString(), 'main content\n');
      } finally {
        RustLib.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: library.isEmpty
        ? 'Run with FLUTTER_DEV_NATIVE_LIBRARY pointing at the rebuilt core.'
        : false,
  );
}
