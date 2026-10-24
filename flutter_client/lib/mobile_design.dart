part of 'main.dart';

ThemeData mobileTheme(ThemeData base) => base.copyWith(
  textTheme: base.textTheme
      .apply(fontFamily: 'Roboto')
      .copyWith(
        bodyMedium: const TextStyle(
          fontFamily: 'Roboto',
          fontSize: 14,
          height: 1.45,
          color: ink,
        ),
        titleMedium: const TextStyle(
          fontFamily: 'Roboto',
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
      ),
  appBarTheme: const AppBarTheme(
    backgroundColor: canvas,
    surfaceTintColor: Colors.transparent,
    centerTitle: false,
    titleSpacing: 20,
    toolbarHeight: 72,
    titleTextStyle: TextStyle(
      fontSize: 25,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      foregroundColor: accent,
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      minimumSize: const Size(48, 44),
    ),
  ),
  cardTheme: CardThemeData(
    color: surface,
    surfaceTintColor: Colors.transparent,
    margin: const EdgeInsets.only(bottom: 10),
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: edge),
    ),
  ),
  listTileTheme: const ListTileThemeData(
    iconColor: muted,
    textColor: ink,
    selectedColor: accent,
    titleTextStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    subtitleTextStyle: TextStyle(fontSize: 13, color: muted, height: 1.4),
    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
  ),
  navigationBarTheme: base.navigationBarTheme.copyWith(
    height: 72,
    backgroundColor: canvas,
    indicatorColor: accent.withValues(alpha: .12),
    surfaceTintColor: Colors.transparent,
  ),
);

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
      color: surface,
      gradient: hero
          ? const LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [Color(0xff29251f), Color(0xff1b1b20), surface],
              stops: [0, .5, 1],
            )
          : null,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: hero ? const Color(0xff494031) : edge),
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
    final busy = c.busy.value || view.phase.isNotEmpty;
    final action = view.running ? 'Отключить VPN' : 'Подключить VPN';
    final color = view.verified ? success : accent;
    return MobilePanel(
      hero: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'ПОДКЛЮЧЕНИЕ',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.6,
                    color: muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: view.running ? color : muted,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                view.running ? 'VPN включён' : 'VPN выключен',
                style: TextStyle(
                  fontSize: 12,
                  color: view.running ? color : muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked =
                  MediaQuery.textScalerOf(context).scale(16) > 21 ||
                  constraints.maxWidth < 270;
              final text = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    view.phase.isNotEmpty
                        ? view.title
                        : view.verified
                        ? 'Вы на связи'
                        : view.running
                        ? 'VPN работает'
                        : 'VPN\nвыключен',
                    style: const TextStyle(
                      fontSize: 27,
                      fontWeight: FontWeight.w700,
                      height: 1.13,
                      letterSpacing: -.6,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    view.phase.isNotEmpty
                        ? view.detail
                        : view.verified
                        ? 'Интернет проверен'
                        : view.running
                        ? 'Интернет ещё не подтверждён'
                        : 'Подключитесь одним нажатием',
                    style: const TextStyle(
                      fontSize: 13,
                      color: muted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: busy ? null : c.toggleConnection,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      alignment: Alignment.centerLeft,
                    ),
                    child: Text(action),
                  ),
                ],
              );
              final power = Container(
                width: 128,
                height: 128,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: color.withValues(alpha: .18)),
                ),
                child: Container(
                  width: 104,
                  height: 104,
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: color.withValues(alpha: .12)),
                  ),
                  child: IconButton(
                    key: const ValueKey('mobile-power'),
                    tooltip: action,
                    onPressed: busy ? null : c.toggleConnection,
                    style: IconButton.styleFrom(
                      backgroundColor: color.withValues(alpha: .12),
                      foregroundColor: color,
                      disabledForegroundColor: muted,
                      side: BorderSide(color: color.withValues(alpha: .55)),
                    ),
                    icon: view.phase.isNotEmpty
                        ? SizedBox(
                            width: 32,
                            height: 32,
                            child: MediaQuery.disableAnimationsOf(context)
                                ? const Icon(Icons.more_horiz)
                                : CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: color,
                                  ),
                          )
                        : const Icon(
                            Icons.power_settings_new_rounded,
                            size: 39,
                          ),
                  ),
                ),
              );
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
            color: canvas.withValues(alpha: .65),
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
                style: const TextStyle(fontSize: 12, color: muted),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: onServer,
            ),
          ),
          if (view.running)
            TextButton.icon(
              onPressed: busy ? null : c.check,
              icon: const Icon(Icons.network_check, size: 18),
              label: const Text('Проверить интернет'),
            ),
        ],
      ),
    );
  }
}
