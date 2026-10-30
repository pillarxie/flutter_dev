import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';

import 'workbench_test.dart'
    show FakeBridge, addProject, key, mount, running, selectProject;

void main() {
  for (final mode in ['light', 'dark']) {
    for (final width in [560.0, 1400.0]) {
      testWidgets(
        '$mode sidebar at $width starts collapsed and stays compact',
        (tester) async {
          const first = Project(name: 'First app', path: '/first');
          const second = Project(name: 'Second app', path: '/second');
          final bridge = FakeBridge()
            ..appSettings = AppSettings(
              themeMode: mode,
              projects: const [first, second],
              selectedProjectPath: first.path,
            )
            ..sessions = [
              running(id: 'first', projectPath: first.path),
              running(id: 'second', projectPath: second.path, state: 'failed'),
            ];
          bridge.gitResponse = (path) async => ProjectGitInfo(
            repositoryRoot: path,
            currentBranch: 'feature/compact-sidebar',
          );
          await mount(tester, bridge, size: Size(width, 800));
          await tester.pumpAndSettle();
          expect(find.text('历史会话'), findsNothing);
          expect(key('session-first'), findsNothing);
          expect(key('session-second'), findsNothing);

          await selectProject(tester, second.path);
          await selectProject(tester, first.path);
          final firstRow = tester.getRect(key('project-/first'));
          final secondRow = tester.getRect(key('project-/second'));
          expect(firstRow.height, lessThanOrEqualTo(56));
          expect(secondRow.top - firstRow.bottom, lessThanOrEqualTo(8));
          await tester.tap(key('expand-/first'));
          await tester.pumpAndSettle();
          expect(key('session-first'), findsOneWidget);
          expect(key('session-second'), findsNothing);
          expect(
            tester.getSize(key('session-first')).height,
            lessThanOrEqualTo(48),
          );
          await tester.tap(key('session-first'));
          await tester.pumpAndSettle();
          expect(key('session-workspace'), findsOneWidget);

          // Collapsing the list must not change the selected running session.
          await tester.tap(key('expand-/first'));
          await tester.pumpAndSettle();
          expect(key('session-first'), findsNothing);
          expect(key('session-workspace'), findsOneWidget);
          bridge.controller.add(
            WorkbenchEvent(
              kind: 'session',
              sessionId: 'second',
              generation: 1,
              sequence: 2,
              session: running(
                id: 'second',
                projectPath: second.path,
                sequence: 2,
                state: 'paused',
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(key('session-second'), findsNothing);
          expect(key('session-workspace'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('new projects start collapsed and retain manual expansion', (
    tester,
  ) async {
    final bridge = FakeBridge();
    await mount(tester, bridge);
    await addProject(tester, '/first');
    expect(find.text('暂无会话'), findsNothing);
    await tester.tap(key('expand-/first'));
    await tester.pumpAndSettle();
    expect(find.text('暂无会话'), findsOneWidget);
    await addProject(tester, '/second');
    expect(tester.widget<IconButton>(key('expand-/first')).tooltip, '收起会话');
    expect(tester.widget<IconButton>(key('expand-/second')).tooltip, '展开会话');
    await selectProject(tester, '/first');
    expect(tester.widget<IconButton>(key('expand-/first')).tooltip, '收起会话');
    expect(bridge.starts, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
