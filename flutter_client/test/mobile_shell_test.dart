import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide group;
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class MobileFeaturesBackend extends DemoBackend {
  Map<String, dynamic>? savedIdentity;
  @override
  bool get mobile => true;
  @override
  int get probeConcurrency => 2;
  MobileFeaturesBackend() {
    group['servers'] = (group['servers'] as List).take(3).toList();
    group['identity'] = {
      'hwid': 'original-id',
      'os': 'Android',
      'model': 'Shared device',
      'locale': 'ru-RU',
      'userAgent': 'SVOI-Test',
    };
  }
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path == 'connection/ip') return {'ip': '203.0.113.7', 'via': 'network'};
    if (path == 'connection') return {'state': 'stopped', 'available': true};
    if (path.endsWith('/probe')) {
      if (path.contains('/0/')) throw ApiException('Нет ответа за 4 секунды');
      return {'latency': 42};
    }
    if (path == 'identity') {
      savedIdentity = Map<String, dynamic>.from((body as Map)['identity']);
      group['identity'] = savedIdentity;
      return group;
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
    'mobile themes fit narrow screens and preserve the VPN controller',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = SvoiController(MobileFeaturesBackend());
      await c.initialize();
      final store = AppearanceStore();
      await tester.pumpWidget(
        AppearanceScope(
          store: store,
          child: ValueListenableBuilder<AppAppearance>(
            valueListenable: store,
            builder: (context, choice, _) => MaterialApp(
              theme: mobileTheme(
                svoiTheme(palette: SvoiColors.forAppearance(choice)),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.6)),
                child: child!,
              ),
              home: MobileShell(c: c),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final shellState = tester.state(find.byType(MobileShell));
      final selected = c.selected.value;
      for (final choice in AppAppearance.values) {
        await store.select(choice);
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(MobileShell)), same(shellState));
        expect(c.selected.value, selected);
        expect(find.byKey(const ValueKey('mobile-power')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: choice.name);
      }
      await tester.tap(find.text('Настройки').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Оформление'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('theme-dark')), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-halloween')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
      store.dispose();
    },
  );

  testWidgets(
    'mobile connection and subscription fit above the fold and adapt to large text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = SvoiController(MobileFeaturesBackend());
      await c.initialize();
      Widget app(double scale) => MaterialApp(
        theme: svoiTheme(),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(360, 740),
            textScaler: TextScaler.linear(scale),
          ),
          child: MobileShell(c: c),
        ),
      );
      await tester.pumpWidget(app(1));
      expect(
        find.byKey(const ValueKey('mobile-power')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.text('Демонстрационная подписка').hitTestable(),
        findsOneWidget,
      );
      expect(find.text('Android · экспериментальная сборка'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('IP · 203.0.113.7'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(app(1.6));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      c.connection.value = {
        'state': 'running',
        'available': true,
        'checked': false,
        'error': 'Контрольный запрос не прошёл',
      };
      await tester.pumpAndSettle();
      expect(find.text('Отключить VPN'), findsOneWidget);
      expect(find.text('Контрольный запрос не прошёл'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
  testWidgets(
    'mobile probes display results and failure does not prevent selection',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = SvoiController(MobileFeaturesBackend());
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: MobileShell(c: c),
        ),
      );
      await tester.tap(find.text('Серверы').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Проверить пинг'));
      await tester.pumpAndSettle();
      expect(find.text('42 мс'), findsNWidgets(2));
      expect(find.text('Нет ответа'), findsOneWidget);
      expect(find.textContaining('3 из 3'), findsOneWidget);
      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      expect(c.selected.value, '0');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
  testWidgets('mobile probe settings use the device concurrency limit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = SvoiController(MobileFeaturesBackend());
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: mobileTheme(svoiTheme()),
        home: MobileShell(c: c),
      ),
    );
    await tester.tap(find.text('Настройки').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Проверка задержки'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('probe-url')), findsOneWidget);
    expect(find.byKey(const ValueKey('probe-parallel-2')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
  testWidgets(
    'mobile identity edits and header opt-out are saved to the active profile',
    (tester) async {
      final api = MobileFeaturesBackend();
      final c = SvoiController(api);
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: MobileShell(c: c),
        ),
      );
      await tester.tap(find.text('Настройки').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('HWID и данные устройства'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'shared-test-id',
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Сохранить'));
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(api.savedIdentity?['hwid'], 'shared-test-id');
      expect(api.savedIdentity?['os'], 'Android');
      expect(api.savedIdentity?['omitDeviceHeaders'], true);
      expect(c.group.value['identity']['hwid'], 'shared-test-id');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
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
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<NavigationBar>(find.byType(NavigationBar))
          .destinations
          .length,
      4,
    );
    await tester.tap(find.text('Настройки').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Общий профиль'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Скопировать код переноса'), 200);
    expect(find.text('Скопировать код переноса'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
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
