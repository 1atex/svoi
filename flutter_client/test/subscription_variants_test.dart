import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class RefreshFailureBackend extends DemoBackend {
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path.startsWith('subscription/refresh')) {
      final source = (this.group['subscriptions'] as List).single as Map;
      source['variants'] = {
        for (final core in ['xray', 'sing-box', 'mihomo'])
          core: {
            'state': 'error',
            'count': 1,
            'stale': true,
            'error': '$core failed',
          },
      };
      throw ApiException('xray failed', 502);
    }
    return super.request(
      path,
      method: method,
      body: body,
      cancellation: cancellation,
    );
  }
}

class RecordingVariantsBackend extends DemoBackend {
  final requests = <String>[];

  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) {
    requests.add(path);
    return super.request(
      path,
      method: method,
      body: body,
      cancellation: cancellation,
    );
  }
}

DemoBackend variantsBackend([DemoBackend? instance]) {
  final backend = instance ?? DemoBackend();
  backend.group['servers'] = [
    for (final core in ['xray', 'sing-box', 'mihomo'])
      {
        'id': core,
        'name': 'Same name',
        'subscriptionId': 'source',
        'subscriptionCore': core,
        'fullProfile': true,
        if (core != 'xray') 'sourceProfileCore': core,
        'protocols': ['vless'],
      },
  ];
  backend.group['subscriptions'] = [
    {
      'id': 'source',
      'name': 'Provider',
      'remote': true,
      'variants': {
        for (final core in ['xray', 'sing-box', 'mihomo'])
          core: {
            'state': 'ready',
            'count': 1,
            'metadata': {
              'hints': {'check-url-via-proxy': 'https://$core.test/'},
            },
          },
      },
    },
  ];
  return backend;
}

