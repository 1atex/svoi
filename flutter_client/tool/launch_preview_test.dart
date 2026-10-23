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

class LaunchBackend extends DemoBackend {
  LaunchBackend() {
    super.group['name'] = 'Моя сеть';
    super.group['servers'] = [
      for (final entry in [
        ('fi', 'Finland', 'FI'),
        ('it', 'Italy', 'IT'),
        ('fr', 'France', 'FR'),
      ])
        {
          'id': entry.$1,
          'name': entry.$2,
          'countryCode': entry.$3,
          'protocol': 'vless',
          'address': 'example.com',
          'port': 443,
          'network': entry.$1 == 'it' ? 'grpc' : 'tcp',
          'security': 'reality',
          'subscriptionId': 'preview',
        },
    ];
    super.group['subscriptions'] = [
      {
        'id': 'preview',
        'name': 'Пример подписки',
        'count': 3,
        'host': 'example.com',
        'remote': false,
      },
    ];
  }

  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path == 'connection') return {'available': true, 'state': 'stopped'};
    if (path.startsWith('zapret')) {
      return {
        'running': false,
        'strategies': <String>[],
        'job': <String, dynamic>{},
      };
    }
    if (path == 'updates') return {'state': 'idle'};
    if (path == 'settings') {
      return {'autoRefresh': false, 'autoUpdate': true, 'autoDownload': false};
    }
    return super.request(
      path,
      method: method,
      body: body,
      cancellation: cancellation,
    );
  }
}

Widget label(String value, {Color color = muted}) => Text(
  value,
  style: TextStyle(
    color: color,
    fontSize: 17,
    letterSpacing: 2.8,
    fontWeight: FontWeight.w500,
  ),
);

Widget title(String value, {double size = 82}) => Text(
  value,
  style: TextStyle(
    color: ink,
    fontSize: size,
    height: 1.08,
    letterSpacing: -3,
    fontWeight: FontWeight.w600,
  ),
);

Widget mark(double size) => ClipRRect(
  borderRadius: BorderRadius.circular(size * .24),
  child: Image.asset('assets/svoi-mark.png', width: size, height: size),
);

class Contours extends CustomPainter {
  const Contours();
  @override
  void paint(Canvas c, Size size) {
    final p = Paint()
      ..color = accent.withValues(alpha: .10)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(740 + i * 92, -350 + i * 70, 1120, 1300),
          const Radius.circular(440),
        ),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(Contours oldDelegate) => false;
}

Widget stage(Widget child, {String? footer}) => Material(
  color: canvas,
  child: Stack(
    children: [
      const Positioned.fill(child: CustomPaint(painter: Contours())),
      Positioned(
        left: 88,
        top: 66,
        child: label('SVOI  /  WINDOWS', color: accent),
      ),
      Positioned(right: 88, top: 66, child: label('НА СВОИХ УСЛОВИЯХ.')),
      Positioned.fill(child: child),
      if (footer != null)
        Positioned(left: 88, bottom: 62, child: label(footer)),
    ],
  ),
);

Widget framed(Widget child) => Container(
  decoration: BoxDecoration(
    color: canvas,
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: edge),
  ),
  clipBehavior: Clip.antiAlias,
  child: child,
);

Widget wordmark() => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    mark(176),
    const SizedBox(width: 42),
    const Text(
      'svoi',
      style: TextStyle(
        fontSize: 208,
        height: 1,
        fontWeight: FontWeight.w700,
        letterSpacing: -12,
      ),
    ),
    Container(
      width: 27,
      height: 27,
      margin: const EdgeInsets.only(left: 10, top: 105),
      decoration: const BoxDecoration(color: accent, shape: BoxShape.circle),
    ),
  ],
);

Widget brandFrame() => stage(
  Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        wordmark(),
        const SizedBox(height: 50),
        const Text(
          'Ваши подключения. Ваши правила.',
          style: TextStyle(color: muted, fontSize: 31, letterSpacing: -.5),
        ),
      ],
    ),
  ),
);

Widget configFrame(SvoiController c) => stage(
  Stack(
    children: [
      Positioned(
        left: 88,
        top: 290,
        width: 470,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label('01  /  КОНФИГУРАЦИИ', color: accent),
            const SizedBox(height: 32),
            title('Всё своё.\nПод рукой.'),
            const SizedBox(height: 32),
            const Text(
              'Подписки, избранное\nи конфигурация каждого сервера.',
              style: TextStyle(fontSize: 25, height: 1.5, color: muted),
            ),
            const SizedBox(height: 46),
            label('VLESS  ·  VMESS\nTROJAN  ·  SHADOWSOCKS'),
          ],
        ),
      ),
      Positioned(
        left: 610,
        top: 222,
        width: 1222,
        height: 638,
        child: framed(ServerPage(c: c)),
      ),
    ],
  ),
  footer: 'ВАШИ ПОДПИСКИ → ВАШ ВЫБОР',
);

Widget connectionFrame(SvoiController c) => stage(
  Stack(
    children: [
      Positioned(
        left: 88,
        top: 300,
        width: 700,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label('02  /  ПОДКЛЮЧЕНИЕ', color: accent),
            const SizedBox(height: 32),
            title('В центре —\nодно действие.', size: 88),
            const SizedBox(height: 34),
            const Text(
              'Выберите сервер.\nНажмите на кнопку питания.',
              style: TextStyle(fontSize: 27, height: 1.5, color: muted),
            ),
          ],
        ),
      ),
      Positioned(
        left: 990,
        top: 155,
        width: 650,
        height: 830,
        child: SingleChildScrollView(child: ConnectionCard(c: c)),
      ),
    ],
  ),
  footer: 'TUN  /  СИСТЕМНЫЙ ПРОКСИ  /  РУЧНОЙ ПРОКСИ',
);

