import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide group;
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class DNSBackend extends DemoBackend {
  final pending = <Completer<Map<String, dynamic>>>[];
  final cancellations = <RequestCancellation>[];
  int total = 0;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path == 'dns/catalog') {
      return {
        'candidates': List.generate(
          5,
          (i) => {'name': 'DNS $i', 'address': '192.0.2.${i + 1}'},
        ),
      };
    }
    if (path == 'dns/benchmark') {
      total++;
      final result = Completer<Map<String, dynamic>>();
      pending.add(result);
      if (cancellation != null) {
        cancellations.add(cancellation);
      }
      return result.future;
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
  testWidgets(
    'DNS runs on request, limits concurrency and cancels on background',
    (tester) async {
      final api = DNSBackend();
      final c = SvoiController(api);
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: DnsComparePanel(c: c)),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.total, 0);
      await tester.tap(find.text('Сравнить DNS').last);
      await tester.pump();
      expect(api.total, 3);
      api.pending.first.complete({'success': 3, 'total': 6, 'medianMs': 1.0});
      await tester.pump();
      expect(api.total, 4);
      expect(find.textContaining('Лучший из проверенных'), findsNothing);
      api.pending[1].complete({'success': 6, 'total': 6, 'medianMs': 15.0});
      await tester.pump();
      expect(api.total, 5);
      expect(find.text('Лучший из проверенных · 6/6'), findsOneWidget);
      c.visibility(false);
      await tester.pump();
      expect(api.cancellations.skip(2).every((r) => r.cancelled), isTrue);
      for (final request in api.pending) {
        if (!request.isCompleted) {
          request.completeError(ApiException("Отменено"));
        }
      }
      await tester.pump();
      expect(find.text('Остановить'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );

  testWidgets(
    'DNS is unavailable with VPN and site check explains invalid input',
    (tester) async {
      final api = DNSBackend();
      final c = SvoiController(api);
      await c.initialize();
      c.connection.value = {'state': 'running', 'mode': 'tun', 'serverId': '1'};
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: DnsComparePanel(c: c)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppButton>(find.byType(AppButton)).onPressed,
        isNull,
      );
      expect(api.total, 0);
      expect(find.textContaining('Отключите VPN'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: CurrentSitePanel(c: c)),
        ),
      );
      await tester.enterText(find.byType(TextField), 'http://example.com');
      await tester.tap(find.text('Проверить сайт').last);
      await tester.pump();
      expect(find.textContaining('Введите HTTPS-адрес'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
}
