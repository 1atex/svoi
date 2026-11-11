import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import 'connection_ui_test.dart' show ConnectionBackend;

class IslandBackend extends ConnectionBackend {
  bool allowed = false;
  bool candidate = false;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path == 'night-island') {
      if (method == 'PUT') {
        if ((body as Map)['enabled'] == true && !candidate) {
          throw ApiException('Откройте Night Island и выберите SVOI.');
        }
        allowed = body['enabled'] == true;
      }
      return {
        'enabled': allowed,
        'candidate': candidate ? 'observed' : '',
        'available': candidate,
      };
    }
    return super.request(
      path,
      method: method,
      body: body,
      cancellation: cancellation,
    );
  }
}

void main() {
  testWidgets('permission starts off and a missing client is actionable', (
    tester,
  ) async {
    final api = IslandBackend();
    final c = SvoiController(api);
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: NightIslandPanel(c: c)),
      ),
    );
    await tester.pumpAndSettle();
    final finder = find.byKey(const ValueKey('night-island-permission'));
    expect(tester.widget<SwitchListTile>(finder).value, false);
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(find.text('Откройте Night Island и выберите SVOI.'), findsOneWidget);
    expect(api.allowed, false);
    api.candidate = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(api.allowed, true);
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(api.allowed, false);
    await tester.pumpWidget(const SizedBox());
    await c.close();
  });

  test('external switches update selection and last-used without starting another connection', () async {
    final api = IslandBackend();
    final c = SvoiController(api);
    await c.initialize();
    final first = c.servers.value[0].id;
    final second = c.servers.value[1].id;
    api.state = {'available': true, 'state': 'running', 'serverId': first};
    await c.poll(force: true);
    expect(c.selected.value, first);
    api.state = {'available': true, 'state': 'running', 'serverId': second};
    await c.poll(force: true);
    expect(c.selected.value, second);
    expect(c.lastUsed.value, second);
    expect(c.connection.value['serverId'], second);
    await c.close();
  });
}
