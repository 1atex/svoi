import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import 'connection_ui_test.dart' show ConnectionBackend;

class FirstRunBackend extends ConnectionBackend {
  FirstRunBackend() {
    super.group['servers'] = <Map<String, dynamic>>[];
    super.group['subscriptions'] = <Map<String, dynamic>>[];
  }
  String? addedUrl;
  int starts = 0;
  bool failCheck = false;

  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path == 'subscriptions' && method == 'POST') {
      addedUrl = (body as Map)['url'] as String;
      super.group['subscriptions'] = [
        {
          'id': 'source',
          'name': 'Подписка',
          'host': 'example.com',
          'count': 1,
          'remote': true,
        },
      ];
      return {'id': 'source', 'group': super.group};
    }
    if (path.startsWith('subscription/refresh')) {
      super.group['servers'] = [
        {
          'id': 'one',
          'name': 'Finland',
          'countryCode': 'FI',
          'protocol': 'vless',
          'address': 'example.com',
          'port': 443,
          'network': 'tcp',
          'security': 'tls',
        },
      ];
      return {};
    }
    if (path == 'connection/start') starts++;
    if (path == 'connection/check' && failCheck) {
      throw ApiException('Проверка не прошла');
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
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> show(WidgetTester tester, SvoiController c, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: SvoiShell(controller: c),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'first run offers both import paths above the fold and loads a subscription',
    (tester) async {
      final backend = FirstRunBackend();
      final c = SvoiController(backend);
      await c.initialize();
      await show(tester, c, const Size(816, 600));
      expect(find.byKey(const ValueKey('connection-power')), findsNothing);
      for (final key in ['welcome-link', 'welcome-add', 'welcome-import']) {
        final target = find.byKey(ValueKey(key));
        expect(target.hitTestable(), findsOneWidget);
        expect(tester.getBottomRight(target).dy, lessThan(600));
      }
      await tester.tap(find.byKey(const ValueKey('welcome-import')));
      await tester.pumpAndSettle();
      expect(find.text('Из файла'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('код SVOI1'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('welcome-link')),
        'invalid',
      );
      await tester.tap(find.byKey(const ValueKey('welcome-add')));
      await tester.pumpAndSettle();
      expect(backend.addedUrl, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('welcome-link')),
        'https://example.com/sub',
      );
      await tester.tap(find.byKey(const ValueKey('welcome-add')));
      await tester.pumpAndSettle();
      expect(backend.addedUrl, 'https://example.com/sub');
      expect(find.byType(ImportWelcome), findsNothing);
      expect(c.selected.value, 'one');
      expect(
        find.text('Добавить подписку').first.hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );

  testWidgets(
    'populated narrow window still exposes subscription action first',
    (tester) async {
      final c = SvoiController(ConnectionBackend());
      await c.initialize();
      await show(tester, c, const Size(1040, 850));
      final add = find.text('Добавить подписку').first;
      expect(add.hitTestable(), findsOneWidget);
      expect(tester.getCenter(add).dy, lessThan(200));
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );

  test('tray actions respect state, busy guard and pending choices', () async {
    final backend = FirstRunBackend();
    final c = SvoiController(backend);
    await c.initialize();
    final opened = <String>[];
    final bridge = TrayBridge(c, open: (action) async => opened.add(action));
    Map item(String id) => (trayState(c)['items'] as List)
        .whereType<Map>()
        .firstWhere((item) => item['id'] == id);
    expect(item('connect')['enabled'], false);
    await bridge.handle('connect');
    expect(backend.starts, 0);
    await c.importText('https://example.com/sub');
    expect(item('connect')['enabled'], true);
    c.busy.value = true;
    await bridge.handle('connect');
    expect(backend.starts, 0);
    c.busy.value = false;
    await bridge.handle('connect');
    expect(backend.starts, 1);
    expect(item('disconnect')['enabled'], true);
    await bridge.handle('connect');
    expect(backend.starts, 1);
    final nextMode = Platform.isWindows ? 'system' : 'local';
    await bridge.handle('mode:$nextMode');
    expect(c.mode.value, nextMode);
    expect(c.pendingConnectionChoice, true);
    expect(item('apply')['enabled'], true);
    await bridge.handle('apply');
    expect(backend.starts, 2);
    expect(backend.state['mode'], nextMode);
    await bridge.handle('server:deleted');
    expect(c.selected.value, 'one');
    backend.failCheck = true;
    await bridge.handle('check');
    expect(opened.last, 'connection');
    await bridge.handle('disconnect');
    expect(backend.state['state'], 'stopped');
    await bridge.handle('import');
    expect(opened.last, 'import');
    bridge.dispose();
    await c.close();
  });

  testWidgets(
    'tray receives status updates while window is hidden and stops after disposal',
    (tester) async {
      final updates = <Map>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        (call) async {
          if (call.method == 'updateTray') updates.add(call.arguments as Map);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          windowChannel,
          null,
        ),
      );
      final backend = FirstRunBackend();
      final c = SvoiController(backend);
      await c.initialize();
      await c.importText('https://example.com/sub');
      final bridge = TrayBridge(c, open: (_) async {})..attach();
      await tester.pump();
      await bridge.handle('connect');
      await tester.pump();
      expect(updates.last['tooltip'], contains('Подключено'));
      c.visibility(false);
      backend.state = {'available': true, 'state': 'stopped'};
      await tester.pump(const Duration(seconds: 15));
      await tester.pump();
      expect(updates.last['tooltip'], contains('VPN выключен'));
      bridge.dispose();
      final count = updates.length;
      c.mode.value = 'tun';
      await tester.pump();
      expect(updates.length, count);
      await c.close();
    },
  );
}
