import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import 'network_tools_test.dart' show NetworkBackend;
import 'subscription_metadata_test.dart' show metadataSource;

void main() {
  testWidgets(
    'DNS is reachable from the main navigation without scrolling settings',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = SvoiController(NetworkBackend());
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: SvoiShell(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('DNS').hitTestable(), findsOneWidget);
      await tester.tap(find.text('DNS'));
      await tester.pumpAndSettle();
      expect(find.text('Подобрать DNS'), findsOneWidget);
      expect(find.text('Сравнить DNS').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Подключение'));
      await tester.pumpAndSettle();
      expect(find.byType(DnsTools), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
  testWidgets(
    'header actions do not collapse servers; recommendations are not an active timer',
    (tester) async {
      tester.view.physicalSize = const Size(420, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var toggles = 0, refreshes = 0, probes = 0, details = 0;
      final source = {
        ...metadataSource,
        'remote': true,
        'report': {'fetchedAt': '2026-10-26T15:30:00Z'},
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SubscriptionHeader(
                name: 'Моя подписка',
                source: source,
                count: 20,
                collapsed: false,
                onToggle: () => toggles++,
                onRefresh: () => refreshes++,
                onProbe: () => probes++,
                onDetails: () => details++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Интервал провайдера: 1 ч'), findsOneWidget);
      expect(find.textContaining('Автообновление'), findsNothing);
      await tester.tap(find.byTooltip('Обновить Моя подписка'));
      await tester.tap(find.byTooltip('Проверить задержку подписки'));
      await tester.tap(
        find.byTooltip(
          'Маршрутизация Happ не применена. Открыть сведения о подписке',
        ),
      );
      expect([toggles, refreshes, probes, details], [0, 1, 1, 1]);
      await tester.tap(find.text('Моя подписка'));
      expect(toggles, 1);
    },
  );
  testWidgets('unlimited quota is static and exhausted quota is clamped', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: const [
              SubscriptionTrafficBar(
                metadata: {'upload': 0, 'download': 1024, 'total': 0},
              ),
              SubscriptionTrafficBar(metadata: {'download': 120, 'total': 100}),
              SubscriptionTrafficBar(metadata: {'total': 100}),
            ],
          ),
        ),
      ),
    );
    final values = tester
        .widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        )
        .map((bar) => bar.value)
        .toList();
    expect(values, [0.0, 1.0, 0.0]);
    expect(find.text('1.0 КиБ / ∞'), findsOneWidget);
    expect(find.text('Расход не указан / 100 Б'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
