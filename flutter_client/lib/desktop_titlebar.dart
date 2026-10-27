part of 'main.dart';

final windowMaximized = ValueNotifier(false);
final windowMaxHovered = ValueNotifier(false);

class DesktopTitlebar extends StatefulWidget {
  const DesktopTitlebar({super.key, this.page, this.onPage, this.onProfiles});
  final int? page;
  final ValueChanged<int>? onPage;
  final VoidCallback? onProfiles;

  @override
  State<DesktopTitlebar> createState() => _DesktopTitlebarState();
}

class _DesktopTitlebarState extends State<DesktopTitlebar> {
  final _brand = GlobalKey(), _gap = GlobalKey(), _maximize = GlobalKey();
  String _geometry = '';

  void _reportFrame() {
    if (!mounted || !Platform.isWindows) return;
    List<double>? rect(GlobalKey key) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return null;
      final point = box.localToGlobal(Offset.zero);
      return [point.dx, point.dy, box.size.width, box.size.height];
    }

    final geometry = {
      'drag': [?rect(_brand), ?rect(_gap)],
      'maximize': rect(_maximize),
      'dark': appColors(context).brightness == Brightness.dark,
    };
    final encoded = jsonEncode(geometry);
    if (encoded == _geometry) return;
    _geometry = encoded;
    unawaited(_sendWindowCommand('titlebar', geometry));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportFrame());
      final narrow = bounds.maxWidth < 600;
      const tabs = [
        (0, 'Подключение', LucideIcons.power),
        (4, 'zapret', LucideIcons.shield),
        (6, 'Инструменты', LucideIcons.network),
        (5, 'Настройки', LucideIcons.settings2),
      ];
      const tabStyle = TextStyle(
        fontFamily: 'Segoe UI',
        fontSize: 14,
        fontWeight: FontWeight.w600,
      );
      var tabsWidth = 0.0;
      for (final tab in tabs) {
        final painter = TextPainter(
          text: TextSpan(text: tab.$2, style: tabStyle),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        tabsWidth += painter.width + 67;
        painter.dispose();
      }
      final labels =
          tabsWidth <= bounds.maxWidth - 403 &&
          MediaQuery.textScalerOf(context).scale(14) <= 19;
      return Material(
        color: appColors(context).titlebar,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              SizedBox(
                key: _brand,
                width: narrow ? 0 : 64,
                height: 64,
                child: Center(
                  child: Tooltip(
                    message: 'SVOI',
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(9),
                          child: Image.asset(
                            'assets/svoi-mark.png',
                            width: 34,
                            height: 34,
                            semanticLabel: 'SVOI',
                          ),
                        ),
                        if (appColors(context).halloween)
                          Positioned(
                            right: -5,
                            bottom: -4,
                            child: ExcludeSemantics(
                              child: CustomPaint(
                                size: const Size(17, 17),
                                painter: PumpkinPainter(
                                  appColors(context).accent,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.onPage != null)
                for (final (index, label, icon) in tabs)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Tooltip(
                      message: label,
                      child: TextButton(
                        key: ValueKey('desktop-tab-$index'),
                        style: TextButton.styleFrom(
                          minimumSize: Size(narrow ? 40 : 48, 44),
                          padding: EdgeInsets.symmetric(
                            horizontal: labels
                                ? 16
                                : narrow
                                ? 10
                                : 14,
                          ),
                          foregroundColor: widget.page == index
                              ? appColors(context).accent
                              : appColors(context).muted,
                          backgroundColor: widget.page == index
                              ? appColors(context).selected
                              : Colors.transparent,
                          textStyle: tabStyle,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () => widget.onPage!(index),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(icon, size: 20),
                            if (labels) ...[
                              const SizedBox(width: 9),
                              Text(label),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
              Expanded(child: SizedBox(key: _gap, height: 64)),
              if (widget.onProfiles != null) const CommunityButton(),
              if (widget.onProfiles != null && narrow)
                PopupMenuButton<String>(
                  tooltip: 'Действия SVOI',
                  onSelected: (value) {
                    if (value == 'profiles') widget.onProfiles!();
                    if (value == 'tray') unawaited(_sendWindowCommand('tray'));
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'profiles',
                      child: Text('Профили и перенос'),
                    ),
                    PopupMenuItem(
                      value: 'tray',
                      child: Text('Свернуть в трей'),
                    ),
                  ],
                  icon: const Icon(LucideIcons.ellipsis, size: 20),
                ),
              if (widget.onProfiles != null && !narrow) ...[
                IconButton(
                  tooltip: 'Профили и перенос',
                  onPressed: widget.onProfiles,
                  icon: const Icon(LucideIcons.users, size: 20),
                ),
                IconButton(
                  tooltip: 'Свернуть в трей',
                  onPressed: () => _sendWindowCommand('tray'),
                  icon: const Icon(LucideIcons.chevronDown, size: 20),
                ),
                const SizedBox(width: 8),
              ],
              if (Platform.isWindows) ...[
                const VerticalDivider(width: 1, indent: 20, endIndent: 20),
                _CaptionButton(
                  narrow: narrow,
                  label: 'Свернуть',
                  icon: LucideIcons.minus,
                  onPressed: () => _sendWindowCommand('minimize'),
                ),
                ValueListenableBuilder(
                  valueListenable: windowMaximized,
                  builder: (context, maximized, _) => ValueListenableBuilder(
                    valueListenable: windowMaxHovered,
                    builder: (context, hovered, _) => _CaptionButton(
                      narrow: narrow,
                      key: _maximize,
                      label: maximized ? 'Восстановить окно' : 'Развернуть',
                      icon: maximized ? LucideIcons.copy : LucideIcons.square,
                      highlighted: hovered,
                      onPressed: () => _sendWindowCommand('maximize'),
                    ),
                  ),
                ),
                _CaptionButton(
                  narrow: narrow,
                  label: 'Закрыть SVOI',
                  icon: LucideIcons.x,
                  close: true,
                  onPressed: () => _sendWindowCommand('requestWindowClose'),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

Future<void> _sendWindowCommand(String command, [Object? arguments]) async {
  try {
    await windowChannel.invokeMethod(command, arguments);
  } on MissingPluginException {
    return;
  }
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.close = false,
    this.highlighted = false,
    this.narrow = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool close, highlighted, narrow;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: SizedBox(
      width: narrow ? 36 : 46,
      height: 64,
      child: TextButton(
        onPressed: onPressed,
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => close && states.contains(WidgetState.hovered)
                ? Colors.white
                : appColors(context).muted,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.hovered) || highlighted
                ? (close ? const Color(0xffc42b1c) : appColors(context).raised)
                : Colors.transparent,
          ),
        ),
        child: Semantics(label: label, child: Icon(icon, size: 16)),
      ),
    ),
  );
}

class DesktopStartup extends StatelessWidget {
  const DesktopStartup({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const DesktopTitlebar(),
        const Divider(height: 1),
        Expanded(child: child),
      ],
    ),
  );
}
