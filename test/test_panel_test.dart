import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';
import 'package:flutter_dev/core/presentation/workbench_theme.dart';
import 'package:flutter_dev/features/testing/test_panel.dart';

const _project = Project(name: 'app', path: '/app');
const _failure = TestResult(
  id: 'failure',
  path: '/app/test/foo_test.dart',
  name: 'group exact [a+b]',
  status: 'failed',
  error: 'Expected true, got false',
  stackTrace: '#0 test/foo_test.dart:3:2',
);

class _TestBridge extends WorkbenchBridge {
  final controller = StreamController<WorkbenchEvent>.broadcast(sync: true);
  @override
  Stream<WorkbenchEvent> get events => controller.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  List<String> files = ['test/foo_test.dart', 'test/sub/bar_test.dart'];
  List<TestRunSnapshot> runs = [];
  TestRunSnapshot next = const TestRunSnapshot(
    id: 'run',
    projectPath: '/app',
    state: 'succeeded',
  );
  final configs = <TestRunConfig>[];
  final stops = <String>[];
  final reads = <int>[];
  List<LogEntry> output = [];
  Future<List<String>> Function(String)? discover;
  bool failStart = false, failNextRead = false;
  Future<TestRunSnapshot> Function(String)? snapshotResponse;
  @override
  Future<List<String>> discoverTestFiles(String projectPath) async =>
      discover == null ? files : discover!(projectPath);
  @override
  Future<List<TestRunSnapshot>> listTestRuns() async => runs;
  @override
  Future<TestRunSnapshot> startTestRun(TestRunConfig config) async {
    configs.add(config);
    if (failStart) throw StateError('bad sdk');
    runs = [next];
    return next;
  }

  @override
  Future<TestRunSnapshot> testRunSnapshot(String id) async =>
      snapshotResponse == null ? next : snapshotResponse!(id);
  @override
  Future<LogPage> readTestLogs(
    String id, {
    int afterId = 0,
    int limit = 200,
  }) async {
    reads.add(afterId);
    if (failNextRead) {
      failNextRead = false;
      throw StateError('temporary read failure');
    }
    final page = output
        .where((entry) => entry.id > afterId)
        .take(limit)
        .toList();
    return LogPage(entries: page, nextAfterId: page.lastOrNull?.id ?? afterId);
  }

  @override
  Future<void> stopTestRun(String id) async {
    stops.add(id);
    next = TestRunSnapshot(
      id: id,
      projectPath: next.projectPath,
      state: 'cancelled',
      tests: next.tests,
    );
    runs = [next];
  }
}

