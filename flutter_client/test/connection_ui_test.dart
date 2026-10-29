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
  testWidgets('backend shutdown remains visible and prevents reconnect', (
    tester,
  ) async {
    final c = SvoiController(ConnectionBackend());
    await c.initialize();
    c.connection.value = {'available': true, 'state': 'stopping'};
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(
          body: SingleChildScrollView(child: ConnectionCard(c: c)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Отключаемся…'), findsOneWidget);
    expect(find.text('Завершается…'), findsOneWidget);
    expect(find.text('VPN выключен'), findsNothing);
    final button = tester.widget<TextButton>(
      find.byKey(const ValueKey('connection-power')),
    );
    expect(button.onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });

  testWidgets(
    'failed internet check keeps VPN status and explicit disconnect, hides admin hint when elevated',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = ConnectionBackend();
      final c = SvoiController(backend);
      await c.initialize();
      c.mode.value = 'tun';
      backend.state = {
        'available': true,
        'state': 'running',
        'elevated': true,
        'checked': false,
        'error': 'Timeout',
        'mode': 'tun',
        'serverId': c.selected.value,
      };
      c.connection.value = Map.from(backend.state);
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(
            body: SingleChildScrollView(child: ConnectionCard(c: c)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('VPN включён'), findsOneWidget);
      expect(find.text('Отключить VPN'), findsNothing);
      expect(find.byTooltip('Отключить VPN'), findsOneWidget);
      expect(find.textContaining('Интернет не подтверждён'), findsOneWidget);
      expect(
        find.textContaining('TUN требует прав администратора'),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('connection-power')));
      await tester.pumpAndSettle();
      expect(backend.state['state'], 'stopped');
      expect(
        find.textContaining('TUN требует прав администратора'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );

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
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
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
      expect(find.text('Интернет проверен'), findsOneWidget);

      await c.select('1');
      await tester.pumpAndSettle();
      expect(find.text('Переключиться'), findsOneWidget);
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(backend.state['state'], 'stopped');
      await tester.tap(find.byTooltip('Действия сервера').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('В избранное'));
      await tester.pumpAndSettle();
      expect(c.favorites.value.isNotEmpty, true);

      Focus.of(
        tester.element(
          find
              .descendant(
                of: connect,
                matching: find.byWidgetPredicate((widget) => widget is Icon),
              )
              .first,
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
