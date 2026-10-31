import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import 'responsive_actions_test.dart' show ActionBackend;

void main() {
  testWidgets('global toast remains usable above routes', (tester) async {
    final c = SvoiController(ActionBackend());
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        builder: (context, child) => Stack(
          children: [
            child!,
            Positioned(
              bottom: 16,
              right: 16,
              child: SizedBox(width: 360, child: SvoiToastHost(c: c)),
            ),
          ],
        ),
        home: const Scaffold(body: Text('Settings')),
      ),
    );
    c.notify('Обновлено');
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('toast-close'))),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
  testWidgets(
    'toast repeats, expires, dismisses and does not replay tray events',
    (tester) async {
      final c = SvoiController(ActionBackend());
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: SvoiToastHost(c: c)),
        ),
      );
      c.notify('Обновлено');
      await tester.pumpAndSettle();
      expect(find.text('Обновлено'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Обновлено'), findsNothing);
      c.notify('Обновлено');
      await tester.pumpAndSettle();
      expect(find.text('Обновлено'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('toast-close')));
      await tester.pumpAndSettle();
      expect(find.text('Обновлено'), findsNothing);
      c.visibility(false);
      c.notify('Скрыто');
      c.visibility(true);
      await tester.pumpAndSettle();
      expect(find.text('Скрыто'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
  test('refresh emits one batch result and never success for failed or cancelled requests', () async {
    final api = ActionBackend();
    final c = SvoiController(api);
    await c.initialize();
    final events = <AppNotice>[];
    c.notice.addListener(() => events.add(c.notice.value!));
    final all = c.refreshSubscriptions();
    api.refreshes['demo']!.complete({});
    await all;
    expect(events.length, 1);
    expect(events.single.warning, false);
    events.clear();
    final failed = c.refreshSource('demo');
    api.refreshes['demo']!.completeError(ApiException('Offline'));
    await failed;
    expect(events.single.warning, true);
    events.clear();
    final cancelled = c.refreshSource('demo');
    c.cancelRefresh('demo');
    api.refreshes['demo']!.complete({});
    await cancelled;
    expect(events, isEmpty);
    final cancelledBatch = c.refreshSubscriptions();
    c.cancelRefresh('demo');
    api.refreshes['demo']!.complete({});
    await cancelledBatch;
    expect(events.single.warning, true);
    await c.close();
  });
}
