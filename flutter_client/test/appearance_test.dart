import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/main.dart';

import 'connection_ui_test.dart' show ConnectionBackend;

void main() {
  test(
    'appearance persists independently of profiles, including rapid choices',
    () async {
      final folder = await Directory.systemTemp.createTemp('svoi-themes-');
      addTearDown(() => folder.delete(recursive: true));
      final file = File('${folder.path}/appearance.json');
      final store = AppearanceStore();
      await store.load(file);
      expect(store.value, AppAppearance.dark);
      await Future.wait([
        store.select(AppAppearance.light),
        store.select(AppAppearance.dark),
        store.select(AppAppearance.halloween),
      ]);
      final restored = AppearanceStore();
      await restored.load(file);
      expect(restored.value, AppAppearance.halloween);
      for (final choice in AppAppearance.values) {
        await store.select(choice);
        await restored.load(file);
        expect(restored.value, choice);
      }
      await file.writeAsString('{"theme":"unknown"}');
      await restored.load(file);
      expect(restored.value, AppAppearance.dark);
      await file.writeAsString('{broken');
      await restored.load(file);
      expect(restored.value, AppAppearance.dark);
      store.dispose();
      restored.dispose();
    },
  );

  test('palettes preserve text and action contrast', () {
    double contrast(Color a, Color b) {
      final values = [a.computeLuminance(), b.computeLuminance()]..sort();
      return (values[1] + .05) / (values[0] + .05);
    }

    for (final p in AppAppearance.values.map(SvoiColors.forAppearance)) {
      for (final pair in [
        (p.ink, p.canvas),
        (p.muted, p.surface),
        (p.muted, p.selected),
        (p.accent, p.surface),
        (p.error, p.surface),
        (p.success, p.surface),
        (p.onAccent, p.accent),
      ]) {
        expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
      }
    }
  });

  testWidgets(
    'pumpkin remains one action and blocks repeat presses while connecting',
    (tester) async {
      var taps = 0;
      Widget app({bool running = false, bool busy = false}) => MaterialApp(
        theme: svoiTheme(palette: SvoiColors.pumpkin),
        home: Scaffold(
          body: Center(
            child: ConnectionOrbit(
              running: running,
              verified: running,
              busy: busy,
              onPressed: () => taps++,
              hint: busy
                  ? 'Подождите'
                  : running
                  ? 'Отключить VPN'
                  : 'Подключить VPN',
            ),
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(TextButton), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('connection-power')));
      expect(taps, 1);
      await tester.pumpWidget(app(running: true));
      await tester.pumpAndSettle();
      expect(find.text('Отключить VPN'), findsNothing);
      expect(find.byTooltip('Отключить VPN'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('connection-power')));
      expect(taps, 2);
      await tester.pumpWidget(app(busy: true));
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('connection-power')))
            .onPressed,
        isNull,
      );
      expect(find.byTooltip('Подождите'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'live themes preserve workspace state and follow Windows only when selected',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          windowChannel,
          null,
        ),
      );
      final backend = ConnectionBackend();
      await tester.pumpWidget(Bootstrap(demo: true, backend: backend));
      await tester.pumpAndSettle();
      final shell = tester.widget<SvoiShell>(find.byType(SvoiShell));
      final shellState = tester.state(find.byType(SvoiShell));
      final store = AppearanceScope.of(tester.element(find.byType(SvoiShell)))!;
      final controller = shell.controller;
      final selected = controller.selected.value;
      await controller.toggleConnection();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop-tab-5')));
      await tester.pumpAndSettle();
      for (final choice in [
        AppAppearance.halloween,
        AppAppearance.light,
        AppAppearance.dark,
      ]) {
        await tester.tap(find.byKey(ValueKey('theme-${choice.name}')));
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(PreferencesPage));
        expect(
          appColors(context).accent,
          SvoiColors.forAppearance(choice).accent,
        );
        expect(tester.state(find.byType(SvoiShell)), same(shellState));
        expect(controller.connection.value['state'], 'running');
        expect(controller.connection.value['serverId'], selected);
        expect(backend.state['state'], 'running');
        expect(find.byType(PreferencesPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await store.select(AppAppearance.system);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(PreferencesPage))).brightness,
        Brightness.light,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(PreferencesPage))).brightness,
        Brightness.dark,
      );
      await store.select(AppAppearance.halloween);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(
        appColors(tester.element(find.byType(PreferencesPage))).halloween,
        isTrue,
      );
      expect(calls, isNot(contains('close')));
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.close();
    },
  );
}