Widget finalFrame(SvoiController c) => stage(
  Stack(
    children: [
      Positioned(
        left: 88,
        top: 228,
        child: title('На связи со своими.', size: 76),
      ),
      Positioned(
        left: 870,
        top: 350,
        width: 960,
        height: 650,
        child: framed(
          FittedBox(
            fit: BoxFit.contain,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 1320,
              height: 900,
              child: Overview(c: c, onServers: () {}),
            ),
          ),
        ),
      ),
      Positioned(
        left: 88,
        top: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            mark(122),
            const SizedBox(height: 36),
            const Text(
              'SVOI',
              style: TextStyle(
                fontSize: 76,
                fontWeight: FontWeight.w700,
                letterSpacing: -3,
              ),
            ),
            const SizedBox(height: 24),
            label('ОТКРЫТЫЙ КОД.\nВАШИ ПОДПИСКИ.'),
          ],
        ),
      ),
    ],
  ),
  footer: 'ДАЛЕЕ: ЭКРАН → СИМВОЛ → SVOI',
);

void main() {
  testWidgets(
    'render sanitized product screenshots and launch approval stills',
    (tester) async {
      await tester.runAsync(() async {
        final fonts = '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts';
        final loader = FontLoader('Segoe UI');
        for (final name in ['segoeui.ttf', 'segoeuib.ttf']) {
          loader.addFont(
            File('$fonts/$name').readAsBytes().then(ByteData.sublistView),
          );
        }
        await loader.load();
        final icons = FontLoader('packages/lucide_icons_flutter/Lucide');
        icons.addFont(
          rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
        );
        await icons.load();
        final material = FontLoader('MaterialIcons');
        material.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await material.load();
        await Directory('../docs/assets').create(recursive: true);
        await Directory('../.ui-preview/launch').create(recursive: true);
      });
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = SvoiController(LaunchBackend());
      await c.initialize();
      c.mode.value = 'tun';
      await c.toggleFavorite('fi');
      final key = GlobalKey();
      Future<void> show(Widget widget, Size size) async {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: svoiTheme(),
              home: widget,
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
      }

      Future<void> save(String path) async {
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(path).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await show(SvoiShell(controller: c, demo: true), const Size(1440, 960));
      await save('../docs/assets/overview.png');
      for (final entry in [
        ('Серверы', 'servers'),
        ('Приложения', 'applications'),
        ('zapret', 'zapret'),
        ('Настройки', 'settings'),
      ]) {
        await tester.tap(find.widgetWithText(ListTile, entry.$1).first);
        await tester.pumpAndSettle();
        await save('../docs/assets/${entry.$2}.png');
      }
      await tester.tap(find.widgetWithText(ListTile, 'Подключение').first);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Overview));
      showServerPicker(context, c);
      await tester.pumpAndSettle();
      await save('../docs/assets/selector.png');
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      await show(brandFrame(), const Size(1920, 1080));
      await save('../.ui-preview/launch/01-brand.png');
      await save('../.ui-preview/launch/05-loop-end.png');
      await show(configFrame(c), const Size(1920, 1080));
      await save('../.ui-preview/launch/02-configurations.png');
      await show(connectionFrame(c), const Size(1920, 1080));
      await save('../.ui-preview/launch/03-connection.png');
      c.connection.value = {
        'available': true,
        'state': 'running',
        'checked': false,
        'serverId': 'fi',
        'mode': 'tun',
      };
      await show(finalFrame(c), const Size(1920, 1080));
      await save('../.ui-preview/launch/04-final.png');
      await show(
        stage(
          Stack(
            children: [
              Positioned(
                left: 88,
                top: 180,
                child: Row(
                  children: [
                    mark(130),
                    const SizedBox(width: 36),
                    title('svoi.', size: 148),
                  ],
                ),
              ),
              Positioned(
                left: 88,
                top: 375,
                child: title('На своих условиях.', size: 65),
              ),
              const Positioned(
                left: 88,
                top: 474,
                child: Text(
                  'VPN-клиент для Windows  /  Flutter + Xray',
                  style: TextStyle(fontSize: 26, color: muted),
                ),
              ),
              Positioned(
                right: 88,
                top: 215,
                child: Container(
                  width: 190,
                  height: 190,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: accent.withValues(alpha: .35)),
                  ),
                  child: const Icon(
                    Icons.power_settings_new,
                    size: 72,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Size(1440, 620),
      );
      await save('../docs/assets/hero.png');
      final images = <ui.Image>[];
      await tester.runAsync(() async {
        for (final name in [
          '01-brand',
          '02-configurations',
          '03-connection',
          '04-final',
        ]) {
          final codec = await ui.instantiateImageCodec(
            await File('../.ui-preview/launch/$name.png').readAsBytes(),
          );
          images.add((await codec.getNextFrame()).image);
          codec.dispose();
        }
      });
      await show(
        Material(
          color: canvas,
          child: Column(
            children: [
              for (var row = 0; row < 2; row++)
                Row(
                  children: [
                    for (var col = 0; col < 2; col++)
                      SizedBox(
                        width: 960,
                        height: 540,
                        child: RawImage(image: images[row * 2 + col]),
                      ),
                  ],
                ),
            ],
          ),
        ),
        const Size(1920, 1080),
      );
      await save('../.ui-preview/launch/contact-sheet.png');
      await tester.pumpWidget(const SizedBox.shrink());
      for (final image in images) {
        image.dispose();
      }
      await c.close();
    },
    skip: !Platform.isWindows,
  );
}
