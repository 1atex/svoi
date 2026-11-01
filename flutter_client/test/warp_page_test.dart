import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class WarpBackend extends DemoBackend {
  Map<String, dynamic> status = {'installed': false, 'state': 'not-installed'};
  final actions = <String>[];
  var reads = 0;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path == 'warp') {
      reads++;
      return {...status};
    }
    if (path.startsWith('warp/')) {
      actions.add(path);
      if (path == 'warp/register') {
        if ((body as Map)['accepted'] != true) {
          throw ApiException('consent missing');
        }
        status = {'installed': true, 'state': 'disconnected'};
      } else if (path == 'warp/connect') {
        status = {'installed': true, 'state': 'connecting'};
      } else if (path == 'warp/disconnect') {
        status = {'installed': true, 'state': 'disconnected'};
      }
      return {...status};
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
  testWidgets('missing install is actionable and polling sleeps in tray', (
    tester,
  ) async {
    final api = WarpBackend();
    final controller = SvoiController(api);
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: WarpPage(c: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Скачать Cloudflare WARP'), findsOneWidget);
    expect(find.byKey(const ValueKey('connection-power')), findsNothing);
    controller.visibility(false);
    final reads = api.reads;
    await tester.pump(const Duration(seconds: 30));
    expect(api.reads, reads);
    await tester.pumpWidget(const SizedBox());
    await controller.close();
  });

  testWidgets(
    'registration requires consent and connect waits for real status',
    (tester) async {
      final api = WarpBackend()
        ..status = {'installed': true, 'state': 'unregistered'};
      final c = SvoiController(api);
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: WarpPage(c: c)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Настроить WARP'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(api.actions, isEmpty);
      await tester.tap(find.text('Настроить WARP'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Принять и настроить'));
      await tester.pumpAndSettle();
      expect(api.actions, ['warp/register']);
      await tester.tap(find.byKey(const ValueKey('connection-power')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('WARP подключён'), findsNothing);
      expect(find.text('Подключаем WARP…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('connection-power')));
      await tester.pumpAndSettle();
      expect(api.actions, ['warp/register', 'warp/connect', 'warp/disconnect']);
      await tester.pumpWidget(const SizedBox());
      await c.close();
    },
  );

  testWidgets(
    'active VPN blocks WARP and layout tolerates narrow and enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = WarpBackend()
        ..status = {
          'installed': true,
          'state': 'disconnected',
          'vpnRunning': true,
        };
      final c = SvoiController(api);
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(body: WarpPage(c: c)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('connection-power')))
            .onPressed,
        isNull,
      );
      expect(api.actions, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await c.close();
    },
  );
}
