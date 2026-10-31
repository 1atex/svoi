import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class StartupBackend extends DemoBackend {
  Map<String, dynamic> startup = {
    'enabled': false,
    'zapret': false,
    'strategy': 'general.bat',
    'elevated': true,
  };
  bool fail = false;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path == 'startup') {
      if (method == 'POST') {
        if (fail) throw ApiException('Нет прав на изменение автозапуска');
        startup = {...startup, ...Map<String, dynamic>.from(body as Map)};
      }
      return Map.from(startup);
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
  testWidgets('telegram startup enables tray app and preserves zapret', (
    tester,
  ) async {
    final backend = StartupBackend();
    final controller = SvoiController(backend);
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: StartupPanel(c: controller, telegramOnly: true)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('telegram-startup')));
    await tester.pumpAndSettle();
    expect(backend.startup['enabled'], true);
    expect(backend.startup['telegramProxy'], true);
    expect(backend.startup['zapret'], false);
    backend.fail = true;
    await tester.tap(find.byKey(const ValueKey('telegram-startup')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('telegram-startup')),
          )
          .value,
      true,
    );
    backend.fail = false;
    await tester.tap(find.byKey(const ValueKey('telegram-startup')));
    await tester.pumpAndSettle();
    expect(backend.startup['enabled'], true);
    expect(backend.startup['telegramProxy'], false);
    await tester.pumpWidget(const SizedBox.shrink());
    await controller.close();
  });
  testWidgets(
    'startup controls enable app with zapret and retain actual state on failure',
    (tester) async {
      final backend = StartupBackend();
      final controller = SvoiController(backend);
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Scaffold(body: StartupPanel(c: controller)),
        ),
      );
      await tester.pumpAndSettle();
      final toggles = find.byType(SwitchListTile);
      await tester.tap(toggles.at(1));
      await tester.pumpAndSettle();
      expect(backend.startup['enabled'], true);
      expect(backend.startup['zapret'], true);
      backend.fail = true;
      await tester.tap(toggles.first);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggles.first).value, true);
      expect(find.textContaining('Нет прав'), findsOneWidget);
      backend.fail = false;
      await tester.tap(toggles.first);
      await tester.pumpAndSettle();
      expect(backend.startup['enabled'], false);
      expect(backend.startup['zapret'], false);
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.close();
    },
  );
}
