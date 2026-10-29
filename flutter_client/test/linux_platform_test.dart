import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/main.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/data_directory.dart';

void main() {
  test(
    'Linux stores data in XDG user data, never next to the executable',
    () async {
      final folder = await Directory.systemTemp.createTemp('svoi-xdg-');
      addTearDown(() => folder.delete(recursive: true));
      final data = await prepareDataDirectory(
        environment: {
          'HOME': folder.path,
          'XDG_DATA_HOME': '${folder.path}/data',
        },
      );
      expect(data.path, '${folder.path}/data/svoi');
      expect(await data.exists(), isTrue);
    },
    skip: !Platform.isLinux,
  );

  testWidgets('Linux shows supported modes, settings, and direct-site rules', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
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
    final c = SvoiController(DemoBackend());
    await c.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: Scaffold(body: ModePicker(c: c)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    expect(find.text('Приложения с системным прокси'), findsNothing);
    expect(find.text('Ручная настройка прокси'), findsWidgets);
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: SvoiShell(controller: c, demo: true),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('zapret'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('desktop-tab-5')));
    await tester.pumpAndSettle();
    expect(find.byType(LinuxPreferences), findsOneWidget);
    expect(find.byType(StartupPanel), findsNothing);
    expect(find.text('Скачивать обновления автоматически'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  }, skip: !Platform.isLinux);
}
