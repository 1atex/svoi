import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/main.dart';

import '../test/network_tools_test.dart' show NetworkBackend;

void main() {
  testWidgets('subscription header and DNS navigation previews', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final font = FontLoader('Segoe UI')
        ..addFont(
          File('C:/Windows/Fonts/segoeui.ttf')
              .readAsBytes()
              .then(ByteData.sublistView),
        );
      await font.load();
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final entry in manifest) {
        if (!entry['family'].toString().toLowerCase().contains('lucide') &&
            entry['family'] != 'MaterialIcons') {
          continue;
        }
        final loader = FontLoader(entry['family']);
        for (final file in entry['fonts']) {
          loader.addFont(rootBundle.load(file['asset']));
        }
        await loader.load();
      }
      await Directory('../.ui-preview/beta12').create(recursive: true);
    });
    final api = NetworkBackend();
    api.group['servers'] = (api.group['servers'] as List).take(6).toList();
    api.group['subscriptions'] = [
      {
        'id': 'demo',
        'name': 'Моя подписка',
        'count': 6,
        'remote': true,
        'host': 'provider.example',
        'report': {'fetchedAt': '2026-10-26T15:30:00Z'},
        'metadata': {
          'upload': 0,
          'download': 66048,
          'total': 102649718374,
          'expire': 1815177600,
          'updateHours': 1,
          'announcement': 'Подписка активна. Доступны все серверы.',
          'routingStatus': 'happ-not-applied',
        },
      },
    ];
    final c = SvoiController(api);
    await c.initialize();
    final key = GlobalKey();
    for (final size in [const Size(1200, 800), const Size(800, 600)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: svoiTheme(),
            home: SvoiShell(controller: c),
          ),
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
        await File(
          '../.ui-preview/beta12/subscription-${size.width.toInt()}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.tap(find.text('DNS'));
    await tester.pumpAndSettle();
    expect(find.text('Подобрать DNS'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('../.ui-preview/beta12/dns.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  });
}
