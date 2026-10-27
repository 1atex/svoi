import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/main.dart';

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
      expect(find.text('Отключить VPN'), findsOneWidget);
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
      expect(find.text('Подождите…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
