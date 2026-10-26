import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import 'connection_ui_test.dart';
import 'controller_test.dart' show ProbeBackend;

class NetworkBackend extends ConnectionBackend {
  String conflict = '';
  bool started = false;
  final checks = <RequestCancellation>[];
  final pending = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path == 'connection/preflight') return {'conflict': conflict};
    if (path == 'connection/start') started = true;
    if (path == 'dns') {
      return {
        'adapters': [
          {
            'id': 'nic',
            'name': 'Ethernet',
            'servers': ['192.0.2.1'],
          },
        ],
        'candidates': [
          {'name': 'Cloudflare', 'address': '1.1.1.1'},
          {'name': 'Google', 'address': '8.8.8.8'},
        ],
        'elevated': true,
      };
    }
    if (path == 'dns/benchmark') {
      checks.add(cancellation!);
      final complete = Completer<Map<String, dynamic>>();
      pending.add(complete);
      return complete.future;
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
    'zapret panel sleeps while hidden and retains unchanged results',
    (tester) async {
      final api = PanelBackend();
      final c = SvoiController(api);
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RemotePanel(
              c: c,
              path: 'zapret',
              builder: (context, data, acting, act) =>
                  Text('Results: ${(data['job']['results'] as List).length}'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Results: 1'), findsOneWidget);
      c.visibility(false);
      await tester.pump(const Duration(seconds: 30));
      expect(api.reads, 1);
      c.visibility(true);
      await tester.pumpAndSettle();
      expect(api.reads, 2);
      expect(find.text('Results: 1'), findsOneWidget);
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(find.text('Results: 2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
  test('external zapret blocks TUN without attempting a connection', () async {
    final api = NetworkBackend()..conflict = 'external';
    final c = SvoiController(api);
    await c.initialize();
    await c.toggleConnection();
    expect(api.started, false);
    expect(c.connectionIssue.value, contains('сторонний zapret'));
    await c.close();
  });
  test(
    'managed zapret needs consent, remembered consent skips dialog',
    () async {
      final api = NetworkBackend()..conflict = 'managed';
      final c = SvoiController(api);
      await c.initialize();
      c.approveZapretPause = () async => 'cancel';
      await c.toggleConnection();
      expect(api.started, false);
      c.approveZapretPause = () async => 'once';
      await c.toggleConnection();
      expect(api.started, true);
      expect(api.state['pauseZapret'], true);
      await c.close();
    },
  );
  test(
    'completed probes survive restart and cancellation retains last result',
    () async {
      final dir = await Directory.systemTemp.createTemp('svoi-probe-history-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/session.json');
      final c = SvoiController(ProbeBackend(), sessionFile: file);
      await c.initialize();
      await c.probe(c.servers.value.take(1).toList());
      final second = c.probe(c.servers.value.take(1).toList());
      expect(c.probes['0']!.value.latency, 42);
      c.cancelProbes();
      await second;
      expect(c.probes['0']!.value.latency, 42);
      await c.close();
      final restored = SvoiController(ProbeBackend(), sessionFile: file);
      await restored.initialize();
      expect(restored.probes['0']!.value.latency, 42);
      expect(restored.probes['0']!.value.busy, false);
      await restored.close();
    },
  );
  testWidgets(
    'DNS results arrive separately, cancel aborts requests and ignores late responses',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = NetworkBackend();
      final c = SvoiController(api);
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: DnsTools(c: c)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сравнить DNS'));
      await tester.pump();
      expect(api.checks.length, 3);
      api.pending[0].complete({
        'success': 6,
        'total': 6,
        'medianMs': 10,
        'worstMs': 20,
      });
      await tester.pump();
      expect(find.textContaining('Медиана 10.0'), findsOneWidget);
      await tester.tap(find.text('Остановить'));
      await tester.pump();
      expect(api.checks.skip(1).every((r) => r.cancelled), true);
      api.pending[1].complete({
        'success': 6,
        'total': 6,
        'medianMs': 99,
        'worstMs': 100,
      });
      api.pending[2].complete({
        'success': 6,
        'total': 6,
        'medianMs': 99,
        'worstMs': 100,
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('Медиана 99.0'), findsNothing);
      expect(find.text('Лучший результат этого теста'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
}

class PanelBackend extends NetworkBackend {
  int reads = 0;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path.startsWith('zapret')) {
      reads++;
      return {
        'resultsRevision': reads < 3 ? '1' : '2',
        'resultsUnchanged': reads == 2,
        'job': {
          'busy': false,
          'results': reads == 2
              ? []
              : List.generate(reads < 3 ? 1 : 2, (i) => {'target': '$i'}),
        },
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
