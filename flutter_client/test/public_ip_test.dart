import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class IPBackend extends DemoBackend {
  final lookups = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) {
    if (path == 'connection/ip') {
      final next = Completer<Map<String, dynamic>>();
      lookups.add(next);
      return next.future;
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
  test(
    'IP updates on connection changes, ignores stale replies and does not poll',
    () async {
      final backend = IPBackend();
      final c = SvoiController(backend);
      await c.initialize();
      expect(backend.lookups, isEmpty);
      c.enablePublicIP();
      backend.lookups[0].complete({'ip': '203.0.113.1', 'via': 'network'});
      await Future<void>.delayed(Duration.zero);
      c.connection.value = {
        'state': 'running',
        'mode': 'tun',
        'serverId': 'one',
        'startedAt': 'first',
      };
      c.connection.value = {...c.connection.value, 'checked': true};
      expect(backend.lookups.length, 2);
      c.connection.value = {
        'state': 'running',
        'mode': 'tun',
        'serverId': 'two',
        'startedAt': 'second',
      };
      backend.lookups[1].complete({'ip': '203.0.113.2', 'via': 'tun'});
      await Future<void>.delayed(Duration.zero);
      expect(c.publicIP.value['ip'], isNull);
      backend.lookups[2].complete({'ip': '203.0.113.3', 'via': 'tun'});
      await Future<void>.delayed(Duration.zero);
      expect(c.publicIP.value['ip'], '203.0.113.3');
      expect(c.publicIP.value['previousIP'], '203.0.113.1');
      await c.close();
    },
  );

  testWidgets('IP display reports comparison and has bounded failure state', (
    tester,
  ) async {
    final backend = IPBackend();
    final c = SvoiController(backend);
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: PublicIPLine(c: c)),
      ),
    );
    backend.lookups[0].complete({'ip': '203.0.113.1', 'via': 'network'});
    await tester.pumpAndSettle();
    expect(find.text('IP · 203.0.113.1'), findsOneWidget);
    c.connection.value = {'state': 'running', 'mode': 'tun', 'serverId': 'one'};
    backend.lookups[1].complete({'ip': '203.0.113.2', 'via': 'tun'});
    await tester.pumpAndSettle();
    expect(find.text('IP изменился'), findsOneWidget);
    expect(find.byTooltip('Скопировать IP'), findsOneWidget);
    await tester.tap(find.byTooltip('Обновить IP'));
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('IP не определён'), findsOneWidget);
    backend.lookups.last.complete({'ip': '203.0.113.99', 'via': 'tun'});
    await tester.pump();
    expect(find.text('IP · 203.0.113.99'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
}
