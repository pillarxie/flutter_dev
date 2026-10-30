import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';
import 'package:flutter_dev/core/presentation/workbench_theme.dart';
import 'package:flutter_dev/features/logs/log_panel.dart';

const _session = Session(
  id: 'one',
  generation: 1,
  state: 'running',
  projectPath: '/app',
  deviceId: 'macos',
  mode: 'debug',
);

class _LogBridge extends WorkbenchBridge {
  final controller = StreamController<WorkbenchEvent>.broadcast(sync: true);
  List<LogEntry> logs = [];
  @override
  Stream<WorkbenchEvent> get events => controller.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  final opened = <({String projectPath, String path, int line, int column})>[];
  bool failOpen = false;
  Future<LogPage> Function(String, int, int, String)? handler;
  @override
  Future<void> openSourceLocation(
    String projectPath,
    String path,
    int line,
    int column,
  ) async {
    opened.add((
      projectPath: projectPath,
      path: path,
      line: line,
      column: column,
    ));
    if (failOpen) throw StateError('editor unavailable');
  }

  @override
  Future<LogPage> readLogs(
    String id, {
    int afterId = 0,
    int limit = 200,
    String query = '',
  }) async => handler == null
      ? Future.value(
          LogPage(
            entries: logs
                .where(
                  (entry) => entry.id > afterId && entry.text.contains(query),
                )
                .take(limit)
                .toList(),
            nextAfterId:
                logs
                    .where(
                      (entry) =>
                          entry.id > afterId && entry.text.contains(query),
                    )
                    .take(limit)
                    .lastOrNull
                    ?.id ??
                afterId,
          ),
        )
      : handler!(id, afterId, limit, query);
}

