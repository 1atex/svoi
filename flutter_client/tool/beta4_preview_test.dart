import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import '../test/startup_panel_test.dart' show StartupBackend;

void main() {
  testWidgets('beta4 connection and startup previews', (tester) async {
    await tester.runAsync(() async {
      final font = FontLoader('Segoe UI')
        ..addFont(
          File('${Platform.environment['WINDIR']}/Fonts/segoeui.ttf')
              .readAsBytes()
              .then(ByteData.sublistView),
        );
      await font.load();
      for (final e in {
        'packages/lucide_icons_flutter/Lucide':
            'packages/lucide_icons_flutter/assets/lucide.ttf',
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(e.key)..addFont(rootBundle.load(e.value))).load();
      }
      await Directory('../.ui-preview/beta4').create(recursive: true);
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = StartupBackend();
    backend.group['servers'] = [
      {
        'id': '0',
        'name': 'fi Finland',
        'protocol': 'vless',
        'address': 'example.com',
        'port': 443,
        'network': 'tcp',
        'security': 'reality',
      },
    ];
    final c = SvoiController(backend);
    await c.initialize();
    c.mode.value = 'tun';
    c.connection.value = {
      'available': true,
      'elevated': true,
      'state': 'running',
      'serverId': '0',
      'mode': 'tun',
      'error': 'Контрольный запрос: timeout',
      'checked': false,
    };
    Future<void> capture(String name, Size size, Widget child) async {
      tester.view.physicalSize = size;
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: svoiTheme(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(padding: const EdgeInsets.all(20), child: child),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final img =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        await File('../.ui-preview/beta4/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        img.dispose();
      });
    }

    await capture(
      'connection-check-failed',
      const Size(560, 800),
      ConnectionCard(c: c),
    );
    await capture(
      'startup-settings',
      const Size(760, 420),
      Section('Автоматизация', children: [StartupPanel(c: c)]),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  }, skip: !Platform.isWindows);
}
