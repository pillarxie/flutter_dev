import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dev/core/presentation/workbench_models.dart';
import 'package:flutter_dev/features/devtools/network_panel.dart';

import 'network_panel_test.dart' show NetworkFake;
import 'workbench_test.dart' show addProject, key, mount;

void main() {
  testWidgets(
    'DevTools opens decoded network parameters inside a narrow workbench',
    (tester) async {
      final bridge = NetworkFake();
      bridge.startResponse = () async => const Session(
        id: 'network-session',
        generation: 1,
        state: 'running',
        projectPath: '/sample',
        deviceId: 'macos',
        mode: 'debug',
        serviceUri: 'http://localhost:123/token/',
        capabilities: {'debugger': true},
      );
      await mount(tester, bridge, size: const Size(560, 960));
      await addProject(tester, '/sample');
      await tester.tap(key('run-project'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DevTools'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(NetworkPanel), findsOneWidget);
      expect(
        bridge.calls.every((call) => call.session == 'network-session'),
        isTrue,
      );
      await tester.tap(find.byType(ListTile).first);
      await tester.pump();
      await tester.pump();
      expect(find.text('返回请求列表'), findsOneWidget);
      expect(find.text('中文'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
