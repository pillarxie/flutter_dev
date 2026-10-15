import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';

import 'workbench_test.dart'
    show
        FakeBridge,
        addProject,
        key,
        mount,
        selectProject,
        expandAdvancedSettings;

const first = Project(
  name: 'First',
  path: '/first',
  entrypoint: 'lib/first.dart',
  platforms: ['macos', 'web'],
);
const second = Project(
  name: 'Second',
  path: '/second',
  entrypoint: 'lib/second.dart',
  platforms: ['ios'],
);
const preset = BuildPreset(id: 'bundle', name: 'Bundle', target: 'bundle');

Future<void> _importDuringLoad(WidgetTester tester, String path) async {
  await tester.tap(key('add-project'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.enterText(key('add-project-path'), path);
  await tester.tap(key('add-project-discover'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(key('add-project-confirm'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets(
    'saved project metadata and selection restore without discovery or auto-run',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = const AppSettings(
          projects: [first, second],
          selectedProjectPath: '/second',
        );
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      expect(key('project-/first'), findsOneWidget);
      expect(key('project-/second'), findsOneWidget);
      expect(bridge.sdkRequests.single.projectPath, '/second');
      await expandAdvancedSettings(tester);
      expect(
        tester.widget<TextField>(key('entrypoint')).controller!.text,
        'lib/second.dart',
      );
      expect(bridge.starts, 0);
      expect(bridge.discoveredRoots, isEmpty);
      expect(bridge.workspaceSaves, isEmpty);
    },
  );

  testWidgets(
    'imports and selection survive recreating the app and preserve other settings',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = const AppSettings(
          defaultSdkPath: '/sdk',
          themeMode: 'dark',
          buildPresets: [preset],
        )
        ..discoverResponse = (path) => [path == '/first' ? first : second];
      await mount(tester, bridge);
      await addProject(tester, '/first');
      await addProject(tester, '/second');
      await addProject(tester, '/first');
      await selectProject(tester, '/second');
      expect(bridge.appSettings.projects.map((p) => p.path), [
        '/first',
        '/second',
      ]);
      expect(bridge.appSettings.selectedProjectPath, '/second');
      expect(bridge.appSettings.defaultSdkPath, '/sdk');
      expect(bridge.appSettings.themeMode, 'dark');
      expect(bridge.appSettings.buildPresets.single.id, 'bundle');
      await tester.pumpWidget(const SizedBox());
      final restarted = FakeBridge()..appSettings = bridge.appSettings;
      await mount(tester, restarted);
      await tester.pumpAndSettle();
      expect(key('project-/first'), findsOneWidget);
      expect(key('project-/second'), findsOneWidget);
      expect(restarted.sdkRequests.single.projectPath, '/second');
      await expandAdvancedSettings(tester);
      expect(
        tester.widget<TextField>(key('entrypoint')).controller!.text,
        'lib/second.dart',
      );
      expect(restarted.starts, 0);
    },
  );

  testWidgets(
    'late settings merge existing projects with new imports without stealing selection',
    (tester) async {
      final load = Completer<AppSettings>();
      final bridge = FakeBridge()..initialSettings = load.future;
      await mount(tester, bridge);
      await _importDuringLoad(tester, '/new');
      expect(bridge.workspaceSaves, isEmpty);
      bridge.initialSettings = null;
      bridge.appSettings = const AppSettings(
        projects: [first],
        selectedProjectPath: '/first',
      );
      load.complete(bridge.appSettings);
      await tester.pumpAndSettle();
      expect(key('project-/first'), findsOneWidget);
      expect(key('project-/new'), findsOneWidget);
      expect(
        bridge.appSettings.projects.map((p) => p.path),
        unorderedEquals(['/first', '/new']),
      );
      expect(bridge.appSettings.selectedProjectPath, '/new');
      expect(bridge.sdkRequests.single.projectPath, '/new');
      expect(bridge.starts, 0);
    },
  );

  testWidgets(
    'failed load never overwrites disk projects and retry merges unsaved imports',
    (tester) async {
      final load = Completer<AppSettings>();
      final bridge = FakeBridge()
        ..appSettings = const AppSettings(
          projects: [first],
          selectedProjectPath: '/first',
        )
        ..initialSettings = load.future;
      await mount(tester, bridge);
      load.completeError(Exception('read denied'));
      await tester.pumpAndSettle();
      expect(key('workspace-persistence-error'), findsOneWidget);
      await addProject(tester, '/new');
      expect(bridge.workspaceSaves, isEmpty);
      expect(bridge.appSettings.projects.single.path, '/first');
      expect(key('project-/new'), findsOneWidget);
      expect(
        await tester.binding.handleRequestAppExit(),
        AppExitResponse.cancel,
      );
      expect(bridge.shutdowns, 0);
      expect(bridge.workspaceSaves, isEmpty);
      bridge.initialSettings = null;
      await tester.tap(key('workspace-projects-retry-load'));
      await tester.pumpAndSettle();
      expect(key('workspace-persistence-error'), findsNothing);
      expect(
        bridge.appSettings.projects.map((p) => p.path),
        unorderedEquals(['/first', '/new']),
      );
      expect(bridge.appSettings.selectedProjectPath, '/new');
    },
  );

  testWidgets(
    'failed save keeps imported projects visible and retries the current snapshot',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = const AppSettings(
          projects: [first],
          selectedProjectPath: '/first',
        )
        ..workspaceResponse = (_, _) async => throw Exception('disk full');
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      await addProject(tester, '/new');
      expect(key('project-/new'), findsOneWidget);
      expect(key('workspace-persistence-error'), findsOneWidget);
      expect(bridge.appSettings.projects.single.path, '/first');
      expect(
        await tester.binding.handleRequestAppExit(),
        AppExitResponse.cancel,
      );
      expect(bridge.shutdowns, 0);
      bridge.workspaceResponse = null;
      await tester.tap(key('workspace-projects-retry-save'));
      await tester.pumpAndSettle();
      expect(key('workspace-persistence-error'), findsNothing);
      expect(bridge.appSettings.projects.map((p) => p.path), [
        '/first',
        '/new',
      ]);
      expect(bridge.appSettings.selectedProjectPath, '/new');
    },
  );

  testWidgets(
    'rapid imports save immutable snapshots in order and exit flushes before shutdown',
    (tester) async {
      final save = Completer<AppSettings>();
      final bridge = FakeBridge();
      bridge.workspaceResponse = (projects, selected) async {
        if (bridge.workspaceSaves.length == 1) return save.future;
        return AppSettings(
          projects: List.of(projects),
          selectedProjectPath: selected,
        );
      };
      await mount(tester, bridge);
      await addProject(tester, '/first');
      await addProject(tester, '/second');
      expect(bridge.workspaceSaves, hasLength(1));
      expect(bridge.workspaceSaves.first.projects.map((p) => p.path), [
        '/first',
      ]);
      final exit = tester.binding.handleRequestAppExit();
      await tester.pump();
      expect(bridge.shutdowns, 0);
      save.complete(
        AppSettings(
          projects: bridge.workspaceSaves.first.projects,
          selectedProjectPath: '/first',
        ),
      );
      await tester.pumpAndSettle();
      expect(await exit, AppExitResponse.exit);
      expect(bridge.appSettings.projects.map((p) => p.path), [
        '/first',
        '/second',
      ]);
      expect(bridge.appSettings.selectedProjectPath, '/second');
      expect(bridge.shutdowns, 1);
    },
  );

  testWidgets(
    'missing selected directory is retained when SDK preparation fails',
    (tester) async {
      final bridge = FakeBridge()
        ..appSettings = const AppSettings(
          projects: [first],
          selectedProjectPath: '/first',
        )
        ..sdkResponse = (_, _) async => throw Exception('folder missing');
      await mount(tester, bridge);
      await tester.pumpAndSettle();
      expect(key('project-/first'), findsOneWidget);
      expect(find.textContaining('folder missing'), findsOneWidget);
      expect(bridge.appSettings.projects.single.path, '/first');
      expect(bridge.workspaceSaves, isEmpty);
      expect(bridge.starts, 0);
    },
  );
}
