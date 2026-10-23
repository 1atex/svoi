import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class FeatureBackend extends DemoBackend {
  final calls = <String>[];
  Object? jobBody;
  bool jobBusy = false;
  bool elevated = true, running = false;
  List<Map<String, dynamic>> results = [];
  Map<String, dynamic> prefs = {
    'autoRefresh': false,
    'routing': {
      'mode': 'all',
      'processes': ['browser.exe'],
    },
  };
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    calls.add('$method $path');
    if (path == 'settings') {
      if (method == 'PUT') prefs = Map<String, dynamic>.from(body as Map);
      return prefs;
    }
    if (path == 'updates/check') return {'accepted': true};
    if (path == 'updates') {
      return {'state': 'current', 'current': clientVersion};
    }
    if (path == 'zapret/job') {
      jobBody = body;
      jobBusy = true;
      return {'accepted': true};
    }
    if (path == 'zapret/cancel') {
      jobBusy = false;
      return {'accepted': true};
    }
    if (path == 'zapret/start') {
      running = true;
      return {'accepted': true};
    }
    if (path == 'zapret/stop') {
      running = false;
      return {'accepted': true};
    }
    if (path.startsWith('zapret')) {
      return {
        'running': running,
        'elevated': elevated,
        'version': 'test',
        'managed': true,
        'strategies': ['general.bat'],
        'logs': ['Ready'],
        'job': {
          'busy': jobBusy,
          'state': jobBusy ? 'running' : 'idle',
          'message': 'Test status',
          'results': results,
          'total': 2,
          'completed': 0,
        },
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
  testWidgets(
    'zapret result filter keeps errors and opens their full details',
    (tester) async {
      tester.view.physicalSize = const Size(1240, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FeatureBackend()
        ..results = [
          {
            'target': 'good.example',
            'state': 'ok',
            'detail': 'HTTP 200',
            'check': 'HTTPS',
          },
          {
            'target': 'bad.example',
            'state': 'error',
            'detail': 'Detailed TLS failure',
            'check': 'TLS',
          },
        ];
      final c = SvoiController(api);
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: ZapretPage(c: c)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Проверки'));
      await tester.pumpAndSettle();
      expect(find.text('good.example'), findsOneWidget);
      await tester.tap(find.text('Только проблемы'));
      await tester.pumpAndSettle();
      expect(find.text('good.example'), findsNothing);
      await tester.tap(find.text('bad.example'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
  testWidgets('all pages fit minimum window and navigation is accessible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = SvoiController(FeatureBackend());
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: SvoiShell(controller: c),
      ),
    );
    for (final page in [
      'Серверы',
      'Общий профиль',
      'Приложения',
      'zapret',
      'Настройки',
      'Подключение',
    ]) {
      final nav = find.widgetWithText(ListTile, page).first;
      await tester.ensureVisible(nav);
      await tester.tap(nav);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: page);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });

  testWidgets('zapret starts and cancels a standard checker through the API', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FeatureBackend();
    final controller = SvoiController(api);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: ZapretPage(c: controller)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Проверки'));
    await tester.pumpAndSettle();
    final start = find.text('Начать проверку');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.jobBody, {'kind': 'standard', 'sweep': false, 'strategies': []});
    final cancel = find.text('Остановить проверку');
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(api.calls, contains('POST zapret/cancel'));
    await tester.tap(find.text('DPI-checkers · HTTP и TLS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Перебрать стратегии'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'general.bat'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.jobBody, {
      'kind': 'dpi',
      'sweep': true,
      'strategies': ['general.bat'],
    });
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await controller.close();
  });

  testWidgets(
    'zapret power reflects backend state and refuses unelevated start',
    (tester) async {
      final api = FeatureBackend();
      final c = SvoiController(api);
      await c.initialize();
      Future<void> mount() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: svoiTheme(),
            home: Scaffold(
              body: ZapretPage(key: UniqueKey(), c: c),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await mount();
      await tester.ensureVisible(find.text('Запустить zapret'));
      await tester.tap(find.text('Запустить zapret'));
      await tester.pumpAndSettle();
      expect(api.running, true);
      expect(find.text('Остановить zapret'), findsOneWidget);
      await tester.tap(find.text('Остановить zapret'));
      await tester.pumpAndSettle();
      expect(api.running, false);
      api.elevated = false;
      await mount();
      expect(
        tester
            .widget<AppButton>(find.byKey(const ValueKey('zapret-power')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );

  testWidgets(
    'per-app routing preserves preferences and applies include mode',
    (tester) async {
      final api = FeatureBackend();
      final c = SvoiController(api);
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: RoutingPage(c: c)),
        ),
      );
      await tester.tap(find.text('Только выбранные'));
      await tester.pumpAndSettle();
      expect(api.prefs['routing'], {
        'mode': 'include',
        'processes': ['browser.exe'],
      });
      expect(api.prefs['autoRefresh'], false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
}
