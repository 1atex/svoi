import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

void main() {
  testWidgets('subscription editor does not require a core format choice', (
    tester,
  ) async {
    Map<String, String>? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await editFields(
                  context,
                  'Подписка',
                  {'name': 'Название'},
                  {'name': 'Provider', 'responseFormat': 'auto'},
                );
              },
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(result, {'name': 'Provider'});
    expect(tester.takeException(), isNull);
  });

  test('native profiles show their actual core and constituent protocols', () {
    final server = ServerEntry({
      'id': 'native',
      'name': 'Профиль Mihomo',
      'fullProfile': true,
      'sourceProfileCore': 'mihomo',
      'nodeCount': 2,
      'protocols': ['vless', 'hysteria2'],
    });
    expect(server.protocol, 'VLESS / Hysteria2 · профиль Mihomo');
    expect(server.search, contains('hysteria2'));
    expect(server.protocol, isNot(contains('Xray')));
  });
}
