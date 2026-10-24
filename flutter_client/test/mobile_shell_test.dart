import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

void main() {
  testWidgets('mobile onboarding is visible without scrolling at 360 pixels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = DemoBackend();
    api.group['servers'] = <dynamic>[];
    api.group['subscriptions'] = <dynamic>[];
    final c = SvoiController(api);
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: MobileShell(c: c),
      ),
    );
    expect(find.text('Начните с подписки'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Добавить подписку').hitTestable(),
      findsOneWidget,
    );
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Добавить подписку'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(FilledButton, 'Добавить').hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
  testWidgets('mobile navigation and large server list fit a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = SvoiController(DemoBackend());
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: MobileShell(c: c),
      ),
    );
    await tester.tap(find.text('Серверы').last);
    await tester.pumpAndSettle();
    expect(find.byType(ListTile).evaluate().length, lessThan(20));
    await tester.enterText(find.byType(TextField), 'Server does not exist');
    await tester.pump();
    expect(find.byType(ListTile), findsNothing);
    await tester.tap(find.text('Профиль').last);
    await tester.pumpAndSettle();
    expect(find.text('Скопировать код переноса'), findsOneWidget);
    await tester.tap(find.text('Серверы').last);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(TextField, 'Server does not exist'),
      findsOneWidget,
    );
    expect(find.text('По запросу ничего не найдено'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Сбросить поиск'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsWidgets);
    await tester.tap(find.text('Настройки').last);
    await tester.pumpAndSettle();
    expect(find.text('Приложения через VPN'), findsOneWidget);
    expect(find.text('Запускать SVOI при входе в Windows'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
  testWidgets('empty active profile points to saved profiles with counts', (
    tester,
  ) async {
    final api = DemoBackend();
    api.group['servers'] = <dynamic>[];
    api.group['subscriptions'] = <dynamic>[];
    final c = SvoiController(api);
    await c.initialize();
    c.sessions.value = [
      ...c.sessions.value,
      {
        'token': 'imported',
        'name': 'Моя сеть',
        'serverCount': 20,
        'subscriptionCount': 1,
        'sources': 'Тестовая подписка',
      },
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: MobileShell(c: c),
      ),
    );
    expect(find.text('В этом профиле нет серверов'), findsOneWidget);
    await tester.tap(find.text('Выбрать сохранённый профиль'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Серверов: 20 · подписок: 1'), findsOneWidget);
    expect(find.textContaining('Активный профиль'), findsOneWidget);
    final active = tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'Профиль · 1'),
    );
    expect(active.onTap, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
}
