import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  var status = <String, dynamic>{};
  setUp(() {
    calls.clear();
    status = {
      'state': 'available',
      'available': true,
      'version': 'test.7',
      'currentVersion': 'test.6',
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MobileUpdateModel.channel, (call) async {
          calls.add(call);
          return call.method == 'install' ? null : jsonEncode(status);
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MobileUpdateModel.channel, null);
  });

  testWidgets('download, permission and install controls follow native state', (
    tester,
  ) async {
    final model = MobileUpdateModel();
    addTearDown(model.dispose);
    await model.call('status');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MobileUpdatesPanel(model: model)),
        ),
      ),
    );
    expect(find.text('Доступна версия test.7'), findsOneWidget);
    status = {
      ...status,
      'state': 'downloading',
      'size': 1000,
      'downloaded': 400,
    };
    await tester.tap(find.text('Скачать обновление'));
    await tester.pump();
    expect(calls.last.method, 'download');
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    status = {...status, 'state': 'ready', 'canInstall': false};
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Разрешить установку'), findsOneWidget);
    status = {...status, 'canInstall': true};
    await tester.tap(find.text('Разрешить установку'));
    await tester.pump();
    expect(calls.any((c) => c.method == 'install'), isTrue);
    expect(find.text('Установить обновление'), findsOneWidget);
  });

  testWidgets('background pauses polling, resume reads persisted download', (
    tester,
  ) async {
    status = {...status, 'state': 'downloading'};
    final model = MobileUpdateModel();
    addTearDown(model.dispose);
    model.start();
    await tester.pump();
    expect(calls.single.arguments, {'force': false});
    model.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 20));
    expect(calls.length, 1);
    model.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls.last.method, 'status');
    await tester.pump(const Duration(seconds: 1));
    expect(calls.length, 3);
  });

  testWidgets('native errors remain visible and allow retry', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MobileUpdateModel.channel, (_) async {
          throw PlatformException(
            code: 'update',
            message: 'Нет свободного места',
          );
        });
    final model = MobileUpdateModel();
    addTearDown(model.dispose);
    await model.call('check', {'force': true});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MobileUpdatesPanel(model: model)),
        ),
      ),
    );
    expect(find.text('Нет свободного места'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNotNull);
  });
}
