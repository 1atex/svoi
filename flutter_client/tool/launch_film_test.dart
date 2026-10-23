import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:svoi_flutter/countries.dart';
import 'package:svoi_flutter/main.dart';

double unit(double x) => x.clamp(0.0, 1.0);
double ease(double x) {
  final v = unit(x);
  return v * v * (3 - 2 * v);
}

double at(double t, double a, double b) => ease((t - a) / (b - a));
double mix(double a, double b, double v) => a + (b - a) * v;
Rect rectMix(Rect a, Rect b, double v) => Rect.lerp(a, b, v)!;

class LaunchFilm {
  LaunchFilm(this.logo, this.flags);
  final ui.Image logo;
  final List<ui.Image> flags;
  late Canvas c;
  final textCache = <String, TextPainter>{};
  static const center = Offset(960, 540);
  static const pill = Rect.fromLTWH(770, 490, 380, 100);
  static const dash = Rect.fromLTWH(490, 240, 940, 620);
  static const list = Rect.fromLTWH(280, 190, 1360, 690);
  static const firstRow = Rect.fromLTWH(320, 350, 1280, 126);
  static const connect = Rect.fromLTWH(520, 150, 880, 780);
  static const config = Rect.fromLTWH(300, 190, 1320, 700);

  void text(
    String value,
    double x,
    double y, {
    double size = 30,
    Color color = ink,
    FontWeight weight = FontWeight.w400,
    bool centered = false,
    String font = 'Segoe UI',
    double width = 1700,
    double spacing = 0,
  }) {
    final key = '$value|$size|$color|$weight|$font|$width|$spacing';
    final p = textCache.putIfAbsent(
      key,
      () => TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(
            fontFamily: font,
            fontSize: size,
            fontWeight: weight,
            color: color,
            letterSpacing: spacing,
            height: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width),
    );
    p.paint(c, Offset(centered ? x - p.width / 2 : x, y));
  }

