import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/main.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';

void main() {
  for (final size in [const Size(800, 600), const Size(1200, 800)]) {
    testWidgets('settings back stays outside Windows drag zones at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final frames = <Map>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, (call) async {
            if (call.method == 'titlebar') frames.add(call.arguments as Map);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(windowChannel, null),
      );
      final c = SvoiController(DemoBackend());
      await c.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: SvoiShell(controller: c, demo: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop-tab-5')));
      await tester.pumpAndSettle();
      final original = frames.last;
      bool intercepted(Offset point, Map frame) {
        final regions = [
          ...(frame['drag'] as List),
          if (frame['maximize'] != null) frame['maximize'],
        ];
        return regions.any(
          (r) => Rect.fromLTWH(
            (r[0] as num).toDouble(),
            (r[1] as num).toDouble(),
            (r[2] as num).toDouble(),
            (r[3] as num).toDouble(),
          ).contains(point),
        );
      }

      for (final section in ['Проверка задержки', 'Автоматизация']) {
        final entry = find.byKey(ValueKey('settings-section-$section'));
        await tester.ensureVisible(entry);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        final back = find.byKey(const ValueKey('settings-back'));
        expect(back.hitTestable(), findsOneWidget);
        expect(find.byTooltip('Закрыть SVOI').hitTestable(), findsOneWidget);
        expect(intercepted(tester.getCenter(back), frames.last), isFalse);
        final count = frames.length;
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(find.byType(SettingsDetailPage), findsNothing);
        expect(entry.hitTestable(), findsOneWidget);
        expect(
          frames.length,
          greaterThan(count),
          reason: 'Restore native titlebar geometry after popping',
        );
        expect(frames.last, original);
        expect(
          intercepted(
            tester.getCenter(find.byKey(const ValueKey('desktop-tab-5'))),
            frames.last,
          ),
          isFalse,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await c.close();
    });
  }

  testWidgets(
    'titlebar keeps every action reachable at minimum size and large text',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(windowChannel, null),
      );
      var page = -1;
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: DesktopTitlebar(
                page: 0,
                onPage: (value) => page = value,
                onProfiles: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final index in [0, 4, 6, 5]) {
        final tab = find.byKey(ValueKey('desktop-tab-$index'));
        expect(tab.hitTestable(), findsOneWidget);
        await tester.tap(tab);
        expect(page, index);
      }
      for (final label in ['Свернуть', 'Развернуть', 'Закрыть SVOI']) {
        expect(find.byTooltip(label).hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip(label));
      }
      await tester.pumpAndSettle();
      expect(
        calls.map((c) => c.method),
        containsAll(['titlebar', 'minimize', 'maximize', 'requestWindowClose']),
      );
      final geometry =
          calls.firstWhere((c) => c.method == 'titlebar').arguments as Map;
      final maximize = geometry['maximize'] as List;
      expect(maximize[2], 46);
      expect((geometry['drag'] as List).length, 2);
      expect(tester.takeException(), isNull);
      windowMaximized.value = true;
      await tester.pumpAndSettle();
      expect(find.byTooltip('Восстановить окно').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      windowMaximized.value = false;
    },
  );
}
