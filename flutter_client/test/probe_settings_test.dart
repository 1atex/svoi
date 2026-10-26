import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/main.dart';

import 'features_test.dart' show FeatureBackend;
import 'controller_test.dart' show ProbeBackend, StalledProbeBackend;

class UnavailableCoreBackend extends ProbeBackend {
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) {
    if (path.endsWith('/probe')) {
      return Future.error(ApiException('Не удалось подготовить Xray', 503));
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
      await tester.tap(find.text('Сохранить настройки'));
      await tester.pumpAndSettle();
      expect(backend.calls.where((c) => c == 'PUT settings'), isEmpty);
      await tester.tap(find.text('HiCloud'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить настройки'));
      await tester.pumpAndSettle();
      expect(backend.prefs['probe'], {
        'url': 'http://connectivitycheck.platform.hicloud.com/generate_204',
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
