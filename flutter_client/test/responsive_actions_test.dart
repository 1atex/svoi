import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';
import 'package:svoi_flutter/user_failure.dart';

class ActionBackend extends DemoBackend {
  ActionBackend({this.stallChecks = false}) {
    this.group['subscriptions'][0]['remote'] = true;
  }
  final bool stallChecks;
  final checks = <Completer<Map<String, dynamic>>>[];
  final checkRequests = <RequestCancellation>[];
  final refreshes = <String, Completer<Map<String, dynamic>>>{};
  final refreshRequests = <String, RequestCancellation>{};
  int starts = 0;
  Completer<void>? startGate;
  Map<String, dynamic> state = {'available': true, 'state': 'stopped'};

  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path.startsWith('subscription/refresh')) {
      final id = Uri.parse(path).queryParameters['id']!;
      refreshRequests[id] = cancellation!;
      final response = Completer<Map<String, dynamic>>();
      refreshes[id] = response;
      return response.future;
    }
    if (path == 'connection/preflight') return {'conflict': ''};
    if (path == 'connection/start') {
      starts++;
      await startGate?.future;
      state = {
        'available': true,
        'state': 'running',
        ...Map<String, dynamic>.from(body as Map),
        'startedAt': '$starts',
      };
    }
    if (path == 'connection/stop') {
      state = {'available': true, 'state': 'stopped'};
    }
    if (path == 'connection/check') {
      if (stallChecks) {
        final response = Completer<Map<String, dynamic>>();
        checks.add(response);
        checkRequests.add(cancellation!);
        return response.future;
      }
      state = {...state, 'checked': true};
    }
    if (path.startsWith('connection')) return Map.from(state);
    if (path == 'me' && token == 'other') {
      return {
        'id': 'other',
        'name': 'Other',
        'servers': <dynamic>[],
        'subscriptions': <dynamic>[],
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

class SlowProbeBackend extends ActionBackend {
  final responses = <Completer<Map<String, dynamic>>>[];
  final requests = <RequestCancellation>[];
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) {
    if (path.endsWith('/probe')) {
      final response = Completer<Map<String, dynamic>>();
      responses.add(response);
      requests.add(cancellation!);
      return response.future;
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
    'an empty subscription shows its failure and retry next to import',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = ActionBackend();
      api.group['servers'] = <dynamic>[];
      final c = SvoiController(api);
      await c.initialize();
      c.refreshErrors.value = {
        'demo': subscriptionFailure(ApiException('HTTP 403', 502)).text,
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: SvoiShell(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Повторить'));
      expect(find.textContaining('Провайдер отклонил'), findsOneWidget);
      expect(find.text('Повторить').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );

  test(
    'connecting and hiding cancel probe work without waiting for stale results',
    () async {
      final api = SlowProbeBackend();
      final c = SvoiController(api);
      await c.initialize();
      final first = c.probe(c.servers.value.take(12).toList());
      expect(api.responses, hasLength(4));
      await c.toggleConnection();
      expect(c.connection.value['state'], 'running');
      expect(api.requests.every((r) => r.cancelled), true);
      for (final response in api.responses) {
        response.complete({'latency': 999});
      }
      await first;
      expect(api.responses, hasLength(4));
      expect(c.probes.values.every((p) => p.value.latency == null), true);
      api.responses.clear();
      api.requests.clear();
      final next = c.probe(c.servers.value.take(12).toList());
      c.visibility(false);
      expect(api.requests.every((r) => r.cancelled), true);
      for (final response in api.responses) {
        response.complete({'latency': 999});
      }
      await next;
      expect(api.responses, hasLength(4));
      await c.close();
    },
  );

  test(
    'a slow subscription does not delay another source or erase its success',
    () async {
      final api = ActionBackend();
      (api.group['subscriptions'] as List).add({
        'id': 'second',
        'remote': true,
        'name': 'Second',
      });
      final c = SvoiController(api);
      await c.initialize();
      final update = c.refreshSubscriptions();
      expect(api.refreshes.keys.toSet(), {'demo', 'second'});
      api.group['subscriptions'][1]['count'] = 12;
      api.refreshes['second']!.complete({});
      await Future<void>.delayed(Duration.zero);
      expect(c.subscriptions.value.last['count'], 12);
      expect(c.refreshingSources.value, {'demo'});
      api.refreshes['demo']!.completeError(ApiException('HTTP 503', 502));
      await update;
      expect(c.subscriptions.value.last['count'], 12);
      expect(c.refreshErrors.value.keys, ['demo']);
      await c.close();
    },
  );
  test(
    'slow internet check cannot delay disconnect or overwrite stopped status',
    () async {
      final api = ActionBackend(stallChecks: true);
      final c = SvoiController(api);
      await c.initialize();
      await c.toggleConnection();
      expect(c.connection.value['state'], 'running');
      expect(c.busy.value, false);
      expect(c.checking.value, true);
      expect(api.checks, hasLength(1));
      await c.stop();
      expect(api.checkRequests.single.cancelled, true);
      api.checks.single.completeError(ApiException('late timeout', 502));
      await Future<void>.delayed(Duration.zero);
      expect(c.connection.value['state'], 'stopped');
      expect(c.connectionIssue.value, isEmpty);
      expect(c.checking.value, false);
      await c.close();
    },
  );

  test(
    'server switch cancels previous check and accepts only the new result',
    () async {
      final api = ActionBackend(stallChecks: true);
      final c = SvoiController(api);
      await c.initialize();
      await c.toggleConnection();
      final old = Map<String, dynamic>.from(c.connection.value);
      await c.select('1');
      await c.toggleConnection();
      expect(api.checkRequests.first.cancelled, true);
      expect(api.starts, 2);
      api.checks.first.complete({...old, 'checked': true});
      await Future<void>.delayed(Duration.zero);
      expect(c.connection.value['serverId'], '1');
      expect(c.checking.value, true);
      api.checks.last.complete({...c.connection.value, 'checked': true});
      await Future<void>.delayed(Duration.zero);
      expect(c.connection.value['checked'], true);
      await c.close();
    },
  );

  test('repeated clicks during startup create a single connection', () async {
    final api = ActionBackend()..startGate = Completer<void>();
    final c = SvoiController(api);
    await c.initialize();
    final first = c.toggleConnection();
    await c.toggleConnection();
    await Future<void>.delayed(Duration.zero);
    expect(api.starts, 1);
    api.startGate!.complete();
    await first;
    await c.close();
  });

  test('subscription refresh keeps connection and selection usable, preserves failed source', () async {
    final api = ActionBackend();
    final c = SvoiController(api);
    await c.initialize();
    final update = c.refreshSubscriptions();
    expect(c.busy.value, false);
    expect(c.refreshingSources.value, {'demo'});
    await c.select('1');
    await c.toggleConnection();
    expect(api.state['serverId'], '1');
    api.refreshes['demo']!.completeError(ApiException('HTTP 403', 502));
    await update;
    expect(c.servers.value, hasLength(1000));
    expect(c.selected.value, '1');
    expect(c.refreshErrors.value['demo'], contains('Провайдер отклонил'));
    expect(c.refreshErrors.value['demo'], contains('личном кабинете'));
    expect(c.message.value, isEmpty);
    expect(c.refreshingSources.value, isEmpty);
    await c.close();
  });

  test(
    'profile change cancels refresh and ignores its late completion',
    () async {
      final api = ActionBackend();
      final c = SvoiController(api);
      await c.initialize();
      final update = c.refreshSource('demo');
      await c.switchProfile('other');
      expect(api.refreshRequests['demo']!.cancelled, true);
      api.refreshes['demo']!.complete({});
      await update;
      expect(c.group.value['id'], 'other');
      expect(c.servers.value, isEmpty);
      expect(c.refreshErrors.value, isEmpty);
      await c.close();
    },
  );

  test('source refresh is deduplicated and explicit cancellation keeps old servers', () async {
    final api = ActionBackend();
    final c = SvoiController(api);
    await c.initialize();
    final update = c.refreshSource('demo');
    final first = api.refreshes['demo'];
    await c.refreshSource('demo');
    expect(api.refreshes['demo'], same(first));
    c.cancelRefresh('demo');
    api.refreshes['demo']!.completeError(ApiException('cancelled'));
    await update;
    expect(c.servers.value, hasLength(1000));
    expect(c.refreshErrors.value['demo'], contains('остановлено'));
    await c.close();
  });

  testWidgets(
    'refresh feedback stays by the source and VPN remains clickable',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = ActionBackend();
      final c = SvoiController(api);
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: SvoiShell(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Обновить Демонстрационная подписка'));
      await tester.pump();
      expect(
        find.textContaining('Сохранённые серверы доступны'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('connection-power')))
            .onPressed,
        isNotNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('desktop-server-search')),
        '1000',
      );
      await tester.pump();
      expect(find.text('1 из 1000 серверов'), findsOneWidget);
      api.refreshes['demo']!.completeError(ApiException('HTTP 404', 502));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Ссылка на подписку недействительна'),
        findsOneWidget,
      );
      expect(find.text('Повторить').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );

  testWidgets(
    'power and server switching remain available during the internet check',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = ActionBackend(stallChecks: true);
      final c = SvoiController(api);
      await c.initialize();
      await c.toggleConnection();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: SvoiShell(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      final power = find.byKey(const ValueKey('connection-power'));
      expect(tester.widget<TextButton>(power).onPressed, isNotNull);
      await c.select('1');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('switch-server')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(power);
      await tester.pumpAndSettle();
      expect(api.state['state'], 'stopped');
      api.checks.single.completeError(ApiException('cancelled'));
      await tester.pump();
      expect(c.connectionIssue.value, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );

  test(
    'recovery messages give concrete steps for provider and VPN failures',
    () {
      expect(
        subscriptionFailure(ApiException('HTTP 429', 502)).action,
        contains('минуту'),
      );
      expect(
        subscriptionFailure(ApiException('HTTP 302', 502)).action,
        contains('конечную HTTPS'),
      );
      expect(
        connectionFailure('Нужны права администратора', running: false).action,
        contains('от имени администратора'),
      );
      expect(
        connectionFailure('Xray отклонил конфигурацию', running: true).action,
        contains('Предыдущее соединение сохранено'),
      );
      expect(
        connectionFailure('timeout', running: true).action,
        contains('VPN остаётся включён'),
      );
    },
  );
}
