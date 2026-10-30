import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

void main() {
  Map<String, dynamic> node(String protocol) => {
    'id': 'protocol-test',
    'name': 'NL Тест',
    'protocol': protocol,
    'address': 'example.org',
    'port': 443,
    'network': 'tcp',
    'security': 'tls',
  };

  test('protocol labels distinguish Hysteria versions and mixed profiles', () {
    expect(ServerEntry(node('hysteria2')).protocol, 'Hysteria2');
    expect(ServerEntry(node('hysteria')).protocol, 'Hysteria');
    final profile = ServerEntry({
      ...node('vless'),
      'fullProfile': true,
      'protocols': ['vless', 'hysteria2', 'vless'],
    });
    expect(profile.protocol, 'VLESS / Hysteria2 · профиль');
    expect(profile.search, contains('hysteria2'));
    expect(
      ServerEntry({...node('vless'), 'fullProfile': true}).protocol,
      'Профиль Xray',
    );
    expect(
      ServerEntry({...node(''), 'protocol': null}).protocol,
      'Протокол не указан',
    );
  });

  testWidgets(
    'protocol remains visible for recent, selected and connected nodes',
    (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = SvoiController(DemoBackend());
      final server = ServerEntry(node('hysteria2'));
      c.lastUsed.value = server.id;
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: DesktopServerRow(c: c, server: server),
            ),
          ),
        ),
      );
      expect(find.text('Hysteria2 · Последний запуск'), findsOneWidget);
      c.selected.value = server.id;
      await tester.pump();
      expect(find.text('Hysteria2 · Выбран'), findsOneWidget);
      c.connection.value = {'state': 'running', 'serverId': server.id};
      await tester.pump();
      expect(find.text('Hysteria2 · Подключён'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
}
