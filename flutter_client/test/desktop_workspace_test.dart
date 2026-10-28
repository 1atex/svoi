import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import 'connection_ui_test.dart' show ConnectionBackend;

void main() {
  testWidgets(
    'compact connection stays visible and switches only on confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = ConnectionBackend();
      final c = SvoiController(backend);
      await c.initialize();
      c.mode.value = Platform.isMacOS ? 'system' : 'tun';
      await c.toggleConnection();
      final active = c.selected.value;
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: SvoiShell(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('desktop-server-search')),
        '1000',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select-server-999')));
      await tester.pumpAndSettle();
      expect(backend.state['serverId'], active);
      expect(find.text('Переключиться').hitTestable(), findsOneWidget);
      expect(find.text('Отключить VPN').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Переключиться'));
      await tester.pumpAndSettle();
      expect(backend.state['serverId'], '999');
      expect(find.text('Переключиться'), findsNothing);
      await tester.tap(find.text('Отключить VPN'));
      await tester.pumpAndSettle();
      expect(backend.state['state'], 'stopped');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );

  testWidgets('subscription collapse and search preserve access to results', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = SvoiController(ConnectionBackend());
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: SvoiShell(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Демонстрационная подписка'));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopServerRow), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('desktop-server-search')),
      '1000',
    );
    await tester.pumpAndSettle();
    expect(find.byType(DesktopServerRow), findsOneWidget);
    expect(find.text('1 из 1000 серверов'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('connection-power')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });

  testWidgets('large text and connection errors keep actions reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = SvoiController(ConnectionBackend());
    await c.initialize();
    c.connection.value = {
      'available': true,
      'state': 'running',
      'serverId': c.selected.value,
      'error': 'timeout',
    };
    c.mode.value = Platform.isMacOS ? 'system' : 'tun';
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: SvoiShell(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Отключить VPN').hitTestable(), findsOneWidget);
    expect(find.text('Что делать').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Что делать'));
    await tester.pumpAndSettle();
    expect(find.textContaining('VPN остаётся включён'), findsOneWidget);
    await tester.tap(find.text('Закрыть').last);
    await tester.pumpAndSettle();
    expect(find.text('Добавить подписку').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
}
