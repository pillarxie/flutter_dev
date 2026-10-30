import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';
import 'package:flutter_dev/core/presentation/workbench_select.dart';

import 'workbench_test.dart'
    show FakeBridge, addProject, expandAdvancedSettings, key, mount;

ProjectGitInfo info(String branch, {String root = '/repo'}) => ProjectGitInfo(
  repositoryRoot: root,
  currentBranch: branch,
  headCommit: '0123456789abcdef',
  branches: ['main', 'feature/a-long-branch-name'],
);

FakeBridge restored({
  List<Project> projects = const [Project(name: 'Sample', path: '/repo/app')],
}) => FakeBridge()
  ..appSettings = AppSettings(
    projects: projects,
    selectedProjectPath: projects.first.path,
  );

Future<void> chooseBranch(
  WidgetTester tester,
  String path,
  String branch,
) async {
  await tester.ensureVisible(key('git-branch-select-$path'));
  await tester.tap(key('git-branch-select-$path'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(MenuItemButton, branch));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

void main() {
  testWidgets('Git detection keeps refresh disabled in the header', (
    tester,
  ) async {
    final detected = Completer<ProjectGitInfo?>();
    final bridge = restored()..gitResponse = (_) => detected.future;
    await mount(tester, bridge);
    expect(
      find.descendant(
        of: key('workspace-header'),
        matching: key('git-refresh-/repo/app'),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<IconButton>(key('git-refresh-/repo/app')).onPressed,
      isNull,
    );
    detected.complete(info('main'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(key('git-refresh-/repo/app')).onPressed,
      isNotNull,
    );
  });

  testWidgets('older sibling refresh does not cancel a newer refresh', (
    tester,
  ) async {
    final bridge = restored(
      projects: const [
        Project(name: 'A', path: '/repo/a'),
        Project(name: 'B', path: '/repo/b'),
      ],
    )..gitResponse = (_) async => info('main');
    await mount(tester, bridge);
    await tester.pumpAndSettle();
    final older = Completer<ProjectGitInfo?>();
    final newer = Completer<ProjectGitInfo?>();
    bridge.gitResponse = (path) =>
        path == '/repo/a' ? older.future : newer.future;
    await tester.tap(key('git-refresh-/repo/a'));
    await tester.pump();
    await tester.tap(key('project-/repo/b'));
    await tester.pump();
    older.complete(info('main'));
    await tester.pump();
    newer.complete(info('feature/a-long-branch-name'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(key('project-branch-/repo/a')).data,
      'feature/a-long-branch-name',
    );
    expect(
      tester.widget<Text>(key('project-branch-/repo/b')).data,
      'feature/a-long-branch-name',
    );
  });
  testWidgets(
    'manual refresh synchronizes sibling branches after external checkout',
    (tester) async {
      var branch = 'main';
      final bridge =
          restored(
              projects: const [
                Project(name: 'A', path: '/repo/a'),
                Project(name: 'B', path: '/repo/b'),
              ],
            )
            ..gitResponse = (_) async {
              return info(branch);
            }
            ..branchResponse = (_, target) async => info(target);
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      branch = 'feature/a-long-branch-name';
      await tester.tap(key('git-refresh-/repo/a'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(key('project-branch-/repo/b')).data, branch);
      await tester.tap(key('project-/repo/b'));
      await tester.pumpAndSettle();
      await chooseBranch(tester, '/repo/b', 'main');
      await tester.pumpAndSettle();
      expect(bridge.branchRequests.single.branch, 'main');
      expect(tester.widget<Text>(key('project-branch-/repo/a')).data, 'main');
    },
  );
  testWidgets(
    'restored and imported projects detect Git; non-Git hides branch controls',
    (tester) async {
      final bridge = restored()
        ..gitResponse = (path) async =>
            path.startsWith('/repo') ? info('main') : null;
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      expect(key('project-branch-/repo/app'), findsOneWidget);
      expect(tester.widget<Text>(key('project-branch-/repo/app')).data, 'main');
      await addProject(tester, '/plain');
      expect(bridge.gitRequests, containsAll(['/repo/app', '/plain']));
      expect(
        bridge.gitRequests.where((path) => path == '/plain'),
        hasLength(1),
      );
      expect(key('git-branch-select-/plain'), findsNothing);
      expect(find.text('Git 分支'), findsNothing);
    },
  );

  testWidgets('importing a selected project shares its pending Git read', (
    tester,
  ) async {
    final pending = Completer<ProjectGitInfo?>();
    final bridge = FakeBridge()..gitResponse = (_) => pending.future;
    await mount(tester, bridge);
    await tester.tap(key('add-project'));
    await tester.pumpAndSettle();
    await tester.enterText(key('add-project-path'), '/repo/imported');
    await tester.tap(key('add-project-discover'));
    await tester.pumpAndSettle();
    await tester.tap(key('add-project-confirm'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(bridge.gitRequests, ['/repo/imported']);
    pending.complete(info('main'));
    await tester.pumpAndSettle();
    expect(bridge.gitRequests, ['/repo/imported']);
    expect(
      tester.widget<Text>(key('project-branch-/repo/imported')).data,
      'main',
    );
  });

  testWidgets(
    'switch updates sibling projects and re-resolves SDK without stealing selection',
    (tester) async {
      final switched = Completer<ProjectGitInfo>();
      final bridge =
          restored(
              projects: const [
                Project(name: 'A', path: '/repo/a'),
                Project(name: 'B', path: '/repo/b'),
              ],
            )
            ..gitResponse = (_) async {
              return info('main');
            }
            ..branchResponse = (_, _) => switched.future;
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await chooseBranch(tester, '/repo/a', 'feature/a-long-branch-name');
      expect(bridge.branchRequests.single.branch, 'feature/a-long-branch-name');
      expect(
        tester
            .widget<WorkbenchSelect<String>>(key('git-branch-select-/repo/a'))
            .onChanged,
        isNull,
      );
      await tester.tap(key('project-/repo/b'));
      await tester.pump();
      switched.complete(info('feature/a-long-branch-name'));
      await tester.pumpAndSettle();
      for (final path in ['/repo/a', '/repo/b']) {
        expect(
          tester.widget<Text>(key('project-branch-$path')).data,
          'feature/a-long-branch-name',
        );
      }
      expect(key('git-branch-select-/repo/b'), findsOneWidget);
      expect(bridge.sdkRequests.last.projectPath, '/repo/b');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed read retries and failed switch preserves known branch', (
    tester,
  ) async {
    var failRead = true;
    final bridge = restored()
      ..gitResponse = (_) async {
        if (failRead) throw StateError('git unavailable');
        return info('main');
      }
      ..branchResponse = (_, _) async =>
          throw StateError('local changes would be overwritten');
    await mount(tester, bridge);
    await tester.pumpAndSettle();
    expect(find.textContaining('读取 Git 分支失败'), findsOneWidget);
    expect(
      find.descendant(
        of: key('project-config'),
        matching: key('git-error-/repo/app'),
      ),
      findsOneWidget,
    );
    failRead = false;
    await tester.tap(key('git-refresh-/repo/app'));
    await tester.pumpAndSettle();
    await chooseBranch(tester, '/repo/app', 'feature/a-long-branch-name');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('local changes would be overwritten'),
      findsOneWidget,
    );
    expect(tester.widget<Text>(key('project-branch-/repo/app')).data, 'main');
    expect(
      tester
          .widget<WorkbenchSelect<String>>(key('git-branch-select-/repo/app'))
          .onChanged,
      isNotNull,
    );
    bridge.gitResponse = (_) async => throw StateError('read failed');
    await tester.tap(key('git-refresh-/repo/app'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(key('project-branch-/repo/app')).data, 'main');
  });

  testWidgets(
    'late project detection stays with its project and disposal ignores results',
    (tester) async {
      final first = Completer<ProjectGitInfo?>();
      final second = Completer<ProjectGitInfo?>();
      final bridge = restored(
        projects: const [
          Project(name: 'A', path: '/a'),
          Project(name: 'B', path: '/b'),
        ],
      )..gitResponse = (path) => path == '/a' ? first.future : second.future;
      await mount(tester, bridge);
      await tester.pump();
      await tester.tap(key('project-/b'));
      await tester.pump();
      first.complete(info('main', root: '/a'));
      await tester.pump();
      expect(key('git-branch-select-/a'), findsNothing);
      expect(key('project-branch-/a'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      second.complete(info('main', root: '/b'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pre-switch sibling read cannot restore old branch', (
    tester,
  ) async {
    final late = Completer<ProjectGitInfo?>();
    var reads = 0;
    final bridge =
        restored(
            projects: const [
              Project(name: 'A', path: '/repo/a'),
              Project(name: 'B', path: '/repo/b'),
            ],
          )
          ..gitResponse = (path) async {
            if (path == '/repo/b' && reads++ == 0) return late.future;
            return info(
              path == '/repo/b' ? 'feature/a-long-branch-name' : 'main',
            );
          }
          ..branchResponse = (_, _) async => info('feature/a-long-branch-name');
    await mount(tester, bridge);
    await tester.pump();
    await chooseBranch(tester, '/repo/a', 'feature/a-long-branch-name');
    await tester.pumpAndSettle();
    late.complete(info('main'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(key('project-branch-/repo/b')).data,
      'feature/a-long-branch-name',
    );
  });

  testWidgets('detached HEAD and unborn branches have informative labels', (
    tester,
  ) async {
    final bridge = restored()
      ..gitResponse = (_) async => const ProjectGitInfo(
        repositoryRoot: '/repo',
        headCommit: '1234567890',
        branches: ['main'],
      );
    await mount(tester, bridge);
    await tester.pumpAndSettle();
    expect(find.text('游离 HEAD · 1234567'), findsWidgets);
    bridge.gitResponse = (_) async =>
        const ProjectGitInfo(repositoryRoot: '/repo', currentBranch: 'main');
    await tester.tap(key('git-refresh-/repo/app'));
    await tester.pumpAndSettle();
    expect(find.textContaining('仓库尚无提交'), findsOneWidget);
    expect(
      tester
          .widget<WorkbenchSelect<String>>(key('git-branch-select-/repo/app'))
          .options,
      isEmpty,
    );
  });

  for (final mode in ['light', 'dark']) {
    for (final width in [1400.0, 560.0]) {
      testWidgets('$mode Git menu at ${width.toInt()}px remains usable', (
        tester,
      ) async {
        final longBranch =
            'feature/${List.filled(12, 'long-branch-name').join('-')}';
        ProjectGitInfo branchInfo(String branch) => ProjectGitInfo(
          repositoryRoot: '/repo',
          currentBranch: branch,
          headCommit: '0123456789abcdef',
          branches: ['main', longBranch],
        );
        final bridge = restored()
          ..appSettings = AppSettings(
            themeMode: mode,
            projects: const [
              Project(name: 'Sample Project', path: '/repo/app'),
            ],
          )
          ..gitResponse = (_) async {
            return branchInfo(longBranch);
          }
          ..branchResponse = (_, branch) async => branchInfo(branch);
        await mount(
          tester,
          bridge,
          size: Size(width, width == 560 ? 500 : 800),
        );
        await tester.pumpAndSettle();
        final branchSelect = key('git-branch-select-/repo/app');
        final refresh = key('git-refresh-/repo/app');
        expect(branchSelect, findsOneWidget);
        expect(
          tester.widget<WorkbenchSelect<String>>(branchSelect).compact,
          isTrue,
        );
        for (final control in [branchSelect, refresh]) {
          expect(
            find.descendant(of: key('workspace-header'), matching: control),
            findsOneWidget,
          );
          expect(
            find.descendant(of: key('project-config'), matching: control),
            findsNothing,
          );
          expect(control.hitTestable(), findsOneWidget);
        }
        expect(find.text('启动配置'), findsNothing);
        expect(find.text('Git 分支'), findsNothing);
        expect(find.text('切换当前工作目录的本地分支。'), findsNothing);
        expect(find.text('当前分支'), findsNothing);
        expect(
          tester.getRect(branchSelect).top,
          greaterThanOrEqualTo(tester.getRect(key('workspace-title')).bottom),
        );
        expect(tester.takeException(), isNull);

        await tester.tap(branchSelect);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(MenuItemButton, longBranch), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.widgetWithText(MenuItemButton, 'main'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(key('project-branch-/repo/app')).data,
          'main',
        );
        final reads = bridge.gitRequests.length;
        await tester.tap(refresh);
        await tester.pumpAndSettle();
        expect(bridge.gitRequests.length, reads + 1);
        expect(
          tester.widget<Text>(key('project-branch-/repo/app')).data,
          longBranch,
        );

        final branchRect = tester.getRect(branchSelect);
        final refreshRect = tester.getRect(refresh);
        await expandAdvancedSettings(tester);
        await tester.ensureVisible(key('tool-args'));
        await tester.pumpAndSettle();
        expect(tester.getRect(branchSelect), branchRect);
        expect(tester.getRect(refresh), refreshRect);
        expect(branchSelect.hitTestable(), findsOneWidget);
        expect(refresh.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
