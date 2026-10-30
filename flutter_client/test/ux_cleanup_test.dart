import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

void main() {
  test(
    'subscription order survives refresh and restarting the controller',
    () async {
      final dir = await Directory.systemTemp.createTemp('svoi-order-');
      addTearDown(() => dir.delete(recursive: true));
      final api = DemoBackend();
      api.group['subscriptions'] = [
        {'id': 'a', 'name': 'First'},
        {'id': 'b', 'name': 'Second'},
        {'id': 'c', 'name': 'Third'},
      ];
      final file = File('${dir.path}/session.json');
      final c = SvoiController(api, sessionFile: file);
      await c.initialize();
      await c.moveSubscription('c', 'a');
      await c.reload();
      expect(c.subscriptions.value.map((s) => s['id']), ['c', 'a', 'b']);
      await c.close();
      final restored = SvoiController(api, sessionFile: file);
      await restored.initialize();
      expect(restored.subscriptions.value.map((s) => s['id']), ['c', 'a', 'b']);
      await restored.close();
    },
  );
  testWidgets(
    'settings start with sections and detail pages return to the menu',
    (tester) async {
      final c = SvoiController(DemoBackend());
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: PreferencesPage(c: c)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          Platform.isWindows
              ? 'Обновлять при запуске'
              : 'Обновлять подписки при запуске',
        ),
        findsNothing,
      );
      await tester.tap(
        find.byKey(
          ValueKey(
            Platform.isWindows
                ? 'settings-section-Автоматизация'
                : 'settings-section-Подписки',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          Platform.isWindows
              ? 'Обновлять при запуске'
              : 'Обновлять подписки при запуске',
        ),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.text(
          Platform.isWindows
              ? 'Обновлять при запуске'
              : 'Обновлять подписки при запуске',
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
  testWidgets(
    'favorite servers stay in their subscription without a duplicate section',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = DemoBackend();
      api.group['servers'] = (api.group['servers'] as List).take(1).toList();
      final c = SvoiController(api);
      await c.initialize();
      await c.toggleFavorite('0');
      c.connection.value = {'state': 'stopped', 'available': true};
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: DesktopWorkspace(c: c)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Избранные и недавние'), findsNothing);
      expect(find.byType(DesktopServerRow), findsOneWidget);
      expect(find.text('VPN выключен'), findsNothing);
      expect(find.text('Выберите сервер и подключитесь'), findsNothing);
      expect(find.byKey(const ValueKey('connection-power')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
}
