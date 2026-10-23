import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import '../test/onboarding_tray_test.dart' show FirstRunBackend;

void main() {
  testWidgets('capture first-run layout at desktop sizes', (tester) async {
    await tester.runAsync(() async {
      final fonts = '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts';
      final text = FontLoader('Segoe UI')
        ..addFont(
          File('$fonts/segoeui.ttf').readAsBytes().then(ByteData.sublistView),
        );
      await text.load();
      for (final entry in {
        'packages/lucide_icons_flutter/Lucide':
            'packages/lucide_icons_flutter/assets/lucide.ttf',
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(
          entry.key,
        )..addFont(rootBundle.load(entry.value))).load();
      }
      await Directory('../.ui-preview/beta3').create(recursive: true);
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = SvoiController(FirstRunBackend());
    await c.initialize();
    final key = GlobalKey();
    Future<void> capture(String name, Size size, {double scale = 1}) async {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: svoiTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: SvoiShell(controller: c),
          ),
        ),
      );
      await tester.runAsync(
        () => precacheImage(
          const AssetImage('assets/svoi-mark.png'),
          key.currentContext!,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../.ui-preview/beta3/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('first-run-small', const Size(816, 600));
    await capture('first-run-125', const Size(816, 600), scale: 1.25);
    await capture('first-run', const Size(1040, 850));
    await capture('first-run-wide', const Size(1440, 900));
    await c.importText('https://example.com/sub');
    await capture('populated-narrow', const Size(1040, 850));
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  }, skip: !Platform.isWindows);
}
