import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import 'responsive_actions_test.dart' show ActionBackend;

class ToolsBackend extends ActionBackend {
  final calls = <String>[];
  final siteRequests = <RequestCancellation>[];
  final sites = <String, Completer<Map<String, dynamic>>>{};
  Map<String, dynamic> zapret = {
    'strategy': 'general.bat',
    'strategies': ['general.bat'],
  };
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    calls.add(path);
    if (path == 'zapret') return zapret;
    if (path == 'zapret/start') return {'running': true};
    if (path == 'tools/site') {
      siteRequests.add(cancellation!);
      final result = Completer<Map<String, dynamic>>();
      sites[(body as Map)['route']] = result;
      return result.future;
    }
    if (path == 'connection/start') {
      final response = await super.request(
        path,
        method: method,
        body: body,
        cancellation: cancellation,
      );
      state = {
        ...response,
        'directDomains': demoSettings['directDomains'],
        'routing': demoSettings['routing'],
      };
      return state;
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
  test('scenarios persist isolated by profile, apply once and retain the running connection on second application', () async {
    final dir = await Directory.systemTemp.createTemp('svoi-scenario-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/session.json');
    final api = ToolsBackend();
    final c = SvoiController(api, sessionFile: file);
    await c.initialize();
    await c.settings({
      'directDomains': ['example.com'],
    });
    await c.setMode('local');
    await c.select('2');
    await c.saveScenario('Работа', 'vpn');
    final scene = c.currentScenarios.single;
    expect(scene['serverId'], '2');
    await c.settings({'directDomains': []});
    await c.select('1');
    await c.applyScenario(scene['id']);
    expect(c.selected.value, '2');
    expect(c.preferences.value['directDomains'], ['example.com']);
    expect(api.starts, 1);
    await c.applyScenario(scene['id']);
    expect(api.starts, 1);
    expect(c.connection.value['state'], 'running');
    c.group.value = {...c.group.value, 'id': 'other'};
    expect(c.currentScenarios, isEmpty);
    await c.close();
    final restored = SvoiController(ToolsBackend(), sessionFile: file);
    await restored.initialize();
    expect(restored.currentScenarios.single['name'], 'Работа');
    await restored.close();
  });
  test(
    'invalid server and removed zapret strategy never stop a working VPN',
    () async {
      final api = ToolsBackend();
      final c = SvoiController(api);
      await c.initialize();
      await c.toggleConnection();
      await c.saveScenario('Сервер', 'vpn');
      final id = c.currentScenarios.single['id'];
      c.servers.value = [];
      await c.applyScenario(id);
      expect(c.connection.value['state'], 'running');
      expect(c.connectionIssue.value, contains('удалён'));
      await c.saveScenario('Видео', 'zapret');
      api.zapret['strategies'] = [];
      api.calls.clear();
      await c.applyScenario(c.currentScenarios.last['id']);
      expect(api.calls, isNot(contains('connection/stop')));
      expect(api.calls, isNot(contains('zapret/start')));
      expect(c.connectionIssue.value, contains('не найдена'));
      await c.close();
    },
  );
  test(
    'zapret scenario stops VPN before starting its saved strategy',
    () async {
      final api = ToolsBackend();
      final c = SvoiController(api);
      await c.initialize();
      await c.toggleConnection();
      await c.saveScenario('Видео', 'zapret');
      api.calls.clear();
      await c.applyScenario(c.currentScenarios.single['id']);
      expect(
        api.calls.indexOf('connection/stop'),
        lessThan(api.calls.indexOf('zapret/start')),
      );
      expect(c.connection.value['state'], 'stopped');
      final tray = trayState(c);
      final menu = (tray['items'] as List).whereType<Map>().firstWhere(
        (m) => m['label'] == 'Сценарии',
      );
      expect((menu['children'] as List).first['label'], 'Видео');
      await c.close();
    },
  );
  testWidgets('scenario validation retains dialog and input', (tester) async {
    final c = SvoiController(ToolsBackend());
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => saveScenarioDialog(context, c),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Введите название сценария.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('scenario-name')),
      'Работа',
    );
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(c.currentScenarios.single['name'], 'Работа');
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
  testWidgets(
    'site results distinguish denial and clear when the address changes',
    (tester) async {
      final api = ToolsBackend();
      final c = SvoiController(api);
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: SiteCheckPanel(c: c)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('site-url')),
        'example.com',
      );
      await tester.tap(find.text('Проверить сайт'));
      await tester.pump();
      api.sites['direct']!.complete({
        'steps': [
          {
            'name': 'HTTPS',
            'ok': true,
            'responded': true,
            'ms': 20,
            'detail': 'HTTP 204',
          },
        ],
      });
      api.sites['profile']!.complete({
        'steps': [
          {
            'name': 'HTTPS',
            'ok': false,
            'responded': true,
            'ms': 30,
            'detail': 'HTTP 403',
          },
        ],
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('Сеть до сайта доступна'), findsOneWidget);
      expect(find.text('Добавить сайт в исключения'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('site-url')),
        'another.com',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('HTTP 403'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
  testWidgets('site checks cancel in tray and ignore their late result', (
    tester,
  ) async {
    final api = ToolsBackend();
    final c = SvoiController(api);
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: SiteCheckPanel(c: c)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('site-url')),
      'example.com',
    );
    await tester.tap(find.text('Проверить сайт'));
    await tester.pump();
    c.visibility(false);
    await tester.pump();
    expect(api.siteRequests.every((r) => r.cancelled), true);
    for (final r in api.sites.values) {
      r.complete({
        'steps': [
          {'name': 'HTTPS', 'ok': true, 'ms': 42, 'detail': 'LATE'},
        ],
      });
    }
    await tester.pumpAndSettle();
    expect(find.text('LATE'), findsNothing);
    expect(find.text('Остановить'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
  testWidgets('compact error state leaves two complete server rows visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = SvoiController(ToolsBackend());
    await c.initialize();
    c.refreshErrors.value = {
      'demo': 'Провайдер отклонил подписку. Проверьте ссылку и срок действия в личном кабинете.',
    };
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: SvoiShell(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byKey(const PageStorageKey('desktop-library'));
    final rows = find.byType(DesktopServerRow);
    expect(rows.evaluate().length, greaterThanOrEqualTo(2));
    expect(
      tester.getBottomRight(rows.at(1)).dy,
      lessThanOrEqualTo(tester.getBottomRight(list).dy),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
}
