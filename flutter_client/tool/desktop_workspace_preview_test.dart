import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import '../test/connection_ui_test.dart' show ConnectionBackend;

void main() {
  testWidgets('capture unified Windows workspace', (tester) async {
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
      await Directory('../.ui-preview/desktop-workspace')
          .create(recursive: true);
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = ConnectionBackend();
    final servers = (backend.group['servers'] as List).take(12).toList();
    backend.group['servers'] = servers;
    backend.group['subscriptions'][0]['name'] = 'Личная подписка';
    backend.group['subscriptions'][0]['count'] = 12;
    final c = SvoiController(backend);
    await c.initialize();
    c.mode.value = 'tun';
    c.connection.value = {...c.connection.value, 'elevated': true};
    c.favorites.value = {'0', '2'};
    for (final entry in {'0': 61, '2': 84}.entries) {
      c.probes[entry.key]!.value = ProbeState(latency: entry.value);
    }
    final key = GlobalKey();
    Future<void> snapshot(String name) async {
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../.ui-preview/desktop-workspace/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    Future<void> capture(
      String name,
      Size size, {
      double scale = 1,
      bool reducedMotion = false,
      SvoiColors palette = SvoiColors.dark,
    }) async {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: svoiTheme(palette: palette),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: reducedMotion,
              ),
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
      await snapshot(name);
    }

    await capture('wide', const Size(1200, 800));
    await capture('compact-desktop', const Size(980, 700));
    await tester.tap(find.text('Добавить подписку').first);
    await tester.pumpAndSettle();
    await snapshot('subscription-import');
    await tester.tap(find.text('Из файла'));
    await tester.pumpAndSettle();
    await snapshot('subscription-file');
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();

    c.notify('Подписки обновлены · 2');
    await capture('toast', const Size(980, 700));
    await capture(
      'wide-light',
      const Size(900, 640),
      palette: SvoiColors.light,
    );
    await capture('reduced-motion', const Size(1200, 800), reducedMotion: true);
    expect(tester.binding.hasScheduledFrame, false);
    await capture('compact', const Size(800, 600));
    await capture('large-text', const Size(800, 600), scale: 1.5);
    await c.toggleConnection();
    await c.selectServer('1');
    await capture('switch', const Size(900, 640));
    await capture('switch-compact', const Size(800, 600));
    await c.stop();
    c.servers.value = [];
    c.subscriptions.value = [];
    await capture('first-run', const Size(800, 600));
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  }, skip: !Platform.isWindows);
}
