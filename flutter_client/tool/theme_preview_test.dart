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
  testWidgets('capture themes and verify minimum size and large text', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fonts = '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts';
      await (FontLoader('Segoe UI')..addFont(
            File('$fonts/segoeui.ttf').readAsBytes().then(ByteData.sublistView),
          ))
          .load();
      for (final entry in {
        'packages/lucide_icons_flutter/Lucide':
            'packages/lucide_icons_flutter/assets/lucide.ttf',
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(
          entry.key,
        )..addFont(rootBundle.load(entry.value))).load();
      }
      await Directory('../.ui-preview/themes').create(recursive: true);
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = ConnectionBackend();
    backend.group['servers'] = (backend.group['servers'] as List)
        .take(12)
        .toList();
    backend.group['subscriptions'][0]['name'] = 'Личная подписка';
    backend.group['subscriptions'][0]['count'] = 12;
    final c = SvoiController(backend);
    await c.initialize();
    c.connection.value = {...c.connection.value, 'elevated': true};
    final store = AppearanceStore();
    final key = GlobalKey();
    double scale = 1;
    Widget app() => RepaintBoundary(
      key: key,
      child: AppearanceScope(
        store: store,
        child: ValueListenableBuilder(
          valueListenable: store,
          builder: (context, value, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: svoiTheme(palette: SvoiColors.forAppearance(value)),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: SvoiShell(controller: c),
          ),
        ),
      ),
    );
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final picture =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final data = await picture.toByteData(format: ui.ImageByteFormat.png);
        await File('../.ui-preview/themes/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        picture.dispose();
      });
    }

    tester.view.physicalSize = const Size(1200, 820);
    await tester.pumpWidget(app());
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/svoi-mark.png'),
        key.currentContext!,
      ),
    );
    await tester.runAsync(
      () => precacheImage(
        ResizeImage.resizeIfNeeded(
          384,
          384,
          const AssetImage('assets/themes/pumpkin-power.png'),
        ),
        key.currentContext!,
      ),
    );
    for (final choice in [
      AppAppearance.dark,
      AppAppearance.light,
      AppAppearance.ocean,
      AppAppearance.emerald,
      AppAppearance.rose,
      AppAppearance.mono,
      AppAppearance.halloween,
    ]) {
      await store.select(choice);
      await capture('${choice.name}-connection');
      await tester.tap(find.byKey(const ValueKey('desktop-tab-5')));
      await capture('${choice.name}-settings');
      await tester.tap(find.byKey(const ValueKey('desktop-tab-6')));
      await capture('${choice.name}-tools');
      await tester.tap(find.byKey(const ValueKey('desktop-tab-0')));
    }
    tester.view.physicalSize = const Size(800, 600);
    scale = 1.5;
    await tester.pumpWidget(app());
    for (final choice in [
      AppAppearance.dark,
      AppAppearance.light,
      AppAppearance.ocean,
      AppAppearance.emerald,
      AppAppearance.rose,
      AppAppearance.mono,
      AppAppearance.halloween,
    ]) {
      await store.select(choice);
      await capture('${choice.name}-compact');
      await tester.tap(find.byKey(const ValueKey('desktop-tab-5')));
      await capture('${choice.name}-settings-large-text');
      await tester.tap(find.byKey(const ValueKey('desktop-tab-0')));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
    store.dispose();
  }, skip: !Platform.isWindows);
}
