part of 'main.dart';

ShadThemeData _buttonTheme(BuildContext context) => ShadThemeData(
  brightness: appColors(context).brightness,
  textTheme: ShadTextTheme(family: 'Segoe UI'),
  colorScheme:
      (appColors(context).brightness == Brightness.dark
              ? const ShadZincColorScheme.dark()
              : const ShadZincColorScheme.light())
          .copyWith(
            primary: appColors(context).accent,
            primaryForeground: appColors(context).onAccent,
            background: appColors(context).canvas,
            foreground: appColors(context).ink,
            border: appColors(context).edge,
            secondary: appColors(context).raised,
            secondaryForeground: appColors(context).ink,
            muted: appColors(context).surface,
            mutedForeground: appColors(context).muted,
          ),
  radius: BorderRadius.circular(10),
);

class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.primary = false,
    this.expand = false,
  });
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary, expand;
  @override
  Widget build(BuildContext context) {
    final child = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
    final leading = icon == null ? null : SvoiIcon(icon, size: 17);
    return ShadTheme(
      data: _buttonTheme(context),
      child: primary
          ? ShadButton(
              onPressed: onPressed,
              enabled: onPressed != null,
              leading: leading,
              width: expand ? double.infinity : null,
              expands: expand,
              height: 46,
              child: child,
            )
          : ShadButton.outline(
              onPressed: onPressed,
              enabled: onPressed != null,
              leading: leading,
              width: expand ? double.infinity : null,
              expands: expand,
              height: 42,
              child: child,
            ),
    );
  }
}

class CountryMark extends StatelessWidget {
  const CountryMark({super.key, required this.country, this.large = false});
  final ServerCountry country;
  final bool large;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: country.label,
    child: Semantics(
      label: country.label,
      image: true,
      child: Container(
        width: large ? 56 : 44,
        height: large ? 56 : 44,
        decoration: BoxDecoration(
          color: appColors(context).raised,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: appColors(context).edge),
        ),
        alignment: Alignment.center,
        child: country.code == null
            ? SvoiIcon(
                LucideIcons.globe,
                size: large ? 24 : 20,
                color: appColors(context).muted,
              )
            : CountryFlag.fromCountryCode(
                country.code!,
                theme: ImageTheme(
                  width: large ? 32 : 26,
                  height: large ? 23 : 19,
                  shape: const RoundedRectangle(3),
                ),
              ),
      ),
    ),
  );
}

class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color});
  final String text;
  final Color? color;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 10,
      letterSpacing: 1.5,
      fontWeight: FontWeight.w600,
      color: color ?? appColors(context).muted,
    ),
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.text, {super.key, this.active = false});
  final String text;
  final bool active;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: active
          ? appColors(context).success.withValues(alpha: .09)
          : appColors(context).raised,
      border: Border.all(
        color: active
            ? appColors(context).success.withValues(alpha: .22)
            : appColors(context).edge,
      ),
      borderRadius: BorderRadius.circular(30),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? appColors(context).success
                : appColors(context).muted,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            color: active
                ? appColors(context).success
                : appColors(context).muted,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ),
  );
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key});
  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.asset(
            'assets/svoi-mark.png',
            width: 42,
            height: 42,
            semanticLabel: 'SVOI',
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          'svoi',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -1,
          ),
        ),
        Text(
          '•',
          style: TextStyle(fontSize: 23, color: appColors(context).accent),
        ),
      ],
    ),
  );
}

class ModePicker extends StatelessWidget {
  const ModePicker({super.key, required this.c});
  final SvoiController c;
  @override
  Widget build(BuildContext context) {
    final routing = Map<String, dynamic>.from(
      c.preferences.value['routing'] ?? {},
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('mode-${c.mode.value}-${routing['mode']}'),
          initialValue: c.mode.value,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Что подключать'),
          items: [
            if (!Platform.isMacOS)
              DropdownMenuItem(
                value: 'tun',
                child: Text(
                  '${modeLabel('tun', routing)} · TUN',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (!Platform.isLinux)
              const DropdownMenuItem(
                value: 'system',
                child: Text(
                  'Приложения с системным прокси',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const DropdownMenuItem(
              value: 'local',
              child: Text(
                'Ручная настройка прокси',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          onChanged: c.busy.value
              ? null
              : (value) {
                  if (value != null) c.setMode(value);
                },
        ),
        const SizedBox(height: 10),
        Text(
          switch (c.mode.value) {
            'tun' when Platform.isLinux =>
              c.connection.value['elevated'] == true
                  ? 'Маршруты из конфигурации сохраняются. DNS управляется системой Linux.'
                  : 'Для TUN установите пакет .deb или настройте сетевые права ядра по LINUX.md.',
            'tun' =>
              c.connection.value['elevated'] == true
                  ? 'Маршруты из конфигурации сохраняются.'
                  : 'TUN требует прав администратора. Маршруты из конфигурации сохраняются.',
            'system' =>
              'Для браузеров и приложений, учитывающих настройки прокси $desktopPlatformName.',
            _ => 'Укажите SOCKS5 или HTTP вручную в приложении. Адреса — в диагностике.',
          },
          style: TextStyle(
            fontSize: 12,
            color: appColors(context).muted,
            height: 1.5,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => showTrafficRules(context, c),
            icon: const SvoiIcon(LucideIcons.appWindow, size: 15),
            label: Text(
              'Правила трафика · ${(c.preferences.value['directDomains'] as List? ?? []).length} сайтов напрямую',
            ),
          ),
        ),
      ],
    );
  }
}
