part of 'main.dart';

enum AppAppearance {
  dark,
  light,
  system,
  halloween,
  ocean,
  emerald,
  rose,
  mono,
}

class AppearanceStore extends ValueNotifier<AppAppearance> {
  AppearanceStore({this.file, AppAppearance initial = AppAppearance.dark})
    : super(initial);
  File? file;
  Future<void> _writes = Future.value();
  final icons = ValueNotifier<UiIconStyle>(UiIconStyle.outline);

  Future<void> load(File source) async {
    file = source;
    try {
      final data = jsonDecode(await source.readAsString()) as Map;
      icons.value =
          UiIconStyle.values
              .where((style) => style.name == data['icons'])
              .firstOrNull ??
          UiIconStyle.outline;
      value =
          AppAppearance.values
              .where((choice) => choice.name == data['theme'])
              .firstOrNull ??
          AppAppearance.dark;
    } on FileSystemException {
      icons.value = UiIconStyle.outline;
      value = AppAppearance.dark;
    } on FormatException {
      icons.value = UiIconStyle.outline;
      value = AppAppearance.dark;
    } on TypeError {
      icons.value = UiIconStyle.outline;
      value = AppAppearance.dark;
    }
  }

  Future<void> select(AppAppearance choice) {
    value = choice;
    return _save();
  }

  Future<void> selectIcons(UiIconStyle choice) {
    icons.value = choice;
    return _save();
  }

  Future<void> _save() {
    final target = file;
    if (target == null) return Future.value();
    final text = jsonEncode({'theme': value.name, 'icons': icons.value.name});
    return _writes = _writes.catchError((Object _) {}).then((_) async {
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(target.path);
    });
  }

  Future<void> flush() => _writes;
  @override
  void dispose() {
    icons.dispose();
    super.dispose();
  }
}

class AppearanceScope extends InheritedNotifier<AppearanceStore> {
  AppearanceScope({
    super.key,
    required AppearanceStore store,
    required Widget child,
  }) : super(
         notifier: store,
         child: UiIconScope(notifier: store.icons, child: child),
       );
  static AppearanceStore? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}

@immutable
class SvoiColors extends ThemeExtension<SvoiColors> {
  const SvoiColors({
    required this.canvas,
    required this.surface,
    required this.raised,
    required this.edge,
    required this.muted,
    required this.accent,
    required this.ink,
    required this.success,
    required this.error,
    required this.onAccent,
    required this.titlebar,
    required this.selected,
    required this.errorSurface,
    required this.powerOff,
    required this.powerOn,
    required this.heroTint,
    required this.brightness,
    this.halloween = false,
  });
  final Color canvas,
      surface,
      raised,
      edge,
      muted,
      accent,
      ink,
      success,
      error,
      onAccent,
      titlebar,
      selected,
      errorSurface,
      powerOff,
      powerOn,
      heroTint;
  final Brightness brightness;
  final bool halloween;

