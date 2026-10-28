import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/main.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/backend.dart';

class IdentityBackend extends DemoBackend {
  Map? created;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) {
    if (path == 'groups') created = body as Map;
    return super.request(
      path,
      method: method,
      body: body,
      cancellation: cancellation,
    );
  }
}

void main() {
  testWidgets('macOS exposes proxy, native settings and no Windows actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1220, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowChannel,
      (MethodCall call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        null,
      ),
    );
    final api = IdentityBackend();
    final c = SvoiController(api);
    await c.initialize();
    expect(c.mode.value, 'system');
    expect(api.created?['platform'], 'macOS');
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: ModePicker(c: c)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.textContaining('· TUN'), findsNothing);
    expect(find.text('Ручная настройка прокси'), findsWidgets);
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: SvoiShell(controller: c, demo: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('zapret'), findsNothing);
    expect(find.byTooltip('Закрыть SVOI'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('desktop-tab-5')));
    await tester.pumpAndSettle();
    expect(find.byType(MacOSPreferences), findsOneWidget);
    expect(find.byType(StartupPanel), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  }, skip: !Platform.isMacOS);
}
