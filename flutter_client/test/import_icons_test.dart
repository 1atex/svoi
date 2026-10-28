import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

void main() {
  testWidgets(
    'paste is explicit, editable and follows both icon styles in light and dark themes',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      var reads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              reads++;
              return {'text': 'https://example.com/subscription'};
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final c = SvoiController(DemoBackend());
      await c.initialize();
      final store = AppearanceStore();
      for (final appearance in [
        AppAppearance.light,
        AppAppearance.mono,
        AppAppearance.ocean,
      ]) {
        await store.select(appearance);
        for (final style in UiIconStyle.values) {
          await store.selectIcons(style);
          await tester.pumpWidget(
            AppearanceScope(
              store: store,
              child: MaterialApp(
                theme: svoiTheme(palette: SvoiColors.forAppearance(appearance)),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => importDialog(context, c),
                      child: const Text('Импорт'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Импорт'));
          await tester.pumpAndSettle();
          final before = reads;
          await tester.tap(find.text('Вставить'));
          await tester.pumpAndSettle();
          expect(reads, before + 1);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'https://example.com/subscription',
          );
          final icons = tester.widgetList<SvgPicture>(find.byType(SvgPicture));
          expect(
            icons.any(
              (icon) =>
                  icon.bytesLoader is SvgAssetLoader &&
                  (icon.bytesLoader as SvgAssetLoader).assetName ==
                      'assets/ui-icons/${style.name}/clipboard-text.svg',
            ),
            isTrue,
          );
          await tester.enterText(
            find.byType(TextField),
            'https://example.com/edited',
          );
          expect(reads, before + 1);
          await tester.tap(find.text('Отмена'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox());
      store.dispose();
      await c.close();
    },
  );
}
