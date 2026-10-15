import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';
import 'package:flutter_dev/core/presentation/workbench_select.dart';
import 'package:flutter_dev/core/presentation/workbench_theme.dart';

import 'workbench_test.dart' show FakeBridge, addProject, key, mount;

final _selector = find.byKey(const ValueKey('selector'));

Future<({ValueNotifier<String?> value, List<String?> submitted})> mountSelector(
  WidgetTester tester, {
  String? selected = 'a',
  required List<WorkbenchOption<String>> options,
}) async {
  final value = ValueNotifier<String?>(selected);
  final submitted = <String?>[];
  addTearDown(value.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: workbenchTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            child: ValueListenableBuilder<String?>(
              valueListenable: value,
              builder: (context, current, _) => WorkbenchSelect<String>(
                key: const ValueKey('selector'),
                label: '设备',
                value: current,
                options: options,
                onChanged: (next) {
                  submitted.add(next);
                  value.value = next;
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (value: value, submitted: submitted);
}

List<WorkbenchOption<String>> choices() => [
  WorkbenchOption(
    value: 'a',
    label: 'Mac',
    detail: 'macOS',
    icon: Icons.computer,
  ),
  WorkbenchOption(
    value: 'b',
    label: 'iPhone',
    detail: 'iOS',
    icon: Icons.phone_iphone,
  ),
];

void main() {
  testWidgets('menu marks the current selection and submits the chosen value', (
    tester,
  ) async {
    final state = await mountSelector(tester, options: choices());
    expect(find.text('Mac'), findsOneWidget);
    await tester.tap(_selector);
    await tester.pumpAndSettle();
    expect(find.text('Mac'), findsNWidgets(2));
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(tester.getSize(find.byType(Scrollable).last).height, lessThan(160));
    await tester.tap(find.text('iPhone'));
    await tester.pumpAndSettle();
    expect(state.submitted, ['b']);
    expect(state.value.value, 'b');
    expect(find.text('iPhone'), findsOneWidget);
    expect(find.text('Mac'), findsNothing);

    // A controlled field must also reflect changes from its owner.
    state.value.value = 'a';
    await tester.pumpAndSettle();
    expect(find.text('Mac'), findsOneWidget);
    expect(find.text('iPhone'), findsNothing);
    expect(state.submitted, ['b']);
  });

  testWidgets('disabled options and empty lists never submit a selection', (
    tester,
  ) async {
    final state = await mountSelector(
      tester,
      options: [
        WorkbenchOption(value: 'a', label: 'Mac'),
        WorkbenchOption(value: 'b', label: '不可用设备', enabled: false),
      ],
    );
    await tester.tap(_selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('不可用设备'));
    await tester.pumpAndSettle();
    expect(state.submitted, isEmpty);
    expect(state.value.value, 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    final empty = await mountSelector(tester, selected: null, options: []);
    expect(find.text('请选择'), findsOneWidget);
    await tester.tap(_selector);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(empty.submitted, isEmpty);
    expect(empty.value.value, isNull);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape and outside clicks dismiss without changing the value', (
    tester,
  ) async {
    final state = await mountSelector(tester, options: choices());
    await tester.tap(_selector);
    await tester.pumpAndSettle();
    expect(find.text('iPhone'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('iPhone'), findsNothing);

    await tester.tap(_selector);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('iPhone'), findsNothing);
    expect(state.value.value, 'a');
    expect(state.submitted, isEmpty);
  });

  testWidgets('Tab, Enter and arrow keys choose an enabled option', (
    tester,
  ) async {
    final state = await mountSelector(
      tester,
      options: [
        WorkbenchOption(value: 'a', label: 'Mac'),
        WorkbenchOption(value: 'blocked', label: '不可用设备', enabled: false),
        WorkbenchOption(value: 'b', label: 'iPhone'),
      ],
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('iPhone'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(state.submitted, ['b']);
    expect(state.value.value, 'b');
    expect(find.text('iPhone'), findsOneWidget);
    expect(find.text('不可用设备'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(state.submitted, ['b', 'a']);
    expect(state.value.value, 'a');
  });

  testWidgets('a long device menu scrolls to and selects its last option', (
    tester,
  ) async {
    final state = await mountSelector(
      tester,
      selected: 'device-1',
      options: List.generate(
        80,
        (index) => WorkbenchOption(
          value: 'device-${index + 1}',
          label: '设备 ${index + 1}',
        ),
      ),
    );
    await tester.tap(_selector);
    await tester.pumpAndSettle();
    final scrolling = find.byType(Scrollable).last;
    expect(tester.getSize(scrolling).height, lessThanOrEqualTo(320));
    await tester.scrollUntilVisible(
      find.text('设备 80'),
      200,
      scrollable: scrolling,
    );
    await tester.tap(find.text('设备 80'));
    await tester.pumpAndSettle();
    expect(state.submitted, ['device-80']);
    expect(find.text('设备 80'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['light', 'dark']) {
    testWidgets('$mode project selectors fit their anchored menus at 560px', (
      tester,
    ) async {
      final bridge = FakeBridge()
        ..appSettings = AppSettings(themeMode: mode)
        ..devices = List.generate(
          30,
          (index) => Device(
            id: 'mac-$index',
            name: 'Mac device $index',
            platform: 'darwin',
          ),
        )
        ..discoverResponse = (_) => const [
          Project(name: 'sample', path: '/sample', platforms: ['macos', 'ios']),
        ];
      await mount(tester, bridge, size: const Size(560, 800));
      await addProject(tester, '/sample');
      for (final field in ['platform-select', 'mode-select', 'device-select']) {
        await tester.ensureVisible(key(field));
        await tester.tap(key(field));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.check_rounded), findsOneWidget);
        expect(tester.takeException(), isNull);
        final scrolling = find.byType(Scrollable).last;
        final menuRect = tester.getRect(scrolling);
        if (field == 'device-select') {
          expect(
            menuRect.width,
            lessThanOrEqualTo(tester.getSize(key(field)).width),
          );
        }
        expect(menuRect.left, greaterThanOrEqualTo(0));
        expect(menuRect.right, lessThanOrEqualTo(560));
        expect(menuRect.top, greaterThanOrEqualTo(0));
        expect(menuRect.bottom, lessThanOrEqualTo(800));
        expect(menuRect.height, lessThanOrEqualTo(320));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(bridge.starts, 0);
      expect(bridge.sdkRequests.length, 1);
    });
  }
}
