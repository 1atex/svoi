import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import 'subscription_variants_test.dart' show variantsBackend;

void main() {
  testWidgets('unavailable core preserves library, title and collapsed state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = variantsBackend();
    (backend.group['servers'] as List).removeWhere(
      (s) => s['subscriptionCore'] != 'xray',
    );
    (backend.group['subscriptions'][0]['variants'] as Map)['mihomo'] = {
      'state': 'unavailable',
      'count': 0,
      'metadata': {'title': 'Different title'},
    };
    final c = SvoiController(backend);
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: DesktopWorkspace(c: c)),
      ),
    );
    await tester.pumpAndSettle();
    final library = tester.state(find.byType(DesktopLibrary));
    await tester.tap(find.text('Provider'));
    await tester.pump();
    expect(find.byType(DesktopServerRow), findsNothing);
    c.connection.value = {...c.connection.value, 'core': 'mihomo'};
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(DesktopLibrary)), same(library));
    expect(find.text('Provider'), findsOneWidget);
    expect(find.text('Different title'), findsNothing);
    expect(find.byType(DesktopServerRow), findsNothing);
    await tester.tap(find.text('Provider'));
    await tester.pump();
    final row = tester.widget<InkWell>(
      find.byKey(const ValueKey('select-server-xray')),
    );
    expect(row.onTap, isNull);
    expect(c.selected.value, isEmpty);
    expect(find.text('Нет ответа'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });

  testWidgets('subscription drag moves whole group without collapsing it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = variantsBackend();
    (backend.group['subscriptions'] as List).add({
      'id': 'second',
      'name': 'Second subscription',
    });
    final c = SvoiController(backend);
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: DesktopWorkspace(c: c)),
      ),
    );
    await tester.pumpAndSettle();
    final start = tester.getCenter(
      find.byKey(const ValueKey('reorder-source-second')),
    );
    final target =
        tester.getTopLeft(find.byKey(const ValueKey('drop-source-source'))) +
        const Offset(120, 6);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, -12));
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(c.subscriptions.value.map((s) => s['id']), ['second', 'source']);
    expect(find.byType(DesktopServerRow), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
}
