import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';

class ProbeBackend extends DemoBackend {
  int active = 0, peak = 0, completed = 0;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path.endsWith('/probe')) {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      active--;
      completed++;
      if (cancellation?.cancelled == true) throw ApiException('cancelled');
      return {'latency': 42};
    }
    if (path == 'connection') return {'available': true, 'state': 'stopped'};
    return super.request(
      path,
      method: method,
      body: body,
      cancellation: cancellation,
    );
  }
}

class StalledProbeBackend extends ProbeBackend {
  final stalled = <Completer<Map<String, dynamic>>>[];
  final cancellations = <RequestCancellation>[];

  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) {
    if (path.endsWith('/probe') && int.parse(path.split('/')[1]) < 4) {
      final response = Completer<Map<String, dynamic>>();
      stalled.add(response);
      cancellations.add(cancellation!);
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

class MobileProbeBackend extends ProbeBackend {
  int polls = 0;
  @override
  bool get mobile => true;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) {
    if (path == 'connection') polls++;
    return super.request(
      path,
      method: method,
      body: body,
      cancellation: cancellation,
    );
  }
}

class DelayedConnectionBackend extends DemoBackend {
  final started = Completer<void>(), checked = Completer<void>();
  Map<String, dynamic> state = {'state': 'stopped', 'available': true};
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path == 'connection/start') {
      await started.future;
      state = {
        'state': 'running',
        'available': true,
        ...Map<String, dynamic>.from(body as Map),
      };
    }
    if (path == 'connection/check') {
      await checked.future;
      state = {
        ...state,
        'checked': false,
        'error': 'timeout',
        'checkedAt': DateTime.now().toIso8601String(),
      };
      throw ApiException('timeout', 502);
    }
    if (path == 'connection') return state;
    if (path == 'connection/start') return state;
    return super.request(
      path,
      method: method,
      body: body,
      cancellation: cancellation,
    );
  }
}

