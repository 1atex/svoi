part of 'main.dart';

class PublicIPLine extends StatefulWidget {
  const PublicIPLine({super.key, required this.c});
  final SvoiController c;
  @override
  State<PublicIPLine> createState() => _PublicIPLineState();
}

class _PublicIPLineState extends State<PublicIPLine> {
  SvoiController get c => widget.c;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) c.enablePublicIP();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c.publicIP, c.connectionPhase]),
    builder: (context, _) {
      final data = c.publicIP.value;
      final ip = data['ip'] as String?;
      final previous = data['previousIP'] as String?;
      final busy = data['busy'] == true;
      final switching = c.connectionPhase.value.isNotEmpty;
      final route = switch (data['via']) {
        'proxy' => 'Через профиль',
        'tun' => 'Маршрут SVOI в TUN',
        _ => 'Без подключения SVOI',
      };
      final detail = ip == null
          ? 'Проверка через ipify'
          : previous == null
          ? route
          : previous == ip
          ? 'IP не изменился'
          : 'IP изменился';
      return Tooltip(
        message:
            'Внешний IP запроса SVOI к api64.ipify.org. При маршрутизации по приложениям и сайтам другие запросы могут иметь другой IP.${previous == null ? '' : '\nДо подключения: $previous'}',
        child: Row(
          children: [
            Icon(LucideIcons.globe, size: 16, color: appColors(context).muted),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ip == null
                        ? switching
                              ? 'IP · переключение…'
                              : busy
                              ? 'Определяем внешний IP…'
                              : 'IP не определён'
                        : 'IP · $ip',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    detail,
                    style: TextStyle(
                      fontSize: 11,
                      color: appColors(context).muted,
                    ),
                  ),
                ],
              ),
            ),
            if (ip != null)
              IconButton(
                tooltip: 'Скопировать IP',
                onPressed: () => Clipboard.setData(ClipboardData(text: ip)),
                icon: const Icon(LucideIcons.copy, size: 15),
              ),
            IconButton(
              tooltip: 'Обновить IP',
              onPressed: switching || busy ? null : c.refreshPublicIP,
              icon: busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(LucideIcons.refreshCw, size: 15),
            ),
          ],
        ),
      );
    },
  );
}
