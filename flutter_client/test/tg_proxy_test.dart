import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class TelegramBackend extends DemoBackend {
  bool running = false;
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path.startsWith('tg-proxy')) {
      calls.add('$method $path');
      if (path.endsWith('/start')) running = true;
      if (path.endsWith('/stop')) running = false;
      return {
        'installed': true,
        'running': running,
        'version': '1.11.2',
        'port': 1443,
        'link': running
            ? 'tg://proxy?server=127.0.0.1&port=1443&secret=dd0123456789abcdef0123456789abcdef'
            : '',
        'logs': <String>[],
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
    'Telegram proxy starts, opens native link and stops in a compact window',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final methods = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        (call) async {
          methods.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          windowChannel,
          null,
        ),
      );
      final api = TelegramBackend();
      final c = SvoiController(api);
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(
            body: SingleChildScrollView(child: TelegramProxyPanel(c: c)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Подключить Telegram'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('tg-proxy-power')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('POST tg-proxy/start'));
      expect(find.text('Работает'), findsOneWidget);
      await tester.tap(find.text('Подключить Telegram'));
      await tester.pumpAndSettle();
      expect(methods.last.method, 'openTelegramProxy');
      expect(methods.last.arguments, startsWith('tg://proxy?server=127.0.0.1'));
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Порт 1443'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('tg-proxy-power')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('POST tg-proxy/stop'));
      expect(find.text('Остановлен'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    },
  );
}
