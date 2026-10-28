import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

void main() {
  testWidgets('server filters show the visible count and reset correctly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = SvoiController(DemoBackend());
    await c.initialize();
    await c.toggleFavorite('1');
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: ServerPage(c: c)),
      ),
    );
    await tester.tap(find.widgetWithText(FilterChip, 'Избранные'));
    await tester.pumpAndSettle();
    expect(find.text('1 из 1000 серверов'), findsOneWidget);
    expect(find.byType(ServerRow), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('0 из 1000 серверов'), findsOneWidget);
    await tester.tap(find.text('Сбросить фильтры'));
    await tester.pumpAndSettle();
    expect(find.text('1000 серверов'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
  testWidgets('1000 servers are lazy, searchable and selectable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = SvoiController(DemoBackend());
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: SvoiShell(controller: controller, demo: true),
      ),
    );
    await tester.tap(find.text('Серверы').first);
    await tester.pumpAndSettle();
    expect(find.text('1000 серверов'), findsOneWidget);
    final mounted = find.byType(DesktopServerRow).evaluate().length;
    expect(mounted, lessThan(20));
    expect(mounted, greaterThan(0));
    expect(find.byType(CountryMark), findsWidgets);
    await tester.enterText(find.byType(TextField), '1000');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopServerRow), findsOneWidget);
    expect(find.text('Франция · 1000'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('select-server-999')));
    await tester.pump();
    expect(controller.selected.value, '999');
    await tester.tap(find.byTooltip('Действия сервера'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Конфигурация'));
    await tester.pumpAndSettle();
    expect(find.text('Исходная'), findsOneWidget);
    expect(find.text('Для подключения'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await controller.close();
  });

  testWidgets('minimum window and settings have no layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = SvoiController(DemoBackend());
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: SvoiShell(controller: controller),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('desktop-tab-5')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Проверка задержки'),
      250,
      scrollable: find
          .descendant(
            of: find.byType(PreferencesPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Проверка задержки'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text(
        Platform.isWindows
            ? 'Обновлять при запуске'
            : 'Обновлять подписки при запуске',
      ),
      300,
      scrollable: find
          .descendant(
            of: find.byType(PreferencesPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      find.text(
        Platform.isWindows
            ? 'Обновлять при запуске'
            : 'Обновлять подписки при запуске',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await controller.close();
  });
}
