import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import 'connection_ui_test.dart' show ConnectionBackend;

void main() {
  final node = ServerEntry({
    'id': 'hysteria',
    'name': 'NL Hysteria2',
    'protocol': 'hysteria2',
    'address': 'example.org',
    'port': 443,
    'network': 'hysteria',
    'security': 'tls',
  });
  test('Hysteria2 displays QUIC and its version', () {
    expect(node.protocol, 'Hysteria2');
    expect(node.details, contains('QUIC / UDP'));
    expect(node.isHysteria, true);
  });
  testWidgets('UDP node keeps configuration and hides misleading TCP test', (
    tester,
  ) async {
    final c = SvoiController(ConnectionBackend());
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(
          body: DesktopServerRow(c: c, server: node),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Действия сервера'));
    await tester.pumpAndSettle();
    expect(find.text('Проверить адрес · TCP'), findsNothing);
    expect(find.text('Конфигурация'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
}
