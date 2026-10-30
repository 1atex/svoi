part of 'main.dart';

ThemeData mobileTheme(ThemeData base) {
  final p = base.extension<SvoiColors>() ?? SvoiColors.dark;
  return base.copyWith(
    textTheme: base.textTheme
        .apply(fontFamily: 'Roboto')
        .copyWith(
          bodyMedium: TextStyle(
            fontFamily: 'Roboto',
            fontSize: 14,
            height: 1.45,
            color: p.ink,
          ),
          titleMedium: TextStyle(
            fontFamily: 'Roboto',
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: p.ink,
          ),
        ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.canvas,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleSpacing: 20,
      toolbarHeight: 64,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: p.brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarColor: p.canvas,
        systemNavigationBarIconBrightness: p.brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
      ),
      titleTextStyle: TextStyle(
        fontFamily: 'Roboto',
        fontSize: 25,
        fontWeight: FontWeight.w700,
        color: p.ink,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        minimumSize: const Size(48, 44),
      ),
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.edge),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.muted,
      textColor: p.ink,
      selectedColor: p.accent,
      titleTextStyle: const TextStyle(
        fontFamily: 'Roboto',
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: 'Roboto',
        fontSize: 13,
        color: p.muted,
        height: 1.4,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: p.canvas,
      indicatorColor: p.selected,
      surfaceTintColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? p.accent : p.muted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: 'Roboto',
          color: states.contains(WidgetState.selected) ? p.accent : p.muted,
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
        ),
      ),
    ),
  );
}

class MobilePanel extends StatelessWidget {
  const MobilePanel({
    super.key,
    required this.child,
    this.hero = false,
    this.padding = const EdgeInsets.all(18),
  });
  final Widget child;
  final bool hero;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: appColors(context).surface,
      gradient: hero
          ? LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [
                appColors(context).heroTint,
                appColors(context).surface,
                appColors(context).surface,
              ],
              stops: [0, .5, 1],
            )
          : null,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(
        color: hero ? appColors(context).edge : appColors(context).edge,
      ),
    ),
    child: child,
  );
}

class MobileConnectionCard extends StatelessWidget {
  const MobileConnectionCard({
    super.key,
    required this.c,
    required this.server,
    required this.onServer,
  });
  final SvoiController c;
  final ServerEntry server;
  final VoidCallback onServer;
  @override
  Widget build(BuildContext context) {
    final view = ConnectionView(c);
    final busy =
        c.busy.value || (view.phase.isNotEmpty && view.phase != 'checking');
    final action = view.running ? 'Отключить VPN' : 'Подключить VPN';
    final color = view.verified
        ? appColors(context).success
        : appColors(context).accent;
    return MobilePanel(
      hero: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              Text(
                'ПОДКЛЮЧЕНИЕ',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.6,
                  color: appColors(context).muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: view.running ? color : appColors(context).muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      view.running ? 'VPN включён' : 'VPN выключен',
                      style: TextStyle(
                        fontSize: 12,
                        color: view.running ? color : appColors(context).muted,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked =
                  MediaQuery.textScalerOf(context).scale(16) > 21 ||
                  constraints.maxWidth < 270;
              final text = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    view.title,
                    style: const TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    view.detail,
                    style: TextStyle(
                      fontSize: 13,
                      color: appColors(context).muted,
                    ),
                  ),
                ],
              );
              final power = appColors(context).halloween
                  ? SizedBox(
                      width: 128,
                      height: 128,
                      child: FittedBox(
                        child: ConnectionOrbit(
                          controlKey: const ValueKey('mobile-power'),
                          running: view.running,
                          verified: view.verified,
                          busy: busy,
                          onPressed: busy ? null : c.toggleConnection,
                          hint: action,
                        ),
                      ),
                    )
                  : Container(
                      width: 128,
                      height: 128,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: color.withValues(alpha: .18)),
                      ),
                      child: Container(
                        width: 88,
                        height: 88,
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color.withValues(alpha: .12),
                          ),
                        ),
                        child: IconButton(
                          key: const ValueKey('mobile-power'),
                          tooltip: action,
                          onPressed: busy ? null : c.toggleConnection,
                          style: IconButton.styleFrom(
                            backgroundColor: color.withValues(alpha: .12),
                            foregroundColor: color,
                            disabledForegroundColor: appColors(context).muted,
                            side: BorderSide(
                              color: color.withValues(alpha: .55),
                            ),
                          ),
                          icon: view.phase.isNotEmpty
                              ? SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: MediaQuery.disableAnimationsOf(context)
                                      ? const SvoiIcon(Icons.more_horiz)
                                      : CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: color,
                                        ),
                                )
                              : const SvoiIcon(
                                  Icons.power_settings_new_rounded,
                                  size: 39,
                                ),
                        ),
                      ),
                    );
              if (!view.needsStatus) return Center(child: power);
              return stacked
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        text,
                        Center(child: power),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(child: text),
                        const SizedBox(width: 8),
                        power,
                      ],
                    );
            },
          ),
          if (view.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                view.error,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ),
          const SizedBox(height: 16),
          Material(
            color: appColors(context).canvas.withValues(alpha: .65),
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 4,
              ),
              leading: CountryMark(country: server.country),
              title: Text(
                server.country.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${server.protocol} · Сменить сервер',
                style: TextStyle(fontSize: 12, color: appColors(context).muted),
              ),
              trailing: const SvoiIcon(Icons.chevron_right_rounded, size: 20),
              onTap: onServer,
            ),
          ),
          const SizedBox(height: 12),
          PublicIPLine(c: c),
          if (view.running)
            TextButton.icon(
              onPressed: busy ? null : c.check,
              icon: const SvoiIcon(Icons.network_check, size: 18),
              label: const Text('Проверить интернет'),
            ),
        ],
      ),
    );
  }
}
