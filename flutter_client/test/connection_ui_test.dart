import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class ConnectionBackend extends DemoBackend {
  Map<String, dynamic> state = {'available': true, 'state': 'stopped'};
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path == 'connection/start') {
      state = {
        'available': true,
        'state': 'running',
        ...Map<String, dynamic>.from(body as Map),
      };
    }
    if (path == 'connection/check') {
      state['checked'] = true;
      state['checkedAt'] = DateTime.now().toIso8601String();
    }
    if (path == 'connection/stop') {
      state = {'available': true, 'state': 'stopped'};
    }
    if (path.startsWith('connection')) return Map.from(state);
    return super.request(
      path,
      method: method,
      body: body,
      cancellation: cancellation,
    );
  }
}

void main() {
  testWidgets(
    'new connection controls choose mode, start and stop the selected server',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = ConnectionBackend();
      final c = SvoiController(backend);
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: SvoiShell(controller: c),
        ),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Все приложения · TUN').last);
      await tester.pumpAndSettle();
      expect(c.mode.value, 'tun');
      c.probes[c.selected.value]!.value = ProbeState(
        error: 'timeout',
        checkedAt: DateTime.now(),
      );
      await tester.pump();
      final connect = find.byKey(const ValueKey('connection-power'));
      expect(tester.widget<TextButton>(connect).onPressed, isNotNull);
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(backend.state['serverId'], c.selected.value);
      expect(backend.state['mode'], 'tun');
      expect(find.text('Подключено'), findsWidgets);
      expect(find.textContaining('HTTPS-проверка пройдена'), findsOneWidget);

      await c.select('1');
      await tester.pumpAndSettle();
      expect(find.text('Применить выбранный сервер и режим'), findsOneWidget);
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(backend.state['state'], 'stopped');
      await tester.tap(find.byKey(const ValueKey('open-server-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favorite-2')));
      await tester.pumpAndSettle();
      expect(c.favorites.value.contains('2'), true);
      await tester.tap(find.byTooltip('Закрыть').last);
      await tester.pumpAndSettle();

      Focus.of(
        tester.element(
          find.descendant(of: connect, matching: find.byType(Icon)).first,
        ),
      ).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(backend.state['state'], 'running');
      expect(backend.state['serverId'], '1');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(backend.state['state'], 'stopped');
      c.busy.value = true;
      await tester.pump();
      expect(tester.widget<TextButton>(connect).onPressed, isNull);
      c.busy.value = false;
      c.connection.value = {'available': false, 'state': 'stopped'};
      await tester.pump();
      expect(tester.widget<TextButton>(connect).onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
}
