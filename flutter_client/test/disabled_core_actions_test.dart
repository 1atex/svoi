import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class DisabledCoreBackend extends DemoBackend {
  DisabledCoreBackend() {
    this.group['subscriptions'] = <Map<String, dynamic>>[];
    this.group['servers'] = [
      {'id': 'ready', 'name': 'Доступный узел', 'protocol': 'vless'},
      {
        'id': 'missing',
        'name': 'Недоступный узел',
        'protocol': 'vless',
        'coreUnavailable': true,
      },
    ];
  }

  Map<String, dynamic> state = {
    'available': true,
    'state': 'stopped',
    'core': 'xray',
  };
  final calls = <String>[];
  final bodies = <String, List<Map<String, dynamic>>>{};

  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    calls.add('$method $path');
    if (body is Map) {
      bodies.putIfAbsent(path, () => []).add(Map<String, dynamic>.from(body));
    }
    if (path.startsWith('connection')) return Map.from(state);
    if (path == 'tools/speed/start') return {'id': 'test'};
    if (path.startsWith('tools/speed/status')) {
      return {'id': 'test', 'state': 'done', 'results': <dynamic>[]};
    }
    if (path == 'tools/speed/cancel') return {};
    if (path == 'tools/site') {
      return {
        'steps': [
          {'ok': true},
        ],
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

Map<String, dynamic> disabledScenario() => {
  'id': 'disabled-scene',
  'name': 'Сохранённый сценарий',
  'kind': 'vpn',
  'groupId': 'demo',
  'serverId': 'missing',
  'serverName': 'Недоступный узел',
  'mode': 'local',
  'routing': {'mode': 'all', 'processes': <String>[]},
  'directDomains': <String>[],
};

Iterable<Map<String, dynamic>> trayItems(List<dynamic> items) sync* {
  for (final raw in items) {
    final item = Map<String, dynamic>.from(raw as Map);
    yield item;
    if (item['children'] is List) yield* trayItems(item['children'] as List);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'unavailable scenario keeps the live connection and saved scenario',
    () async {
      final backend = DisabledCoreBackend();
      final c = SvoiController(backend);
      await c.initialize();
      c.scenarios.value = [disabledScenario()];
      backend.state = {
        'available': true,
        'state': 'running',
        'core': 'xray',
        'serverId': 'ready',
        'mode': 'local',
      };
      c.connection.value = Map.from(backend.state);
      final selected = c.selected.value;
      backend.calls.clear();
      await c.applyScenario('disabled-scene');
      expect(c.connection.value['state'], 'running');
      expect(c.selected.value, selected);
      expect(c.scenarios.value.single['id'], 'disabled-scene');
      expect(backend.calls, isNot(contains('POST connection/stop')));
      expect(backend.calls, isNot(contains('POST connection/start')));
      expect(backend.calls, isNot(contains('PUT settings')));
      expect(c.connectionIssue.value, contains('недоступен'));
      await c.close();
    },
  );

  test(
    'tray disables placeholder connect, selection and saved scenario',
    () async {
      final backend = DisabledCoreBackend();
      final c = SvoiController(backend);
      await c.initialize();
      c.scenarios.value = [disabledScenario()];
      c.selected.value = 'missing';
      final items = trayItems(trayState(c)['items'] as List).toList();
      for (final id in [
        'connect',
        'server:missing',
        'scenario:disabled-scene',
      ]) {
        expect(items.singleWhere((item) => item['id'] == id)['enabled'], false);
      }
      c.selected.value = 'ready';
      final bridge = TrayBridge(c, open: (_) async {});
      await bridge.handle('server:missing');
      expect(c.selected.value, 'ready');
      bridge.dispose();
      await c.close();
    },
  );

  testWidgets(
    'speed disables placeholders and excludes a remembered selection',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = DisabledCoreBackend();
      final c = SvoiController(backend);
      await c.initialize();
      c.speedView.value = {
        'groupId': 'demo',
        'selected': ['missing'],
        'data': <String, dynamic>{},
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: SpeedTools(c: c)),
        ),
      );
      await tester.pumpAndSettle();
      final unavailable = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('speed-server-missing')),
      );
      expect(unavailable.onChanged, isNull);
      expect(unavailable.value, false);
      await tester.ensureVisible(find.text('Сравнить скорость'));
      await tester.tap(find.text('Сравнить скорость'));
      await tester.pumpAndSettle();
      expect(
        backend.bodies['tools/speed/start']!.single['serverIds'],
        isNot(contains('missing')),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );

  testWidgets('site comparison does not offer or probe a placeholder', (
    tester,
  ) async {
    final backend = DisabledCoreBackend();
    final c = SvoiController(backend);
    await c.initialize();
    c.selected.value = 'missing';
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: SiteCheckPanel(c: c)),
      ),
    );
    await tester.pumpAndSettle();
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(dropdown.items!.any((item) => item.value == 'missing'), false);
    await tester.enterText(
      find.byKey(const ValueKey('site-url')),
      'https://example.com',
    );
    await tester.tap(find.text('Проверить сайт'));
    await tester.pumpAndSettle();
    final requests = backend.bodies['tools/site']!;
    expect(requests.any((body) => body['serverId'] == 'missing'), false);
    expect(requests.any((body) => body['route'] == 'profile'), false);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
}