  void image(ui.Image image, Rect r) => c.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    r,
    Paint()..filterQuality = FilterQuality.high,
  );

  void icon(IconData icon, Offset p, {double size = 30, Color color = muted}) {
    text(
      String.fromCharCode(icon.codePoint),
      p.dx - size / 2,
      p.dy - size / 2,
      size: size,
      color: color,
      font: 'packages/${icon.fontPackage}/${icon.fontFamily}',
    );
  }

  void box(
    Rect r, {
    double radius = 24,
    Color fill = surface,
    Color border = edge,
    double stroke = 1.5,
  }) {
    final shape = RRect.fromRectAndRadius(r, Radius.circular(radius));
    c.drawRRect(shape, Paint()..color = fill);
    c.drawRRect(
      shape,
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
  }

  void clip(Rect r, void Function() draw, {double radius = 0}) {
    c.save();
    c.clipRRect(RRect.fromRectAndRadius(r, Radius.circular(radius)));
    draw();
    c.restore();
  }

  void background(double t) {
    c.drawColor(canvas, BlendMode.src);
    final travel = 25 * math.sin(t / 12 * math.pi * 2);
    final paint = Paint()
      ..color = accent.withValues(alpha: .09)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < 6; i++) {
      final p = Path()
        ..moveTo(860 + i * 90 + travel, -40)
        ..cubicTo(
          600 + i * 110,
          290 + travel,
          1760 + i * 70,
          350,
          1430 + i * 60,
          1120,
        );
      c.drawPath(p, paint);
    }
    text('SVOI  /  WINDOWS', 92, 65, size: 18, color: accent, spacing: 3);
    text('НА СВОИХ УСЛОВИЯХ.', 1430, 65, size: 17, color: muted, spacing: 2.2);
  }

  void brand(double compression) {
    final v = ease(compression);
    final r = rectMix(
      const Rect.fromLTWH(610, 428, 176, 176),
      const Rect.fromLTWH(1220, 550, 32, 32),
      v,
    );
    final visible = 1 - v;
    clip(
      Rect.fromLTWH(r.left, r.top, r.width * visible, r.height),
      () => image(logo, r),
      radius: 32,
    );
    final x = mix(828, 1225, v), y = mix(405, 535, v);
    c.save();
    c.translate(x, y);
    c.scale(mix(1, .08, v), mix(1, .16, v));
    clip(
      Rect.fromLTWH(0, 0, 435 * visible, 220),
      () => text('svoi', 0, 0, size: 190, weight: FontWeight.w700, spacing: -9),
    );
    c.restore();
    c.drawCircle(
      Offset(mix(1260, 1236, v), mix(568, 566, v)),
      15,
      Paint()..color = accent,
    );
    clip(
      Rect.fromLTWH(420, 672, 1080 * visible, 65),
      () => text(
        'Ваши подключения. Ваши правила.',
        960,
        675,
        centered: true,
        size: 32,
        color: muted,
      ),
    );
  }

  void panel(Rect r, double radius, {bool gold = false}) {
    box(
      r,
      radius: radius,
      fill: const Color(0xf51a1a1f),
      border: gold ? const Color(0xff655337) : const Color(0xff3a3a41),
    );
    clip(r.deflate(2), () {
      c.drawRect(
        r,
        Paint()
          ..shader = ui.Gradient.linear(r.topLeft, r.bottomRight, [
            accent.withValues(alpha: gold ? .08 : .025),
            Colors.transparent,
          ]),
      );
      c.drawLine(
        r.topLeft + const Offset(30, 1),
        r.topRight - const Offset(30, -1),
        Paint()..color = ink.withValues(alpha: .10),
      );
    }, radius: radius);
  }

  void header(
    Rect r, {
    bool selected = true,
    double titleScale = 1,
    double fromRow = 0,
  }) {
    image(
      flags[0],
      Rect.fromLTWH(
        r.left + mix(40, 65, fromRow),
        r.top + mix(30, 25, fromRow),
        mix(70, 76, fromRow),
        mix(70, 76, fromRow),
      ),
    );
    text(
      'Finland',
      r.left + mix(130, 164, fromRow),
      r.top + mix(29, 19, fromRow),
      size: mix(40, 37, fromRow) * titleScale,
      weight: FontWeight.w600,
    );
    text(
      selected ? 'Нажмите, чтобы сменить сервер' : 'VLESS · TCP · REALITY',
      r.left + mix(132, 166, fromRow),
      r.top + mix(80, 72, fromRow),
      size: 21,
      color: muted,
    );
    icon(LucideIcons.fileJson, Offset(r.right - 55, r.top + 65), size: 30);
  }

  void power(
    Offset p,
    double diameter,
    double t, {
    bool verified = false,
    bool busy = false,
  }) {
    final color = verified ? success : accent;
    final press = 1 - .045 * math.exp(-math.pow((t - 4.78) / .075, 2));
    c.save();
    c.translate(p.dx, p.dy);
    c.scale(press);
    final base = diameter / 184;
    for (final radius in [91.0, 75.0]) {
      c.drawCircle(
        Offset.zero,
        radius * base,
        Paint()
          ..color = color.withValues(alpha: .19)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }
    c.drawCircle(
      Offset.zero,
      58 * base,
      Paint()
        ..color = verified ? const Color(0xff23362e) : const Color(0xff342b1e),
    );
    c.drawCircle(
      Offset.zero,
      58 * base,
      Paint()
        ..color = color.withValues(alpha: .7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    if (busy) {
      c.drawArc(
        Rect.fromCircle(center: Offset.zero, radius: 23 * base),
        t * 8,
        math.pi * 1.3,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 3 * base,
      );
    } else {
      icon(LucideIcons.power, Offset.zero, size: 40 * base, color: color);
    }
    c.restore();
  }

  void connectionBody(Rect r, double t, {double reveal = 1}) {
    clip(
      Rect.fromLTWH(r.left, r.top + 130, r.width, (r.height - 130) * reveal),
      () {
        final verified = t >= 6 && t < 11;
        final busy = t >= 4.85 && t < 6;
        final y = r.top + 340;
        power(Offset(r.center.dx, y), 300, t, verified: verified, busy: busy);
        final states = [
          'VPN выключен',
          'Подключаемся…',
          'Проверяем интернет…',
          'Подключено',
        ];
        final times = [0.0, 4.85, 5.4, 6.0];
        var state = 0;
        for (var i = 1; i < times.length; i++) {
          if (t >= times[i]) state = i;
        }
        final v = at(t, times[state], times[state] + .18);
        clip(Rect.fromLTWH(r.left, y + 178, r.width, 57), () {
          if (state > 0 && v < 1) {
            text(
              states[state - 1],
              r.center.dx,
              y + 183 - 60 * v,
              size: 37,
              weight: FontWeight.w600,
              centered: true,
            );
          }
          text(
            states[state],
            r.center.dx,
            y + 183 + 60 * (1 - v),
            size: 37,
            weight: FontWeight.w600,
            centered: true,
          );
        });
        if (r.height > 700) {
          final mode = Rect.fromLTWH(
            r.left + 46,
            r.bottom - 126,
            r.width - 92,
            72,
          );
          box(mode, radius: 14, fill: canvas);
          icon(
            LucideIcons.shield,
            Offset(mode.left + 35, mode.center.dy),
            size: 26,
            color: accent,
          );
          text('Все приложения · TUN', mode.left + 65, mode.top + 20, size: 25);
          icon(
            LucideIcons.chevronDown,
            Offset(mode.right - 30, mode.center.dy),
            size: 24,
          );
        }
      },
    );
  }

  void serverList(double t, Rect bounds) {
    final enter = at(t, 1.65, 2.15), exit = at(t, 3.25, 3.65);
    clip(bounds, () {
      clip(
        Rect.fromLTWH(
          list.left + 40,
          list.top + 25,
          list.width - 80,
          100 * (1 - exit),
        ),
        () {
          text(
            'Серверы',
            list.left + 42,
            list.top + 28,
            size: 42,
            weight: FontWeight.w600,
          );
          text(
            'Избранное',
            list.right - 270,
            list.top + 39,
            size: 25,
            color: accent,
          );
          icon(
            LucideIcons.star,
            Offset(list.right - 300, list.top + 55),
            size: 26,
            color: accent,
          );
        },
      );
      for (var i = 2; i >= 0; i--) {
        final stagger = at(t, 1.8 + i * .09, 2.3 + i * .09);
        final y = mix(
          firstRow.top,
          firstRow.top + i * 145,
          stagger * (1 - exit),
        );
        final r = Rect.fromLTWH(
          firstRow.left + 50 * (1 - enter),
          y,
          firstRow.width,
          firstRow.height,
        );
        final selected = i == 0 && t >= 3.05;
        box(
          r,
          radius: 18,
          fill: selected ? const Color(0xff2b261e) : const Color(0xff202025),
          border: selected ? accent : edge,
        );
        image(flags[i], Rect.fromLTWH(r.left + 65, r.top + 25, 76, 76));
        c.drawCircle(
          Offset(r.left + 30, r.center.dy),
          12,
          Paint()
            ..color = selected ? accent : muted
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.4,
        );
        if (selected) {
          c.drawCircle(
            Offset(r.left + 30, r.center.dy),
            6,
            Paint()..color = accent,
          );
        }
        text(
          ['Finland', 'Italy', 'France'][i],
          r.left + 164,
          r.top + 19,
          size: 37,
          weight: FontWeight.w600,
        );
        text(
          i == 1 ? 'VLESS · gRPC · REALITY' : 'VLESS · TCP · REALITY',
          r.left + 166,
          r.top + 72,
          size: 22,
          color: muted,
        );
        icon(
          LucideIcons.star,
          Offset(r.right - 160, r.center.dy),
          size: 31,
          color: i == 0 && t >= 2.65 ? accent : muted,
        );
        if (i == 0 && t >= 2.65) {
          c.drawCircle(
            Offset(r.right - 160, r.center.dy),
            4,
            Paint()..color = accent,
          );
        }
        icon(LucideIcons.fileJson, Offset(r.right - 80, r.center.dy), size: 28);
      }
    }, radius: 24);
  }

  void jsonView(double t, Rect r, double opening) {
    clip(
      Rect.fromLTWH(
        r.left + 36,
        r.top + 128,
        r.width - 72,
        (r.height - 160) * opening,
      ),
      () {
        final tab = at(t, 7.65, 7.88);
        text(
          'Для подключения',
          r.left + 54,
          r.top + 136,
          size: 28,
          color: tab < .5 ? ink : muted,
        );
        text(
          'Исходная',
          r.left + 400,
          r.top + 136,
          size: 28,
          color: tab >= .5 ? ink : muted,
        );
        c.drawLine(
          Offset(mix(r.left + 54, r.left + 400, tab), r.top + 185),
          Offset(mix(r.left + 309, r.left + 544, tab), r.top + 185),
          Paint()
            ..color = accent
            ..strokeWidth = 3,
        );
        final lines = [
          '"routing": {',
          '  "domainStrategy": "AsIs",',
          '  "rules": [{',
          '    "type": "field",',
          '    "inboundTag": ["original-socks"],',
          '    "balancerTag": "entry"',
          '  }]',
          '}',
        ];
        final scroll = 40 * at(t, 8.0, 8.4);
        clip(
          Rect.fromLTWH(
            r.left + 54,
            r.top + 220,
            r.width - 108,
            r.height - 315,
          ),
          () {
            for (var i = 0; i < lines.length; i++) {
              text(
                '${i + 1}',
                r.left + 54,
                r.top + 230 + i * 45 - scroll,
                size: 25,
                color: muted,
                font: 'Consolas',
              );
              text(
                lines[i],
                r.left + 112,
                r.top + 230 + i * 45 - scroll,
                size: 28,
                color: i < 2 ? accent : ink,
                font: 'Consolas',
              );
            }
          },
        );
        text('Закрыть', r.right - 170, r.bottom - 63, size: 27, color: accent);
      },
    );
  }

  Offset cursorAt(double t) {
    final points = <(double, Offset)>[
      (0, const Offset(1780, 1150)),
      (.45, const Offset(1240, 575)),
      (.76, const Offset(1025, 545)),
      (1.48, const Offset(790, 308)),
      (1.85, const Offset(740, 310)),
      (2.58, const Offset(1440, 413)),
      (2.86, const Offset(1440, 413)),
      (3.07, const Offset(350, 413)),
      (3.35, const Offset(480, 460)),
      (4.55, const Offset(975, 500)),
      (4.8, const Offset(975, 500)),
      (5.2, const Offset(1240, 670)),
      (6.45, const Offset(1230, 640)),
      (6.85, const Offset(1345, 215)),
      (7.25, const Offset(1400, 500)),
      (7.65, const Offset(790, 340)),
      (7.9, const Offset(790, 340)),
      (8.2, const Offset(1090, 540)),
      (8.58, const Offset(1510, 835)),
      (9.0, const Offset(1410, 800)),
      (10.1, const Offset(1640, 880)),
      (11.5, const Offset(1780, 1150)),
      (12, const Offset(1780, 1150)),
    ];
    for (var i = 1; i < points.length; i++) {
      if (t <= points[i].$1) {
        return Offset.lerp(
          points[i - 1].$2,
          points[i].$2,
          at(t, points[i - 1].$1, points[i].$1),
        )!;
      }
    }
    return points.last.$2;
  }

  void cursor(double t) {
    final pos = cursorAt(t);
    final clicks = [.78, 1.49, 2.65, 3.08, 4.78, 6.87, 7.68, 8.6];
    var scale = 1.0;
    for (final hit in clicks) {
      if ((t - hit).abs() < .14) {
        scale -= .17 * (1 - (t - hit).abs() / .14);
      }
      if (t > hit && t < hit + .24) {
        c.drawCircle(
          pos,
          12 + 50 * (t - hit),
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8,
        );
      }
    }
    c.save();
    c.translate(pos.dx, pos.dy);
    c.scale(scale);
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(4, 38)
      ..lineTo(14, 27)
      ..lineTo(23, 46)
      ..lineTo(31, 42)
      ..lineTo(22, 23)
      ..lineTo(37, 22)
      ..close();
    c.drawPath(
      path,
      Paint()
        ..color = canvas
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 5,
    );
    c.drawPath(path, Paint()..color = ink);
    c.restore();
  }

  void paint(Canvas canvas, double t) {
    c = canvas;
    background(t);
    if (t <= .5) {
      brand(t / .5);
    } else if (t < 1.05) {
      final dot = Rect.fromCircle(center: const Offset(1236, 566), radius: 15);
      final r = rectMix(dot, pill, at(t, .5, .76));
      panel(r, r.height / 2, gold: true);
      clip(
        r,
        () => text(
          'Подключить',
          r.center.dx,
          r.center.dy - 23,
          centered: true,
          size: 38,
        ),
        radius: r.height / 2,
      );
    } else if (t < 1.65) {
      final r = rectMix(pill, dash, at(t, 1.05, 1.5));
      panel(r, mix(50, 28, at(t, 1.05, 1.5)), gold: true);
      clip(r, () {
        header(r);
        connectionBody(r, t, reveal: at(t, 1.15, 1.55));
      }, radius: 28);
    } else if (t < 3.65) {
      var r = rectMix(dash, list, at(t, 1.65, 2.02));
      if (t > 3.25) {
        r = rectMix(list, firstRow, at(t, 3.25, 3.65));
      }
      panel(r, 24);
      serverList(t, r);
    } else if (t < 6.92) {
      final r = rectMix(firstRow, connect, at(t, 3.65, 4.0));
      panel(r, 28, gold: true);
      clip(r, () {
        header(r);
        connectionBody(r, t, reveal: at(t, 3.78, 4.27));
      }, radius: 28);
    } else if (t < 8.95) {
      final open = at(t, 6.92, 7.25), close = at(t, 8.65, 8.95);
      final r = rectMix(rectMix(connect, config, open), connect, close);
      panel(r, 28, gold: true);
      clip(r, () {
        header(r, selected: false);
        jsonView(t, r, open * (1 - close));
      }, radius: 28);
    } else if (t < 9.45) {
      panel(connect, 28, gold: true);
      header(connect);
      connectionBody(connect, t, reveal: at(t, 8.95, 9.14));
    } else if (t < 10.1) {
      final v = at(t, 9.45, 9.86), r = rectMix(connect, pill, v);
      panel(r, mix(28, 50, v), gold: true);
      clip(r, () {
        header(connect);
        power(
          Offset.lerp(
            const Offset(960, 490),
            Offset(pill.left + 45, pill.center.dy),
            v,
          )!,
          mix(300, 12, v),
          t,
          verified: true,
        );
        text(
          'Подключено',
          mix(960, pill.center.dx + 14, v),
          mix(673, pill.center.dy - 22, v),
          centered: true,
          size: mix(37, 36, v),
          weight: FontWeight.w600,
        );
      }, radius: mix(28, 50, v));
    } else if (t < 10.65) {
      final v = at(t, 10.1, 10.52);
      final r = rectMix(pill, const Rect.fromLTWH(872, 452, 176, 176), v);
      panel(r, mix(50, 42, v), gold: true);
      clip(r, () {
        image(
          logo,
          Rect.fromLTWH(r.center.dx - 88, mix(650, 452, v), 176, 176),
        );
        text(
          'Подключено',
          r.center.dx,
          mix(518, 350, v),
          centered: true,
          size: 36,
        );
      }, radius: 40);
    } else {
      final travel = at(t, 10.65, 11.0);
      if (t < 11) {
        final r = rectMix(
          const Rect.fromLTWH(872, 452, 176, 176),
          const Rect.fromLTWH(1220, 550, 32, 32),
          travel,
        );
        clip(r, () => image(logo, r), radius: mix(40, 16, travel));
      } else {
        brand(1 - at(t, 11, 11.8));
      }
    }
    if (t >= 9.85 && t < 10.95) {
      final show = at(t, 9.85, 10.05) * (1 - at(t, 10.65, 10.95));
      clip(
        Rect.fromLTWH(420, 680, 1080 * show, 75),
        () => text(
          'На связи со своими.',
          960,
          681,
          centered: true,
          size: 43,
          weight: FontWeight.w600,
        ),
      );
    }
    cursor(t);
  }
}

void main() {
  testWidgets(
    'render the approved 12-second SVOI launch film',
    (tester) async {
      await tester.runAsync(() async {
        final fonts = '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts';
        for (final entry in {
          'Segoe UI': ['segoeui.ttf', 'segoeuib.ttf'],
          'Consolas': ['consola.ttf'],
        }.entries) {
          final loader = FontLoader(entry.key);
          for (final file in entry.value) {
            loader.addFont(
              File('$fonts/$file').readAsBytes().then(ByteData.sublistView),
            );
          }
          await loader.load();
        }
        final icons = FontLoader('packages/lucide_icons_flutter/Lucide');
        icons.addFont(
          rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
        );
        await icons.load();
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1920, 1080);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final flags = <ui.Image>[];
      for (final country in ['FI', 'IT', 'FR']) {
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: svoiTheme(),
            home: Center(
              child: RepaintBoundary(
                key: key,
                child: CountryMark(
                  country: ServerCountry(country, ''),
                  large: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          flags.add(
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 3),
          );
        });
      }
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(
          await File('../assets/brand/svoi-avatar-amber.png').readAsBytes(),
        );
        final logo = (await codec.getNextFrame()).image;
        codec.dispose();
        final movie = LaunchFilm(logo, flags);
        final out = Directory('../.ui-preview/launch/frames');
        await out.create(recursive: true);
        final preview = Platform.environment['SVOI_FILM_PREVIEW'] == '1';
        final frames = preview
            ? [
                0,
                24,
                46,
                80,
                112,
                151,
                181,
                220,
                246,
                285,
                318,
                352,
                380,
                414,
                441,
                478,
                511,
                546,
                578,
                613,
                644,
                672,
                705,
                719,
              ]
            : List.generate(720, (i) => i);
        for (final frame in frames) {
          final recorder = ui.PictureRecorder();
          movie.paint(Canvas(recorder), frame == 719 ? 0 : frame / 60.0);
          final picture = recorder.endRecording();
          final image = await picture.toImage(1920, 1080);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${out.path}/${frame.toString().padLeft(4, '0')}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
          if (frame % 120 == 0) {
            debugPrint('Rendered $frame / 720');
          }
        }
        logo.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      for (final flag in flags) {
        flag.dispose();
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