void main() {
  test('native node choices show their own protocol and endpoint', () {
    final server = ServerEntry({
      'id': 'source-mihomo-node~stable',
      'name': 'Germany 2',
      'fullProfile': true,
      'profileNode': true,
      'sourceProfileCore': 'mihomo',
      'protocol': 'hysteria2',
      'protocols': ['vless', 'hysteria2'],
      'address': 'example.test',
      'port': 443,
      'network': 'hysteria',
      'security': 'tls',
    });
    expect(server.protocol, 'Hysteria2');
    expect(server.details, 'example.test:443 · QUIC / UDP · tls');
    expect(server.search, contains('hysteria2'));
  });
  test('failed refresh reloads authoritative per-core diagnostics', () async {
    final c = SvoiController(variantsBackend(RefreshFailureBackend()));
    await c.initialize();
    c.connection.value = {'core': 'mihomo', 'state': 'stopped'};
    await c.refreshSource('source');
    expect(c.servers.value.single.id, 'mihomo');
    expect(
      c.sourceIssue(c.subscriptions.value.single),
      contains('mihomo failed'),
    );
    expect(
      c.sourceIssue(c.subscriptions.value.single),
      contains('сохранённая копия'),
    );
    await c.close();
  });
  test('returning to a profile restores its own selection', () async {
    final backend = variantsBackend();
    (backend.group['servers'] as List).add({
      'id': 'second',
      'name': 'Second',
      'subscriptionCore': 'xray',
      'subscriptionId': 'source',
    });
    final c = SvoiController(backend);
    await c.initialize();
    await c.select('second');
    final original = Map<String, dynamic>.from(backend.group);
    c.group.value = Map<String, dynamic>.from(c.group.value);
    backend.group.clear();
    backend.group.addAll({
      'id': 'another',
      'servers': [
        {'id': 'another-node', 'name': 'Another'},
      ],
    });
    await c.reload();
    expect(c.selected.value, 'another-node');
    c.group.value = Map<String, dynamic>.from(c.group.value);
    backend.group.clear();
    backend.group.addAll(original);
    await c.reload();
    expect(c.selected.value, 'second');
    await c.close();
  });
  test(
    'absent variant metadata does not inherit another core check URL',
    () async {
      final backend = variantsBackend();
      final source = (backend.group['subscriptions'] as List).single as Map;
      source['metadata'] = {
        'hints': {'check-url-via-proxy': 'https://other-core.test/'},
      };
      (source['variants'] as Map)['mihomo'] = {'state': 'ready', 'count': 1};
      final c = SvoiController(backend);
      await c.initialize();
      c.connection.value = {'core': 'mihomo', 'state': 'stopped'};
      expect(c.probeUrlFor(c.servers.value.single), defaultProbeUrl);
      expect(c.subscriptions.value.single['metadata'], source['metadata']);
      await c.close();
    },
  );
  test('core selection projects correct cache and matching metadata', () async {
    final c = SvoiController(variantsBackend());
    await c.initialize();
    expect(c.servers.value.map((s) => s.id), ['xray']);
    await c.select('xray');
    c.connection.value = {'core': 'sing-box', 'state': 'stopped'};
    expect(c.servers.value.map((s) => s.id), ['sing-box']);
    expect(c.selected.value, 'sing-box');
    expect(c.probeUrlFor(c.servers.value.single), 'https://sing-box.test/');
    await c.select('sing-box');
    c.connection.value = {'core': 'mihomo', 'state': 'stopped'};
    expect(c.servers.value.single.id, 'mihomo');
    c.connection.value = {'core': 'xray', 'state': 'stopped'};
    expect(c.selected.value, 'xray');
    c.connection.value = {'core': 'sing-box', 'state': 'stopped'};
    expect(c.selected.value, 'sing-box');
    await c.close();
  });

  test(
    'failed refresh retains native cache and shows stale explanation',
    () async {
      final backend = variantsBackend();
      final source = (backend.group['subscriptions'] as List).single as Map;
      (source['variants'] as Map)['mihomo'] = {
        'state': 'error',
        'count': 1,
        'stale': true,
        'error': 'HTTP 503',
      };
      final c = SvoiController(backend);
      await c.initialize();
      c.connection.value = {'core': 'mihomo', 'state': 'stopped'};
      expect(c.servers.value.single.id, 'mihomo');
      expect(
        c.sourceIssue(c.subscriptions.value.single),
        contains('сохранённая копия'),
      );
      await c.close();
    },
  );

  test(
    'unavailable native format keeps all canonical Xray rows disabled',
    () async {
      final backend = variantsBackend();
      backend.group['servers'] = [
        (backend.group['servers'] as List).first,
        {
          'id': 'uri',
          'name': 'URI',
          'subscriptionId': 'source',
          'subscriptionCore': 'xray',
          'protocol': 'vless',
        },
      ];
      final source = (backend.group['subscriptions'] as List).single as Map;
      (source['variants'] as Map)['sing-box'] = {
        'state': 'unavailable',
        'count': 0,
      };
      final c = SvoiController(backend);
      await c.initialize();
      c.connection.value = {'core': 'sing-box', 'state': 'stopped'};
      expect(c.servers.value.map((s) => s.id), ['xray', 'uri']);
      expect(c.servers.value.every((s) => !s.availableForCore), isTrue);
      expect(c.selected.value, isEmpty);
      expect(c.sourceIssue(c.subscriptions.value.single), isNull);
      expect(
        c.sourceAvailabilityNote(c.subscriptions.value.single),
        contains('нет подходящего варианта'),
      );
      c.connection.value = {'core': 'mihomo', 'state': 'stopped'};
      expect(c.servers.value.map((s) => s.id), ['xray', 'uri']);
      expect(c.servers.value.every((s) => !s.availableForCore), isTrue);
      expect(c.selected.value, isEmpty);
      await c.close();
    },
  );

  test(
    'older unscoped remote nodes do not enable an unavailable native format',
    () async {
      final backend = variantsBackend();
      backend.group['servers'] = [
        {
          'id': 'old-uri',
          'name': 'Old URI',
          'subscriptionId': 'source',
          'protocol': 'vless',
        },
        {'id': 'manual', 'name': 'Manual', 'protocol': 'vless'},
      ];
      final c = SvoiController(backend);
      await c.initialize();
      c.connection.value = {'core': 'sing-box', 'state': 'stopped'};
      expect(
        c.servers.value.singleWhere((s) => s.id == 'old-uri').availableForCore,
        isFalse,
      );
      expect(
        c.servers.value.singleWhere((s) => s.id == 'manual').availableForCore,
        isTrue,
      );
      expect(c.selected.value, 'manual');
      await c.close();
    },
  );

  testWidgets('unavailable core keeps source and disabled rows visible', (
    tester,
  ) async {
    final backend = variantsBackend();
    backend.group['servers'] = [(backend.group['servers'] as List).first];
    final c = SvoiController(backend);
    await c.initialize();
    c.connection.value = {'core': 'mihomo', 'state': 'stopped'};
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: DesktopWorkspace(c: c)),
      ),
    );
    expect(find.byType(DesktopLibrary), findsOneWidget);
    expect(find.byType(ImportWelcome), findsNothing);
    expect(find.byType(DesktopServerRow), findsOneWidget);
    expect(
      tester
          .widget<DesktopServerRow>(find.byType(DesktopServerRow))
          .server
          .availableForCore,
      isFalse,
    );
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('select-server-xray')))
          .onTap,
      isNull,
    );
    expect(find.textContaining('Provider'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await c.close();
  });

  test(
    'source identity and canonical metadata never change with core',
    () async {
      final backend = variantsBackend();
      final source = (backend.group['subscriptions'] as List).single as Map;
      source['metadata'] = {'title': 'Canonical provider', 'used': 42};
      source['report'] = {
        'warnings': ['canonical'],
      };
      for (final variant in (source['variants'] as Map).values) {
        (variant as Map)['metadata'] = {'title': 'Different variant title'};
        variant['report'] = {
          'warnings': ['variant'],
        };
      }
      final c = SvoiController(backend);
      await c.initialize();
      for (final core in ['xray', 'sing-box', 'mihomo', 'xray']) {
        c.connection.value = {'core': core, 'state': 'stopped'};
        expect(c.subscriptions.value.single['id'], 'source');
        expect(c.subscriptions.value.single['name'], 'Provider');
        expect(c.subscriptions.value.single['metadata'], source['metadata']);
        expect(c.subscriptions.value.single['report'], source['report']);
        expect(c.servers.value.single.availableForCore, isTrue);
      }
      await c.close();
    },
  );

  test(
    'unavailable placeholders cannot select, connect, probe or export config',
    () async {
      final backend = variantsBackend(
        RecordingVariantsBackend(),
      ) as RecordingVariantsBackend;
      backend.group['servers'] = [(backend.group['servers'] as List).first];
      final source = (backend.group['subscriptions'] as List).single as Map;
      (source['variants'] as Map)['mihomo'] = {
        'state': 'unavailable',
        'count': 0,
        'error': 'Expected format unavailable',
      };
      final c = SvoiController(backend);
      await c.initialize();
      await c.select('xray');
      final previous = c.servers.value.single;
      c.connection.value = {
        'core': 'mihomo',
        'state': 'stopped',
        'available': true,
      };
      final row = c.servers.value.single;
      expect(row.id, 'xray');
      expect(row.availableForCore, isFalse);
      expect(c.selected.value, isEmpty);
      expect(c.subscriptions.value.single['coreUnavailable'], isTrue);
      expect(c.sourceIssue(c.subscriptions.value.single), isNull);
      expect(
        c.sourceAvailabilityNote(c.subscriptions.value.single),
        isNotEmpty,
      );
      backend.requests.clear();
      await c.select(row.id);
      await c.probe([row, previous]);
      expect(await c.config(row), isEmpty);
      expect(await c.config(previous), isEmpty);
      c.selected.value =
          row.id; // Even direct notifier mutation cannot bypass guard.
      await c.toggleConnection();
      expect(backend.requests.where((p) => p != 'connection'), isEmpty);
      expect(c.message.value, isEmpty);
      expect(c.connectionIssue.value, isEmpty);
      expect(c.probes[row.id]?.value.checkedAt, isNull);
      c.connection.value = {'core': 'xray', 'state': 'stopped'};
      expect(c.selected.value, 'xray');
      await c.close();
    },
  );

  test(
    'per-core selection survives temporary unavailable projection',
    () async {
      final backend = variantsBackend();
      final c = SvoiController(backend);
      await c.initialize();
      c.connection.value = {'core': 'mihomo', 'state': 'stopped'};
      await c.select('mihomo');
      final saved = List<dynamic>.from(backend.group['servers'] as List);
      backend.group['servers'] = saved
          .where((s) => s['id'] != 'mihomo')
          .toList();
      await c.reload();
      expect(c.selected.value, isEmpty);
      c.connection.value = {'core': 'xray', 'state': 'stopped'};
      backend.group['servers'] = saved;
      await c.reload();
      c.connection.value = {'core': 'mihomo', 'state': 'stopped'};
      expect(c.selected.value, 'mihomo');
      await c.close();
    },
  );

  test('subscription order persists, survives core changes and appends new sources', () async {
    final dir = await Directory.systemTemp.createTemp(
      'svoi-subscription-order-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final session = File('${dir.path}/session.json');
    final backend = variantsBackend();
    backend.group['subscriptions'] = <Map<String, dynamic>>[
      for (final source in backend.group['subscriptions'] as List)
        Map<String, dynamic>.from(source),
      {'id': 'second', 'name': 'Second'},
      {'id': 'third', 'name': 'Third'},
    ];
    final c = SvoiController(backend, sessionFile: session);
    await c.initialize();
    await c.moveSubscription('third', 'source');
    expect(c.subscriptions.value.map((s) => s['id']), [
      'third',
      'source',
      'second',
    ]);
    c.connection.value = {'core': 'mihomo', 'state': 'stopped'};
    expect(c.subscriptions.value.map((s) => s['id']), [
      'third',
      'source',
      'second',
    ]);
    await c.moveSubscription('third', 'second', after: true);
    expect(c.subscriptions.value.map((s) => s['id']), [
      'source',
      'second',
      'third',
    ]);
    await c.moveSubscription('second', 'source');
    await c.close();
    final restored = SvoiController(backend, sessionFile: session);
    await restored.initialize();
    expect(restored.subscriptions.value.map((s) => s['id']), [
      'second',
      'source',
      'third',
    ]);
    (backend.group['subscriptions'] as List)
      ..removeWhere((s) => s['id'] == 'source')
      ..add({'id': 'new', 'name': 'New'});
    await restored.reload();
    expect(restored.subscriptions.value.map((s) => s['id']), [
      'second',
      'third',
      'new',
    ]);
    await restored.moveSubscription('missing', 'third');
    expect(restored.subscriptions.value.map((s) => s['id']), [
      'second',
      'third',
      'new',
    ]);
    await restored.close();
  });
}