  static const dark = SvoiColors(
    canvas: Color(0xff101013),
    surface: Color(0xff19191e),
    raised: Color(0xff232329),
    edge: Color(0xff303037),
    muted: Color(0xffaaa8a3),
    accent: Color(0xffe7b96a),
    ink: Color(0xfff4f2ed),
    success: Color(0xff91d9b5),
    error: Color(0xffffaaa6),
    onAccent: Color(0xff101013),
    titlebar: Color(0xff141417),
    selected: Color(0xff30291e),
    errorSurface: Color(0xff382327),
    powerOff: Color(0xff342b1e),
    powerOn: Color(0xff23362e),
    heroTint: Color(0xff262219),
    brightness: Brightness.dark,
  );
  static const light = SvoiColors(
    canvas: Color(0xfff3f6fb),
    surface: Colors.white,
    raised: Color(0xffe9eef7),
    edge: Color(0xffcbd4e2),
    muted: Color(0xff576477),
    accent: Color(0xff2456c9),
    ink: Color(0xff172337),
    success: Color(0xff167043),
    error: Color(0xffb4232d),
    onAccent: Colors.white,
    titlebar: Colors.white,
    selected: Color(0xffe5edff),
    errorSurface: Color(0xffffe8e6),
    powerOff: Color(0xffe1ebff),
    powerOn: Color(0xffdcefe7),
    heroTint: Color(0xffeef4ff),
    brightness: Brightness.light,
  );
  static const pumpkin = SvoiColors(
    canvas: Color(0xff0d0f15),
    surface: Color(0xff171a23),
    raised: Color(0xff232735),
    edge: Color(0xff353b4b),
    muted: Color(0xffb6bac8),
    accent: Color(0xffff982f),
    ink: Color(0xfff5f6fa),
    success: Color(0xff81ddbb),
    error: Color(0xffffaaa6),
    onAccent: Color(0xff171b22),
    titlebar: Color(0xff11141b),
    selected: Color(0xff252b37),
    errorSurface: Color(0xff342128),
    powerOff: Color(0xff242935),
    powerOn: Color(0xff1c3530),
    heroTint: Color(0xff171c28),
    brightness: Brightness.dark,
    halloween: true,
  );
  static final ocean = _night(
    accent: const Color(0xff84b9ff),
    canvas: const Color(0xff0b1220),
    surface: const Color(0xff141f30),
    raised: const Color(0xff202d42),
    edge: const Color(0xff30405a),
    muted: const Color(0xffb0bfd4),
    ink: const Color(0xffeff5ff),
  );
  static final emerald = _night(
    accent: const Color(0xff62e4b5),
    canvas: const Color(0xff0a1513),
    surface: const Color(0xff12221f),
    raised: const Color(0xff1d302b),
    edge: const Color(0xff30463f),
    muted: const Color(0xffabc8bd),
    ink: const Color(0xffedfff7),
  );
  static final rose = _night(
    accent: const Color(0xffff9acb),
    canvas: const Color(0xff160f18),
    surface: const Color(0xff221925),
    raised: const Color(0xff322737),
    edge: const Color(0xff49394d),
    muted: const Color(0xffcfb6cb),
    ink: const Color(0xfffff1fc),
  );
  static final mono = _night(
    accent: const Color(0xffe7eaee),
    canvas: Colors.black,
    surface: const Color(0xff08080a),
    raised: const Color(0xff121215),
    edge: const Color(0xff29292e),
    muted: const Color(0xffb0b5bd),
    ink: const Color(0xfff5f6f8),
  );

  static SvoiColors _night({
    required Color accent,
    required Color canvas,
    required Color surface,
    required Color raised,
    required Color edge,
    required Color muted,
    required Color ink,
  }) => SvoiColors(
    canvas: canvas,
    surface: surface,
    raised: raised,
    edge: edge,
    muted: muted,
    accent: accent,
    ink: ink,
    success: const Color(0xff8de0b5),
    error: const Color(0xffffaaa6),
    onAccent: const Color(0xff071219),
    titlebar: canvas,
    selected: Color.alphaBlend(accent.withValues(alpha: .12), surface),
    errorSurface: const Color(0xff342128),
    powerOff: Color.alphaBlend(accent.withValues(alpha: .14), surface),
    powerOn: const Color(0xff1b352b),
    heroTint: raised,
    brightness: Brightness.dark,
  );
  static SvoiColors forAppearance(AppAppearance appearance) =>
      switch (appearance) {
        AppAppearance.light => light,
        AppAppearance.halloween => pumpkin,
        AppAppearance.ocean => ocean,
        AppAppearance.emerald => emerald,
        AppAppearance.rose => rose,
        AppAppearance.mono => mono,
        _ => dark,
      };
  @override
  SvoiColors copyWith() => this;
  @override
  SvoiColors lerp(covariant SvoiColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return SvoiColors(
      canvas: mix(canvas, other.canvas),
      surface: mix(surface, other.surface),
      raised: mix(raised, other.raised),
      edge: mix(edge, other.edge),
      muted: mix(muted, other.muted),
      accent: mix(accent, other.accent),
      ink: mix(ink, other.ink),
      success: mix(success, other.success),
      error: mix(error, other.error),
      onAccent: mix(onAccent, other.onAccent),
      titlebar: mix(titlebar, other.titlebar),
      selected: mix(selected, other.selected),
      errorSurface: mix(errorSurface, other.errorSurface),
      powerOff: mix(powerOff, other.powerOff),
      powerOn: mix(powerOn, other.powerOn),
      heroTint: mix(heroTint, other.heroTint),
      brightness: t < .5 ? brightness : other.brightness,
      halloween: t < .5 ? halloween : other.halloween,
    );
  }
}

SvoiColors appColors(BuildContext context) =>
    Theme.of(context).extension<SvoiColors>() ?? SvoiColors.dark;

