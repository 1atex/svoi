import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/main.dart';

import 'features_test.dart' show FeatureBackend;
import 'controller_test.dart' show ProbeBackend, StalledProbeBackend;

class UnavailableCoreBackend extends ProbeBackend {
  UnavailableCoreBackend([this.status = 503]);
  final int status;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) {
    if (path.endsWith('/probe')) {
      return Future.error(ApiException('Причина отказа проверки', status));
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
    'provider probe address follows subscription and manual override',
    () async {
      final c = SvoiController(ProbeBackend());
      await c.initialize();
      final server = ServerEntry({
        'id': 'provider',
        'name': 'Test',
        'subscriptionId': 'source',
      });
      c.subscriptions.value = [
        {
          'id': 'other',
          'metadata': {
            'hints': {'check-url-via-proxy': 'https://wrong.example/'},
          },
        },
        {
          'id': 'source',
          'metadata': {
            'hints': {'check-url-via-proxy': 'http://ya.ru/'},
          },
        },
      ];
      c.preferences.value = {};
      expect(c.probeUrlFor(server), 'http://ya.ru/');
      c.preferences.value = {
        'probe': {'urlSource': 'custom', 'url': defaultProbeUrl},
      };
      expect(c.probeUrlFor(server), defaultProbeUrl);
      c.preferences.value = {
        'probe': {'url': 'https://custom.example/'},
      };
      expect(c.probeUrlFor(server), 'https://custom.example/');
      c.preferences.value = {
        'probe': {
          'urlSource': 'subscription',
          'url': 'https://fallback.example/',
        },
      };
      expect(c.probeUrlFor(server), 'http://ya.ru/');
      c.subscriptions.value = [
        {
          'id': 'source',
          'metadata': {
            'hints': {'check-url-via-proxy': 'file:///private'},
          },
        },
      ];
      expect(c.probeUrlFor(server), 'https://fallback.example/');
      await c.close();
    },
  );
  test(
    'core change clears persisted probe history as well as visible values',
    () async {
      final dir = await Directory.systemTemp.createTemp('svoi-core-history-');
      final session = File('${dir.path}/session.json');
      final c = SvoiController(ProbeBackend(), sessionFile: session);
      await c.initialize();
      await c.probe(c.servers.value.take(1).toList());
      expect(c.probes['0']!.value.latency, 42);
      await c.clearProbeHistory();
      expect(c.probes['0']!.value.latency, isNull);
      await c.close();
      final restored = SvoiController(ProbeBackend(), sessionFile: session);
      await restored.initialize();
      expect(
        restored.probes.values.every((probe) => probe.value.latency == null),
        true,
      );
      await restored.close();
      await dir.delete(recursive: true);
    },
  );
  testWidgets('quiet unavailable result retains distinct diagnostic reasons', (
    tester,
  ) async {
    for (final item in {
      422: 'Несовместимо',
      503: 'Ошибка ядра',
      504: 'Нет ответа',
      502: 'Ошибка проверки',
      429: 'Проверка занята',
    }.entries) {
      final c = SvoiController(UnavailableCoreBackend(item.key));
      await c.initialize();
      c.connection.value = {...c.connection.value, 'available': true};
      final server = c.servers.value.first;
      await c.probe([server]);
      final state = c.probes[server.id]!.value;
      expect(
        ProbeState.fromJson(state.toJson()).withBusy(false).failureLabel,
        item.value,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(
            body: ServerPingButton(c: c, server: server),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('n/a'), findsOneWidget);
      expect(find.text('Нет ответа'), findsNothing);
      await tester.tap(find.text('n/a'));
      await tester.pumpAndSettle();
      expect(find.text(item.value), findsOneWidget);
      expect(state.latency, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    }
  });
  test(
    'preparation failure is distinct from server timeout and persists',
    () async {
      final c = SvoiController(UnavailableCoreBackend());
      await c.initialize();
      await c.probe(c.servers.value.take(1).toList());
      final result = c.probes['0']!.value;
      expect(result.setupError, true);
      expect(result.latency, isNull);
      expect(
        ProbeState.fromJson(result.toJson()).withBusy(true).setupError,
        true,
      );
      await c.close();
    },
  );
  testWidgets(
    'probe form validates and saves without changing other preferences',
    (tester) async {
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FeatureBackend();
      final c = SvoiController(backend);
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(
            body: SingleChildScrollView(child: ProbeSettingsPanel(c: c)),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('probe-url')),
        'file:///secret',
      );
      await tester.pump();
      expect(
        find.text('Введите HTTP(S)-адрес без логина, пароля и фрагмента'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Сохранить настройки'));
      await tester.tap(find.text('Сохранить настройки'));
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c == 'PUT settings'), isEmpty);
      await tester.ensureVisible(find.text('HiCloud'));
      await tester.tap(find.text('HiCloud'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Сохранить настройки'));
      await tester.tap(find.text('Сохранить настройки'));
      await tester.pumpAndSettle();
      expect(backend.prefs['probe'], {
        'url': 'http://connectivitycheck.platform.hicloud.com/generate_204',
        'urlSource': 'subscription',
        'timeoutSeconds': 4,
        'parallel': 4,
      });
      expect(backend.prefs['autoRefresh'], false);
      expect((backend.prefs['routing'] as Map)['mode'], 'all');
      expect(find.text('Настройки сохранены'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );

  test(
    'configured concurrency and probe URL survive history persistence',
    () async {
      final backend = ProbeBackend();
      final c = SvoiController(backend);
      await c.initialize();
      c.preferences.value = {
        'probe': {
          'parallel': 2,
          'timeoutSeconds': 8,
          'url': 'http://example.org/check',
        },
      };
      await c.probe(c.servers.value.take(7).toList());
      expect(backend.peak, 2);
      expect(backend.completed, 7);
      final restored = ProbeState.fromJson(c.probes['0']!.value.toJson());
      expect(restored.url, 'http://example.org/check');
      expect(restored.latency, 42);
      expect(c.probeProgress.value, contains('лимит 8 с'));
      await c.close();
    },
  );

  testWidgets('configured timeout cancels stalled requests', (tester) async {
    final backend = StalledProbeBackend();
    final c = SvoiController(backend);
    await c.initialize();
    c.preferences.value = {
      'probe': {
        'parallel': 1,
        'timeoutSeconds': 1,
        'url': 'http://example.org/check',
      },
    };
    final pending = c.probe(c.servers.value.take(1).toList());
    await tester.pump(const Duration(seconds: 8));
    await pending;
    expect(backend.cancellations.single.cancelled, true);
    expect(c.probing.value, false);
    backend.stalled.single.complete({'latency': 999});
    await tester.pump();
    expect(c.probes['0']!.value.latency, isNull);
    await c.close();
  });
}
