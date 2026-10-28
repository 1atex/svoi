import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import '../test/speed_tools_test.dart' show SpeedBackend;

void main() {
  testWidgets('speed comparison visuals', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 760);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await (FontLoader('Segoe UI')..addFont(
            File('C:/Windows/Fonts/segoeui.ttf')
                .readAsBytes()
                .then(ByteData.sublistView),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      await Directory('../.ui-test/speed').create(recursive: true);
    });
    final c = SvoiController(SpeedBackend()..complete = true);
    await c.initialize();
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: svoiTheme(),
          home: Scaffold(body: NetworkToolsPage(c: c)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../.ui-test/speed/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('select');
    await tester.tap(find.text('Сравнить скорость'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await capture('results');
    await tester.pumpWidget(const SizedBox());
    await c.close();
  });
}