Future<void> _mount(
  WidgetTester tester,
  _LogBridge bridge, {
  Session session = _session,
  Size size = const Size(800, 700),
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: workbenchTheme(brightness),
      home: Scaffold(
        body: LogPanel(bridge: bridge, session: session),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  test(
    'source locations accept Dart stack coordinates and reject network URLs',
    () {
      expect(
        logSourceLocations(
          '#0 foo (package:app/src/a.dart:12:4)\n#1 (file:///tmp/main.dart:3:9)\n#2 /tmp/x.dart:8\n#3 C:\\app\\lib\\a.dart:14:2',
        ),
        [
          (path: 'package:app/src/a.dart', line: 12, column: 4),
          (path: 'file:///tmp/main.dart', line: 3, column: 9),
          (path: '/tmp/x.dart', line: 8, column: null),
          (path: r'C:\app\lib\a.dart', line: 14, column: 2),
        ],
      );
      expect(
        logSourceLocations('https://example.test/lib/a.dart:3:2 request 12:34'),
        isEmpty,
      );
    },
  );

  test(
    'spaced absolute paths retain their complete roots and respect prose boundaries',
    () {
      expect(
        logSourceLocations(
          '#0 foo (/Users/iron/My Project/lib/main.dart:12:3)\n'
          r'#1 bar (C:\Users\My Project\lib\main.dart:21:4)'
          '\n'
          'at "/tmp/Other Project/main.dart:2:8"\n'
          '/Users/iron/My Project/lib/main.dart:5\n'
          'source lib/example.dart:9:2',
        ),
        [
          (path: '/Users/iron/My Project/lib/main.dart', line: 12, column: 3),
          (path: r'C:\Users\My Project\lib\main.dart', line: 21, column: 4),
          (path: '/tmp/Other Project/main.dart', line: 2, column: 8),
          (path: '/Users/iron/My Project/lib/main.dart', line: 5, column: null),
          (path: 'lib/example.dart', line: 9, column: 2),
        ],
      );
      expect(
        logSourceLocations('https://example.test/My Project/lib/main.dart:3:2'),
        isEmpty,
      );
      expect(
        logSourceLocations(
          'request /not_source.dart then /tmp/My Project/main.dart:6:2',
        ),
        [(path: '/tmp/My Project/main.dart', line: 6, column: 2)],
      );
      expect(
        logSourceLocations(
          'ordinary body: explanation 12:3 and no source coordinate',
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'spaced POSIX and Windows source buttons pass full paths to the editor',
    (tester) async {
      final bridge = _LogBridge()
        ..logs = const [
          LogEntry(
            id: 1,
            category: 'stderr',
            text: '#0 (/Users/iron/My Project/lib/main.dart:12:3)',
          ),
          LogEntry(
            id: 2,
            category: 'stderr',
            text: r'#1 (C:\Users\My Project\lib\main.dart:21:4)',
          ),
        ];
      addTearDown(bridge.controller.close);
      await _mount(tester, bridge);
      await tester.tap(
        find.byKey(
          const ValueKey(
            'log-source-1-/Users/iron/My Project/lib/main.dart:12',
          ),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(
          const ValueKey(r'log-source-2-C:\Users\My Project\lib\main.dart:21'),
        ),
      );
      await tester.pump();
      expect(bridge.opened, [
        (
          projectPath: '/app',
          path: '/Users/iron/My Project/lib/main.dart',
          line: 12,
          column: 3,
        ),
        (
          projectPath: '/app',
          path: r'C:\Users\My Project\lib\main.dart',
          line: 21,
          column: 4,
        ),
      ]);
      expect(find.byType(SelectableText), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'source button opens project location, retains selectable log and retries failure',
    (tester) async {
      final bridge = _LogBridge()
        ..logs = const [
          LogEntry(
            id: 1,
            category: 'stderr',
            text: '#0 build (package:app/main.dart:42:7)',
          ),
        ];
      addTearDown(bridge.controller.close);
      await _mount(tester, bridge);
      expect(find.byType(SelectableText), findsOneWidget);
      final source = find.byKey(
        const ValueKey('log-source-1-package:app/main.dart:42'),
      );
      bridge.failOpen = true;
      await tester.tap(source);
      await tester.pump();
      expect(find.textContaining('打开源码失败'), findsOneWidget);
      bridge.failOpen = false;
      await tester.tap(source);
      await tester.pump();
      expect(bridge.opened.last, (
        projectPath: '/app',
        path: 'package:app/main.dart',
        line: 42,
        column: 7,
      ));
      expect(find.textContaining('打开源码失败'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'error filter drains full non-error page and preserves next-page error',
    (tester) async {
      final bridge = _LogBridge();
      addTearDown(bridge.controller.close);
      bridge.handler = (id, afterId, limit, query) async {
        if (afterId == 0) {
          return LogPage(
            entries: [
              for (var i = 1; i <= 200; i++)
                LogEntry(id: i, category: 'stdout', text: 'normal $i'),
            ],
            nextAfterId: 200,
          );
        }
        return LogPage(
          entries: afterId == 200
              ? const [
                  LogEntry(id: 201, category: 'exception', text: 'bad thing'),
                ]
              : const [],
          nextAfterId: 201,
        );
      };
      await _mount(tester, bridge);
      await tester.tap(find.byKey(const Key('log-errors-filter')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('bad thing'), findsOneWidget);
      expect(find.text('normal 200'), findsNothing);
      expect(find.text('1 条日志'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'switching session id ignores an outstanding read with same generation',
    (tester) async {
      final bridge = _LogBridge();
      addTearDown(bridge.controller.close);
      final first = Completer<LogPage>();
      bridge.handler = (id, afterId, limit, query) => id == 'one'
          ? first.future
          : Future.value(
              const LogPage(
                entries: [
                  LogEntry(id: 2, category: 'stdout', text: 'new session'),
                ],
                nextAfterId: 2,
              ),
            );
      await _mount(tester, bridge);
      await _mount(
        tester,
        bridge,
        session: const Session(
          id: 'two',
          generation: 1,
          state: 'running',
          projectPath: '/app2',
          deviceId: 'macos',
          mode: 'debug',
        ),
      );
      first.complete(
        const LogPage(
          entries: [LogEntry(id: 1, category: 'stdout', text: 'old session')],
          nextAfterId: 1,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('old session'), findsNothing);
      expect(find.text('new session'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'log controls fit narrow ${brightness.name} view and expose pause state',
      (tester) async {
        final bridge = _LogBridge();
        addTearDown(bridge.controller.close);
        await _mount(
          tester,
          bridge,
          size: const Size(340, 620),
          brightness: brightness,
        );
        await tester.tap(find.byTooltip('暂停滚动（继续接收日志）'));
        await tester.pump();
        expect(find.text('已暂停滚动 · 继续接收日志'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