ThemeData svoiTheme({SvoiColors palette = SvoiColors.dark}) {
  final p = palette;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: p.accent,
        brightness: p.brightness,
      ).copyWith(
        primary: p.accent,
        onPrimary: p.onAccent,
        surface: p.surface,
        onSurface: p.ink,
        surfaceContainerHighest: p.raised,
        outline: p.edge,
        error: p.error,
      );
  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    fontFamily: 'Segoe UI',
    extensions: [p],
    colorScheme: scheme,
    scaffoldBackgroundColor: p.canvas,
    splashFactory: NoSplash.splashFactory,
    hoverColor: p.ink.withValues(alpha: .04),
    listTileTheme: ListTileThemeData(
      iconColor: p.muted,
      textColor: p.ink,
      selectedColor: p.accent,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: p.muted),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        textStyle: const TextStyle(
          fontFamily: 'Segoe UI',
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: p.edge),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
    ),
    dividerColor: p.edge,
    dividerTheme: DividerThemeData(color: p.edge, thickness: 1, space: 1),
    cardTheme: const CardThemeData(elevation: 0),
    chipTheme: ChipThemeData(
      backgroundColor: p.surface,
      selectedColor: p.selected,
      side: BorderSide(color: p.edge),
      checkmarkColor: p.accent,
      labelStyle: TextStyle(fontFamily: 'Segoe UI', fontSize: 12, color: p.ink),
      iconTheme: IconThemeData(color: p.muted, size: 15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(100, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(100, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.canvas,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: p.edge),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: p.edge),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(p.muted.withValues(alpha: .6)),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(6),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}

class AppearancePanel extends StatelessWidget {
  const AppearancePanel({super.key});
  @override
  Widget build(BuildContext context) {
    final store = AppearanceScope.of(context);
    if (store == null) return const SizedBox.shrink();
    final labels = {
      AppAppearance.dark: 'Классика',
      AppAppearance.light: 'Светлая',
      AppAppearance.system: Platform.isLinux
          ? 'Как в системе'
          : 'Как в Windows',
      AppAppearance.ocean: 'Океан',
      AppAppearance.emerald: 'Изумруд',
      AppAppearance.rose: 'Роза',
      AppAppearance.mono: 'AMOLED',
      AppAppearance.halloween: 'Хэллоуин',
    };
    return Section(
      'Оформление',
      subtitle: 'Тема меняется сразу и сохраняется на этом устройстве.',
      children: [
        IconStylePicker(store: store),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, bounds) => Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final choice in labels.keys)
                SizedBox(
                  width: bounds.maxWidth >= 720
                      ? (bounds.maxWidth - 36) / 4
                      : (bounds.maxWidth - 12) / 2,
                  child: _AppearanceCard(
                    choice: choice,
                    label: labels[choice]!,
                    selected: store.value == choice,
                    onPressed: () async {
                      try {
                        await store.select(choice);
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Тема применена, но не сохранена. Проверьте доступ к папке данных и выберите тему ещё раз.',
                              ),
                            ),
                          );
                        }
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class IconStylePicker extends StatelessWidget {
  const IconStylePicker({super.key, required this.store});
  final AppearanceStore store;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<UiIconStyle>(
    valueListenable: store.icons,
    builder: (context, selected, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Иконки интерфейса',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'Стиль применяется ко всем экранам и не меняет тему.',
          style: TextStyle(color: appColors(context).muted),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, bounds) => Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final style in UiIconStyle.values)
                SizedBox(
                  width: bounds.maxWidth >= 440
                      ? (bounds.maxWidth - 12) / 2
                      : bounds.maxWidth,
                  child: Semantics(
                    button: true,
                    selected: selected == style,
                    label: style == UiIconStyle.outline
                        ? 'Контурные иконки'
                        : 'Двухцветные иконки',
                    child: Material(
                      color: selected == style
                          ? appColors(context).selected
                          : appColors(context).surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: selected == style
                              ? appColors(context).accent
                              : appColors(context).edge,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        key: ValueKey('icons-${style.name}'),
                        onTap: () async {
                          try {
                            await store.selectIcons(style);
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Стиль применён, но не сохранён. Выберите его ещё раз, чтобы повторить сохранение.',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  for (final icon in [
                                    LucideIcons.shield,
                                    LucideIcons.network,
                                    LucideIcons.gauge,
                                  ])
                                    Padding(
                                      padding: const EdgeInsets.only(right: 14),
                                      child: SvoiIcon(
                                        icon,
                                        size: 26,
                                        color: appColors(context).accent,
                                        style: style,
                                      ),
                                    ),
                                  const Spacer(),
                                  if (selected == style)
                                    SvoiIcon(
                                      LucideIcons.check,
                                      size: 18,
                                      color: appColors(context).accent,
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                style == UiIconStyle.outline
                                    ? 'Контурные'
                                    : 'Двухцветные',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard({
    required this.choice,
    required this.label,
    required this.selected,
    required this.onPressed,
  });
  final AppAppearance choice;
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final p =
        choice == AppAppearance.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.light
        ? SvoiColors.light
        : SvoiColors.forAppearance(choice);
    final current = appColors(context);
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: Material(
        color: current.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? current.accent : current.edge,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('theme-${choice.name}'),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 64,
                  decoration: BoxDecoration(
                    color: p.canvas,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: p.edge),
                  ),
                  padding: const EdgeInsets.all(9),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 0; i < 3; i++)
                              Container(
                                height: 7,
                                margin: const EdgeInsets.only(bottom: 5),
                                decoration: BoxDecoration(
                                  color: i == 0 ? p.selected : p.surface,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (choice == AppAppearance.halloween)
                        CustomPaint(
                          size: const Size(32, 32),
                          painter: PumpkinPainter(p.accent),
                        )
                      else
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: p.powerOff,
                            shape: BoxShape.circle,
                            border: Border.all(color: p.accent),
                          ),
                          child: SvoiIcon(
                            LucideIcons.power,
                            color: p.accent,
                            size: 15,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: current.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (selected)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: SvoiIcon(
                          LucideIcons.circleCheck,
                          size: 18,
                          color: current.accent,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SeasonalBackdrop extends StatelessWidget {
  const SeasonalBackdrop({super.key});
  @override
  Widget build(BuildContext context) {
    final p = appColors(context);
    if (!p.halloween) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: HalloweenBackdrop(p.accent),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class PumpkinPainter extends CustomPainter {
  const PumpkinPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 32, size.height / 32);
    final fill = Paint()..color = color;
    canvas.drawOval(const Rect.fromLTWH(2, 9, 21, 21), fill);
    canvas.drawOval(const Rect.fromLTWH(10, 9, 20, 21), fill);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(14, 3, 4, 9),
        const Radius.circular(2),
      ),
      fill,
    );
    final face = Paint()..color = const Color(0xff211207);
    canvas.drawPath(
      Path()
        ..moveTo(8, 17)
        ..lineTo(12, 13)
        ..lineTo(14, 19)
        ..close(),
      face,
    );
    canvas.drawPath(
      Path()
        ..moveTo(18, 19)
        ..lineTo(20, 13)
        ..lineTo(24, 17)
        ..close(),
      face,
    );
    canvas.drawPath(
      Path()
        ..moveTo(8, 22)
        ..lineTo(13, 24)
        ..lineTo(16, 22)
        ..lineTo(19, 24)
        ..lineTo(24, 22)
        ..lineTo(21, 27)
        ..lineTo(11, 27)
        ..close(),
      face,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant PumpkinPainter oldDelegate) =>
      color != oldDelegate.color;
}

class HalloweenBackdrop extends CustomPainter {
  const HalloweenBackdrop(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(0, 72);
    final width = size.width >= 1000 ? size.width - 360 : size.width;
    final origin = Offset(width, 0);
    final web = Paint()
      ..color = color.withValues(alpha: .13)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final ends = [
      Offset(width - 240, 0),
      Offset(width - 220, 75),
      Offset(width - 165, 160),
      Offset(width - 75, 220),
      Offset(width, 240),
    ];
    for (final end in ends) {
      canvas.drawLine(origin, end, web);
    }
    for (final fraction in [.22, .44, .66, .88]) {
      final path = Path();
      for (var i = 0; i < ends.length; i++) {
        final point = Offset.lerp(origin, ends[i], fraction)!;
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.quadraticBezierTo(
            width - (width - ends[i - 1].dx) * fraction * .7,
            ends[i - 1].dy * fraction * .7,
            point.dx,
            point.dy,
          );
        }
      }
      canvas.drawPath(path, web);
    }
    final bat = Paint()..color = color.withValues(alpha: .15);
    for (final placement in [
      (size.width * .45, 34.0, .8),
      (size.width * .6, 94.0, .55),
    ]) {
      canvas.save();
      canvas.translate(placement.$1, placement.$2);
      canvas.scale(placement.$3);
      canvas.drawPath(
        Path()
          ..moveTo(-24, -8)
          ..quadraticBezierTo(-12, -6, -7, 0)
          ..lineTo(-4, -5)
          ..lineTo(0, -2)
          ..lineTo(4, -5)
          ..lineTo(7, 0)
          ..quadraticBezierTo(12, -6, 24, -8)
          ..quadraticBezierTo(17, 2, 16, 10)
          ..quadraticBezierTo(9, 3, 4, 10)
          ..lineTo(0, 15)
          ..lineTo(-4, 10)
          ..quadraticBezierTo(-9, 3, -16, 10)
          ..quadraticBezierTo(-17, 2, -24, -8)
          ..close(),
        bat,
      );
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant HalloweenBackdrop oldDelegate) =>
      color != oldDelegate.color;
}
