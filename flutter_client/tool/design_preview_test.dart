import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class PreviewBackend extends DemoBackend {
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path.startsWith('zapret')) {
      return {
        'running': false,
        'elevated': true,
        'managed': true,
        'version': '1.9.2 (демо)',
        'strategies': [
          'general.bat',
          'general (ALT).bat',
          'general (FAKE TLS AUTO).bat',
        ],
        'logs': ['Демонстрационный журнал. Реальный zapret не запускался.'],
        'job': {
          'busy': false,
          'state': 'done',
          'message': 'Проверка завершена',
          'successful': 1,
          'resultCount': 2,
          'results': [
            {
              'target': 'youtube.com',
              'check': 'HTTPS',
              'state': 'ok',
              'detail': 'HTTP 200',
              'millis': 82,
            },
            {
              'target': 'discord.com',
              'check': 'TLS',
              'state': 'error',
              'detail': 'Время ожидания ответа истекло',
            },
          ],
        },
      };
    }
    if (path == 'connection') {
      return {'available': true, 'state': 'stopped', 'version': '26.10.21'};
    }
    return super.request(
      path,
      method: method,
      body: body,
      cancellation: cancellation,
    );
  }
}

void main() {
  testWidgets('render desktop and compact layouts with bundled flags', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fonts = '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts';
      final loader = FontLoader('Segoe UI');
      for (final name in ['segoeui.ttf', 'segoeuib.ttf']) {
        loader.addFont(
          File('$fonts/$name')
              .readAsBytes()
              .then((b) => ByteData.sublistView(b)),
        );
      }
      await loader.load();
      final manifest = (await rootBundle.loadString('FontManifest.json'));

      final iconLoader = FontLoader('packages/lucide_icons_flutter/Lucide');
      expect(manifest, contains('Lucide'));
      iconLoader.addFont(
        rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
      );
      await iconLoader.load();
      final material = FontLoader('MaterialIcons');
      material.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await material.load();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1240, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = SvoiController(PreviewBackend());
    await c.initialize();
    await c.toggleFavorite('1');
    await c.toggleFavorite('3');
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        home: RepaintBoundary(
          key: key,
          child: SvoiShell(controller: c, demo: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> render(String name) async {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../.ui-test/flutter-$clientVersion-$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    }

    await render('overview');
    c.connection.value = {
      'available': true,
      'state': 'running',
      'checked': true,
      'checkedAt': DateTime.now().toIso8601String(),
      'serverId': c.selected.value,
      'mode': c.mode.value,
      'latency': 81,
      'socksPort': 1080,
      'httpPort': 1081,
    };
    await tester.pumpAndSettle();
    await render('connected');
    c.connection.value = {
      ...c.connection.value,
      'checked': false,
      'error': 'Контрольный HTTPS-запрос: время ожидания истекло',
    };
    await tester.pumpAndSettle();
    await render('check-failed');
    c.connection.value = {'available': true, 'state': 'stopped'};
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Серверы').first);
    await tester.pumpAndSettle();
    await render('servers');
    await tester.tap(find.widgetWithText(ListTile, 'zapret').first);
    await tester.pumpAndSettle();
    await render('zapret');
    await tester.tap(find.widgetWithText(ChoiceChip, 'Проверки'));
    await tester.pumpAndSettle();
    await render('zapret-checks');
    tester.view.physicalSize = const Size(800, 600);
    await tester.pumpAndSettle();
    await render('zapret-compact');
    await tester.tap(find.widgetWithText(ListTile, 'Серверы').first);
    await tester.pumpAndSettle();
    await render('compact');
    await tester.tap(find.widgetWithText(ListTile, 'Подключение').first);
    await tester.pumpAndSettle();
    await render('compact-overview');
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
  }, skip: !Platform.isWindows);
}
