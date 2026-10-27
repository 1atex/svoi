import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/main.dart';

void main() {
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