class SavedProfilesBackend extends DemoBackend {
  @override
  bool get mobile => true;
  int stops = 0;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path == 'me') {
      if (token == 'expired') throw ApiException('expired', 401);
      return {
        ...this.group,
        'id': token,
        'name': 'Моя сеть',
        if (token == 'empty') 'servers': <dynamic>[],
        if (token == 'empty') 'subscriptions': <dynamic>[],
      };
    }
    if (path == 'connection/stop') stops++;
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
    'saved profile migration and switching retain servers and stable order',
    () async {
      final directory = await Directory.systemTemp.createTemp('svoi-profiles-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/session.json');
      await file.writeAsString(
        jsonEncode({
          'token': 'empty',
          'sessions': [
            for (final token in ['imported', 'expired', 'empty'])
              {'token': token, 'name': 'Моя сеть'},
          ],
        }),
      );
      final api = SavedProfilesBackend();
      final c = SvoiController(api, sessionFile: file);
      await c.initialize();
      expect(api.token, 'empty');
      expect(c.servers.value, isEmpty);
      expect(c.sessions.value.first['serverCount'], 1000);
      expect(c.sessions.value.last['serverCount'], 0);
      await c.switchProfile('imported');
      expect(c.servers.value.length, 1000);
      expect(c.selected.value, isNotEmpty);
      await c.switchProfile('imported');
      expect(api.stops, 1);
      await c.switchProfile('empty');
      expect(c.servers.value, isEmpty);
      await c.switchProfile('imported');
      expect(c.servers.value.length, 1000);
      expect(c.sessions.value.map((s) => s['token']), [
        'imported',
        'expired',
        'empty',
      ]);
      await c.close();
      final reopened = SvoiController(
        SavedProfilesBackend(),
        sessionFile: file,
      );
      await reopened.initialize();
      expect(reopened.api.token, 'imported');
      expect(reopened.servers.value.length, 1000);
      await reopened.close();
    },
  );
  test(
    'connection phases distinguish start, check and an unsuccessful check',
    () async {
      final api = DelayedConnectionBackend();
      final controller = SvoiController(api);
      await controller.initialize();
      final pending = controller.toggleConnection();
      expect(controller.connectionPhase.value, 'starting');
      api.started.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.connectionPhase.value, 'checking');
      expect(controller.lastUsed.value, controller.selected.value);
      api.checked.complete();
      await pending;
      expect(controller.connectionPhase.value, isEmpty);
      expect(controller.connectionIssue.value, 'timeout');
      expect(controller.connection.value['checked'], false);
      expect(controller.busy.value, false);
      await controller.close();
    },
  );

  test(
    'favorites survive restart and latency sorting keeps favorites first',
    () async {
      final dir = await Directory.systemTemp.createTemp('svoi-library-test-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/session.json');
      final c = SvoiController(ProbeBackend(), sessionFile: file);
      await c.initialize();
      await c.toggleFavorite('3');
      c.probes['0']!.value = ProbeState(latency: 70, checkedAt: DateTime.now());
      c.probes['1']!.value = ProbeState(latency: 20, checkedAt: DateTime.now());
      c.probes['2']!.value = ProbeState(
        error: 'timeout',
        checkedAt: DateTime.now(),
      );
      expect(
        c
            .orderedServers(c.servers.value.take(4), latency: true)
            .map((s) => s.id),
        ['3', '1', '0', '2'],
      );
      await c.close();
      final restored = SvoiController(ProbeBackend(), sessionFile: file);
      await restored.initialize();
      expect(restored.favorites.value, {'3'});
      expect(restored.orderedServers(restored.servers.value).first.id, '3');
      await restored.close();
    },
  );

  test(
    'active routing changes require applying, independent of map key order',
    () async {
      final c = SvoiController(ProbeBackend());
      await c.initialize();
      await c.setMode('tun');
      c.connection.value = {
        'state': 'running',
        'mode': 'tun',
        'serverId': c.selected.value,
        'routing': {
          'mode': 'include',
          'processes': ['Chrome.exe'],
        },
      };
      c.preferences.value = {
        'routing': {
          'processes': ['chrome.exe'],
          'mode': 'include',
        },
      };
      expect(c.pendingConnectionChoice, false);
      c.preferences.value = {
        'routing': {'mode': 'all', 'processes': []},
      };
      expect(c.pendingConnectionChoice, true);
      await c.close();
    },
  );
  test('probes use four slots and cancellation stops scheduling', () async {
    final backend = ProbeBackend();
    final controller = SvoiController(backend);
    await controller.initialize();
    await controller.probe(controller.servers.value.take(12).toList());
    expect(backend.peak, 4);
    expect(backend.completed, 12);
    expect(controller.probes['0']!.value.latency, 42);
    final pending = controller.probe(controller.servers.value);
    controller.cancelProbes();
    await pending;
    expect(backend.completed, 16);
    expect(controller.probing.value, false);
    expect(controller.probes.values.any((p) => p.value.busy), false);
    await controller.close();
  });
  testWidgets(
    'stalled probes are cancelled and release the queue after six seconds',
    (tester) async {
      final backend = StalledProbeBackend();
      final c = SvoiController(backend);
      await c.initialize();
      final pending = c.probe(c.servers.value.take(5).toList());
      expect(backend.stalled.length, 4);
      await tester.pump(const Duration(seconds: 6));
      expect(backend.cancellations.every((request) => request.cancelled), true);
      await tester.pump(const Duration(milliseconds: 20));
      await pending;
      expect(c.probing.value, false);
      expect(c.probes['0']!.value.error, contains('Локальный сервис'));
      expect(c.probes['4']!.value.latency, 42);
      for (final response in backend.stalled) {
        response.complete({'latency': 999});
      }
      await tester.pump();
      expect(c.probes['0']!.value.latency, isNull);
      await c.close();
    },
  );
  test('unchanged status does not notify widgets', () async {
    final c = SvoiController(ProbeBackend());
    await c.initialize();
    var notifications = 0;
    c.connection.addListener(() => notifications++);
    await c.poll();
    await c.poll();
    expect(notifications, 0);
    await c.close();
  });
  testWidgets(
    'mobile background stops UI polling and probe queue; resume refreshes state',
    (tester) async {
      final backend = MobileProbeBackend();
      final c = SvoiController(backend);
      await c.initialize();
      c.connection.value = {'state': 'running', 'available': true};
      final pending = c.probe(c.servers.value.take(12).toList());
      expect(backend.peak, 2);
      c.visibility(false);
      final polls = backend.polls;
      await tester.pump(const Duration(minutes: 2));
      await pending;
      expect(backend.completed, 2);
      expect(backend.polls, polls);
      expect(c.probing.value, false);
      expect(c.connection.value['state'], 'running');
      c.visibility(true);
      await tester.pump();
      expect(backend.polls, polls + 1);
      await c.close();
    },
  );
}
