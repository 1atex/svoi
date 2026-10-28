import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide group;
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class SpeedBackend extends DemoBackend {
  SpeedBackend() {
    group['servers'] = (group['servers'] as List).take(4).toList();
  }
  final calls = <String>[];
  List<String> chosen = [];
  bool complete = false,
      cancelled = false,
      fail = false,
      shortProfile = false,
      shortBaseline = false;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path.startsWith('tools/speed/')) {
      calls.add(path);
      if (path.endsWith('/start')) {
        chosen = List<String>.from((body as Map)['serverIds'] as List);
        return {'id': 'test'};
      }
      if (path.endsWith('/cancel')) {
        cancelled = true;
        return {};
      }
      return {
        'id': 'test',
        'state': cancelled
            ? 'cancelled'
            : complete
            ? 'done'
            : 'running',
        'results': [
          {
            'serverId': '',
            'name': 'Без VPN',
            'protocol': 'Напрямую',
            'state': 'done',
            'downloadMbps': 40.0,
            'uploadMbps': 20.0,
            'downloadSeconds': shortBaseline ? 1.2 : 4.0,
            'uploadSeconds': 4.0,
            'downloadBytes': shortBaseline ? 6000000 : 20000000,
            'uploadBytes': 10000000,
            'downloadCapped': shortBaseline,
            'downloadFullWindow': !shortBaseline,
            'uploadFullWindow': true,
            'downloadSamples': [
              for (var i = 0; i < 4; i++)
                {
                  'seconds': i + 1.0,
                  'mbps': [18.0, 41.0, 51.0, 50.0][i],
                },
            ],
            'uploadSamples': [
              for (var i = 0; i < 4; i++)
                {
                  'seconds': i + 1.0,
                  'mbps': [12.0, 23.0, 26.0, 19.0][i],
                },
            ],
            'latencyMs': 20.0,
          },
          {
            'serverId': '0',
            'name': 'NL Нидерланды · 1',
            'protocol': 'VLESS',
            'state': cancelled
                ? 'cancelled'
                : fail
                ? 'error'
                : complete
                ? 'done'
                : 'running',
            'phase': 'download',
            'error': fail ? 'Сервер не ответил. Выберите другой сервер.' : '',
            'downloadMbps': fail
                ? null
                : shortProfile
                ? 210.0
                : 32.0,
            'downloadSeconds': shortProfile ? 1.28 : 4.0,
            'uploadSeconds': 4.0,
            'downloadBytes': shortProfile ? 33554432 : 16000000,
            'uploadBytes': 10000000,
            'downloadCapped': shortProfile,
            'downloadFullWindow': !shortProfile && !fail,
            'uploadFullWindow': !fail,
            'downloadSamples': fail
                ? []
                : [
                    for (var i = 0; i < 4; i++)
                      {
                        'seconds': shortProfile ? (i + 1) * 0.32 : i + 1.0,
                        'mbps': shortProfile
                            ? [125.0, 210.0, 260.0, 245.0][i]
                            : [11.0, 36.0, 42.0, 39.0][i],
                      },
                  ],
            'uploadSamples': fail
                ? []
                : [
                    for (var i = 0; i < 4; i++)
                      {
                        'seconds': i + 1.0,
                        'mbps': [12.0, 23.0, 26.0, 19.0][i],
                      },
                  ],
            'warning': shortProfile
                ? 'Короткая выборка загрузки: скорость ориентировочная.'
                : '',
            'uploadMbps': complete && !fail ? 20.0 : null,
            'latencyMs': fail ? null : 40.0,
          },
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

void main() {
  Future<SvoiController> setup(
    WidgetTester tester,
    SpeedBackend api, {
    Size size = const Size(1000, 950),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = SvoiController(api);
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: SpeedTools(c: c)),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets(
    'speed selection and results render asset flags without raw prefixes',
    (tester) async {
      final api = SpeedBackend()..complete = true;
      final c = await setup(tester, api);
      final choices = tester.widgetList<CountryMark>(find.byType(CountryMark));
      expect(
        choices.map((flag) => flag.country.code),
        containsAll(['NL', 'DE', 'FI', 'FR']),
      );
      expect(find.text('NL Нидерланды · 1'), findsNothing);
      await tester.ensureVisible(find.text('Сравнить скорость'));
      await tester.tap(find.text('Сравнить скорость'));
      await tester.pumpAndSettle();
      final flag = find.byKey(const ValueKey('speed-result-flag-0'));
      await tester.ensureVisible(flag);
      expect(tester.widget<CountryMark>(flag).country.code, 'NL');
      expect(find.byKey(const ValueKey('speed-result-flag-')), findsNothing);
      expect(find.text('Нидерланды · 1'), findsOneWidget);
      expect(find.text('Через профиль · VLESS'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await c.close();
    },
  );

  testWidgets(
    'does not run automatically, limits choices and renders measured comparison',
    (tester) async {
      final api = SpeedBackend();
      final c = await setup(tester, api);
      expect(api.calls, isEmpty);
      for (final name in ['Германия · 2', 'Финляндия · 3', 'Франция · 4']) {
        await tester.tap(find.text(name));
        await tester.pump();
      }
      expect(
        find.text('Можно сравнить до трёх серверов за один запуск.'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Сравнить скорость'));
      api.complete = true;
      await tester.tap(find.text('Сравнить скорость'));
      await tester.pumpAndSettle();
      expect(api.chosen.length, 3);
      expect(api.calls.where((s) => s.endsWith('/start')).length, 1);
      await tester.ensureVisible(find.text('Последнее сравнение'));
      await tester.pumpAndSettle();
      expect(
        find.text('80% от результата без VPN в этом тесте'),
        findsOneWidget,
      );
      expect(c.speedView.value['data']['state'], 'done');
      final count = api.calls.length;
      await tester.pump(const Duration(seconds: 5));
      expect(api.calls.length, count);
      await tester.pumpWidget(const SizedBox());
      await c.close();
    },
  );
  testWidgets('tray stops an active test and keeps completed results', (
    tester,
  ) async {
    final api = SpeedBackend();
    final c = await setup(tester, api);
    await tester.ensureVisible(find.text('Сравнить скорость'));
    await tester.tap(find.text('Сравнить скорость'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    c.visibility(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pumpAndSettle();
    expect(api.cancelled, isTrue);
    expect(c.speedView.value['data']['state'], 'cancelled');
    expect(c.speedView.value['data']['results'][0]['downloadMbps'], 40.0);
    await tester.pumpWidget(const SizedBox());
    await c.close();
  });
  testWidgets(
    'active TUN explains disabled comparison without disconnecting VPN',
    (tester) async {
      final api = SpeedBackend();
      final c = await setup(tester, api);
      c.connection.value = {'state': 'running', 'mode': 'tun', 'serverId': '0'};
      await tester.pump();
      await tester.ensureVisible(find.text('Сравнить скорость'));
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Сравнить скорость'),
      );
      expect(button.onPressed, isNull);
      expect(find.textContaining('сначала отключите TUN'), findsOneWidget);
      expect(api.calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await c.close();
    },
  );
  testWidgets(
    'narrow screen with large text has no overflow and errors do not become zero speeds',
    (tester) async {
      final api = SpeedBackend()
        ..complete = true
        ..fail = true;
      final c = await setup(
        tester,
        api,
        size: const Size(320, 750),
        scale: 1.5,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Сравнить скорость'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сравнить скорость'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.scrollUntilVisible(
        find.text('Сервер не ответил. Выберите другой сервер.'),
        120,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('speed-results-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('80% от результата без VPN в этом тесте'), findsNothing);
      expect(c.speedView.value['data']['results'][1]['downloadMbps'], isNull);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await c.close();
    },
  );
  testWidgets('changing tool tab cancels measurement', (tester) async {
    final api = SpeedBackend();
    final c = await setup(tester, api);
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(
          body: DefaultTabController(
            length: 2,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'Скорость'),
                    Tab(text: 'Проверить сайт'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      SpeedTools(c: c),
                      const SizedBox(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сравнить скорость'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.text('Проверить сайт'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.cancelled, isTrue);
    await tester.pumpWidget(const SizedBox());
    await c.close();
  });
  testWidgets(
    'short download in either route suppresses comparison percentages',
    (tester) async {
      for (final shortDirect in [false, true]) {
        final api = SpeedBackend()
          ..complete = true
          ..shortProfile = !shortDirect
          ..shortBaseline = shortDirect;
        final c = await setup(tester, api);
        await tester.tap(find.text('Сравнить скорость'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.textContaining('Процент не рассчитан:'),
          120,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('speed-results-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(find.textContaining('% от результата'), findsNothing);
        expect(find.text('Короткий замер'), findsAtLeastNWidgets(1));
        expect(find.textContaining('Загрузка:').evaluate(), isNotEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await c.close();
      }
    },
  );
  testWidgets('wide result puts a real chart next to metrics', (tester) async {
    final api = SpeedBackend()..complete = true;
    final c = await setup(tester, api, size: const Size(1200, 950));
    await tester.tap(find.text('Сравнить скорость'));
    await tester.pumpAndSettle();
    expect(find.byType(SpeedChart), findsWidgets);
    expect(
      tester.getTopLeft(find.byType(SpeedChart).first).dx,
      greaterThan(tester.getTopLeft(find.text('Загрузка').first).dx + 400),
    );
    expect(find.text('Недостаточно данных для графика'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await c.close();
  });
  test('chart ignores invalid samples and shares the same vertical scale', () {
    expect(
      SpeedChart.points([
        {'seconds': 1, 'mbps': double.nan},
        {'seconds': -1, 'mbps': 4},
        {'seconds': 1, 'mbps': 50},
      ]),
      hasLength(1),
    );
    expect(
      SpeedChart.scaleFor([
        {
          'downloadSamples': [
            {'seconds': 1, 'mbps': 50},
          ],
        },
        {
          'uploadSamples': [
            {'seconds': 1, 'mbps': 200},
          ],
        },
      ]),
      greaterThanOrEqualTo(200),
    );
  });
}