Future<void> _mount(
  WidgetTester tester,
  _TestBridge bridge, {
  Project project = _project,
  Brightness brightness = Brightness.light,
  Size size = const Size(800, 700),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: workbenchTheme(brightness),
      home: Scaffold(
        body: TestPanel(
          bridge: bridge,
          project: project,
          sdkPreference: '/sdk',
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'file tree runs actual file and individual machine-discovered test',
    (tester) async {
      final bridge = _TestBridge()
        ..next = const TestRunSnapshot(
          id: 'run',
          projectPath: '/app',
          state: 'failed',
          tests: [_failure],
          failed: 1,
          exitCode: 1,
        );
      addTearDown(bridge.controller.close);
      await _mount(tester, bridge);
      expect(find.text('foo_test.dart'), findsOneWidget);
      expect(find.text('sub'), findsOneWidget);
      expect(find.text('group exact [a+b]'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('test-file-run-test/foo_test.dart')),
      );
      await tester.pumpAndSettle();
      expect(bridge.configs.single.projectPath, '/app');
      expect(bridge.configs.single.sdkPath, '/sdk');
      expect(
        bridge.configs.single.selections.single.path,
        'test/foo_test.dart',
      );
      await tester.tap(find.text('foo_test.dart'));
      await tester.pumpAndSettle();
      expect(find.text('group exact [a+b]'), findsOneWidget);
      await tester.tap(find.byTooltip('运行此测试'));
      await tester.pumpAndSettle();
      expect(bridge.configs.last.selections.single.name, 'group exact [a+b]');
      expect(bridge.configs.last.selections.single.path, 'test/foo_test.dart');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reruns failures by exact path and name and displays failure details',
    (tester) async {
      final bridge = _TestBridge()
        ..next = const TestRunSnapshot(
          id: 'run',
          projectPath: '/app',
          state: 'failed',
          tests: [_failure],
          failed: 1,
        );
      bridge.runs = [bridge.next];
      addTearDown(bridge.controller.close);
      await _mount(tester, bridge);
      await tester.pumpAndSettle();
      await tester.tap(find.text('foo_test.dart'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('group exact [a+b]'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Expected true, got false'), findsOneWidget);
      await tester.tap(find.byKey(const Key('test-rerun-failed')));
      await tester.pumpAndSettle();
      expect(bridge.configs.single.selections.single.name, _failure.name);
      expect(
        bridge.configs.single.selections.single.path,
        'test/foo_test.dart',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'run all, close, reopen active run and cancel without tying run to panel lifetime',
    (tester) async {
      final bridge = _TestBridge()
        ..next = const TestRunSnapshot(
          id: 'active',
          projectPath: '/app',
          state: 'running',
        );
      addTearDown(bridge.controller.close);
      await _mount(tester, bridge);
      await tester.tap(find.byKey(const Key('test-run-all')));
      await tester.pump();
      expect(bridge.configs.single.selections, isEmpty);
      await tester.pumpWidget(const SizedBox());
      expect(bridge.stops, isEmpty);
      await _mount(tester, bridge);
      expect(find.byKey(const Key('test-stop')), findsOneWidget);
      await tester.tap(find.byKey(const Key('test-stop')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(bridge.stops, ['active']);
      expect(find.textContaining('已取消'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('empty discovery is truthful and start failure can be retried', (
    tester,
  ) async {
    final bridge = _TestBridge()..files = [];
    addTearDown(bridge.controller.close);
    await _mount(tester, bridge);
    expect(find.text('未发现测试文件'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('test-run-all')),
    );
    expect(button.onPressed, isNull);
    bridge.files = ['test/foo_test.dart'];
    await tester.tap(find.byKey(const Key('test-refresh')));
    await tester.pump();
    bridge.failStart = true;
    await tester.tap(find.byKey(const Key('test-run-all')));
    await tester.pump();
    expect(find.textContaining('启动测试失败'), findsOneWidget);
    bridge.failStart = false;
    await tester.tap(find.byKey(const Key('test-run-all')));
    await tester.pump();
    expect(find.textContaining('启动测试失败'), findsNothing);
    expect(bridge.configs, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'old discovery cannot replace a new project and disposal tolerates delayed work',
    (tester) async {
      final bridge = _TestBridge();
      addTearDown(bridge.controller.close);
      final delayed = Completer<List<String>>();
      bridge.discover = (path) => path == '/app'
          ? delayed.future
          : Future.value(['test/new_test.dart']);
      await _mount(tester, bridge);
      await _mount(
        tester,
        bridge,
        project: const Project(name: 'new', path: '/new'),
      );
      delayed.complete(['test/stale_test.dart']);
      await tester.pump();
      expect(find.text('new_test.dart'), findsOneWidget);
      expect(find.text('stale_test.dart'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('finished task drains more than one log page', (tester) async {
    final bridge = _TestBridge()
      ..output = [
        for (var i = 1; i <= 205; i++)
          LogEntry(id: i, category: 'stdout', text: 'output $i'),
      ];
    bridge.runs = [bridge.next];
    addTearDown(bridge.controller.close);
    await _mount(tester, bridge);
    await tester.pump(const Duration(milliseconds: 60));
    expect(bridge.reads, containsAll([0, 200]));
    expect(find.text('205 条输出'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'terminal snapshot waits for final output instead of pairing an old empty page',
    (tester) async {
      final bridge = _TestBridge()
        ..next = const TestRunSnapshot(
          id: 'late',
          projectPath: '/app',
          state: 'running',
        );
      bridge.runs = [bridge.next];
      final terminal = Completer<TestRunSnapshot>();
      bridge.snapshotResponse = (_) => terminal.future;
      addTearDown(bridge.controller.close);
      await _mount(tester, bridge);
      // The log buffer is initially empty. A concurrent read here would miss the
      // failure written while the snapshot request is still awaiting completion.
      bridge.output = const [
        LogEntry(id: 1, category: 'stderr', text: 'last compilation failure'),
      ];
      terminal.complete(
        const TestRunSnapshot(
          id: 'late',
          projectPath: '/app',
          state: 'failed',
          exitCode: 1,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('1 条输出'), findsOneWidget);
      await tester.tap(find.byKey(const Key('test-output')));
      await tester.pumpAndSettle();
      expect(find.text('last compilation failure'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'terminal log read failure retries without advancing the output cursor',
    (tester) async {
      final bridge = _TestBridge()
        ..failNextRead = true
        ..output = const [
          LogEntry(id: 1, category: 'stderr', text: 'failure after retry'),
        ];
      bridge.runs = [bridge.next];
      addTearDown(bridge.controller.close);
      await _mount(tester, bridge);
      await tester.pump();
      expect(find.textContaining('刷新测试状态失败'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump();
      expect(bridge.reads, [0, 0]);
      expect(find.textContaining('刷新测试状态失败'), findsNothing);
      expect(find.text('1 条输出'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('machine file URIs are converted to relative selections', (
    tester,
  ) async {
    final bridge = _TestBridge()
      ..next = const TestRunSnapshot(
        id: 'uri',
        projectPath: '/app',
        state: 'failed',
        failed: 1,
        tests: [
          TestResult(
            id: 'uri-test',
            path: 'file:///app/test/a%20b_test.dart',
            name: 'uri exact',
            status: 'failed',
          ),
        ],
      );
    bridge.runs = [bridge.next];
    addTearDown(bridge.controller.close);
    await _mount(tester, bridge);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('test-rerun-failed')));
    await tester.pumpAndSettle();
    expect(bridge.configs.single.selections.single.path, 'test/a b_test.dart');
    expect(bridge.configs.single.selections.single.name, 'uri exact');
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    testWidgets('test panel fits 340px ${brightness.name}', (tester) async {
      final bridge = _TestBridge();
      addTearDown(bridge.controller.close);
      await _mount(
        tester,
        bridge,
        brightness: brightness,
        size: const Size(340, 620),
      );
      expect(find.text('foo_test.dart'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
