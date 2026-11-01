part of 'main.dart';

class WarpPage extends StatelessWidget {
  const WarpPage({super.key, required this.c});
  final SvoiController c;
  Future<void> open(BuildContext context, String url) async {
    try {
      await windowChannel.invokeMethod('openExternal', url);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось открыть ссылку Cloudflare. Попробуйте ещё раз.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => FeatureBody(
    children: [
      RemotePanel(
        c: c,
        path: 'warp',
        builder: (context, data, acting, act) {
          final p = appColors(context);
          final state = data['state']?.toString() ?? 'unknown';
          final installed = data['installed'] == true;
          final active = [
            'connected',
            'connecting',
            'disconnecting',
          ].contains(state);
          final conflict =
              data['vpnRunning'] == true || data['zapretRunning'] == true;
          final title = switch (state) {
            'not-installed' => 'Добавьте WARP',
            'unregistered' => 'Остался первый запуск',
            'connected' => 'WARP подключён',
            'disconnected' => 'Готов к подключению',
            'connecting' => 'Подключаем WARP…',
            'disconnecting' => 'Отключаем WARP…',
            _ => 'Проверьте службу WARP',
          };
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: p.accent.withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: SvoiIcon(
                                LucideIcons.cloud,
                                size: 26,
                                color: p.accent,
                              ),
                            ),
                            const SizedBox(width: 14),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'WARP',
                                    style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    'Cloudflare',
                                    style: TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                            StatusPill(
                              installed
                                  ? state == 'connected'
                                        ? 'Включён'
                                        : 'Установлен'
                                  : 'Не установлен',
                              active: state == 'connected',
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Text(
                          installed
                              ? 'Подключение через сеть Cloudflare. Ваша VPN-подписка не используется.'
                              : 'Бесплатное подключение через сеть Cloudflare без VPN-подписки. Для работы нужен официальный компонент WARP.',
                          style: TextStyle(color: p.muted, height: 1.5),
                        ),
                        const SizedBox(height: 20),
                        if (installed)
                          Center(
                            child: ConnectionDial(
                              activeLabel: 'Подключён',
                              showElapsed: false,
                              foreground: c.visible,
                              running: state == 'connected',
                              verified: false,
                              busy:
                                  acting ||
                                  [
                                    'connecting',
                                    'disconnecting',
                                  ].contains(state),
                              hint: active ? 'Отключить WARP' : 'Включить WARP',
                              onPressed:
                                  acting ||
                                      (!active &&
                                          (state != 'disconnected' || conflict))
                                  ? null
                                  : () => act(
                                      active ? 'disconnect' : 'connect',
                                      null,
                                    ),
                            ),
                          ),
                        const SizedBox(height: 10),
                        Text(
                          title,
                          textAlign: installed
                              ? TextAlign.center
                              : TextAlign.left,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if ((data['error'] ?? '').toString().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              '${data['error']}',
                              style: TextStyle(color: p.accent),
                            ),
                          ),
                        if (conflict && !active)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              data['vpnRunning'] == true
                                  ? 'Отключите VPN на вкладке «Подключение», чтобы включить WARP.'
                                  : 'Остановите zapret, чтобы включить WARP.',
                              style: TextStyle(color: p.accent),
                            ),
                          ),
                        if (!installed) ...[
                          const SizedBox(height: 14),
                          AppButton(
                            label: data['componentAvailable'] == true
                                ? 'Установить WARP'
                                : 'Скачать Cloudflare WARP',
                            primary: true,
                            icon: LucideIcons.download,
                            onPressed: acting
                                ? null
                                : data['componentAvailable'] == true
                                ? () => act('install', null)
                                : () => open(
                                    context,
                                    Platform.isMacOS
                                        ? 'https://downloads.cloudflareclient.com/v1/download/macos/ga'
                                        : Platform.isLinux
                                        ? 'https://pkg.cloudflareclient.com/'
                                        : 'https://downloads.cloudflareclient.com/v1/download/windows/ga',
                                  ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            data['installerOpened'] == true
                                ? 'Установщик открыт. Завершите установку в системном окне, затем обновите состояние.'
                                : data['componentAvailable'] == true
                                ? 'Официальный компонент входит в сборку. Системный установщик запросит необходимые права.'
                                : 'Загрузите официальный клиент Cloudflare, установите его и обновите состояние.',
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                        ],
                        if (state == 'unregistered') ...[
                          const SizedBox(height: 14),
                          Text(
                            'Зарегистрируйте WARP один раз. Данные регистрации останутся в официальном клиенте Cloudflare.',
                            style: TextStyle(color: p.muted),
                          ),
                          const SizedBox(height: 12),
                          AppButton(
                            label: 'Настроить WARP',
                            primary: true,
                            onPressed: acting
                                ? null
                                : () async {
                                    final accepted = await showDialog<bool>(
                                      context: context,
                                      builder: (dialog) => AlertDialog(
                                        title: const Text('Первый запуск WARP'),
                                        content: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text(
                                              'Регистрация выполняется в Cloudflare. Продолжая, вы принимаете их условия и политику конфиденциальности.',
                                            ),
                                            TextButton(
                                              onPressed: () => open(
                                                context,
                                                'https://www.cloudflare.com/application/terms/',
                                              ),
                                              child: const Text(
                                                'Условия Cloudflare',
                                              ),
                                            ),
                                            TextButton(
                                              onPressed: () => open(
                                                context,
                                                'https://www.cloudflare.com/application/privacypolicy/',
                                              ),
                                              child: const Text(
                                                'Политика конфиденциальности',
                                              ),
                                            ),
                                          ],
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(dialog, false),
                                            child: const Text('Отмена'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(dialog, true),
                                            child: const Text(
                                              'Принять и настроить',
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (accepted == true) {
                                      await act('register', {'accepted': true});
                                    }
                                  },
                          ),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: acting
                                  ? null
                                  : () => act('refresh', null),
                              icon: const SvoiIcon(
                                LucideIcons.refreshCw,
                                size: 16,
                              ),
                              label: const Text('Обновить состояние'),
                            ),
                            TextButton.icon(
                              onPressed: () => open(
                                context,
                                'https://developers.cloudflare.com/warp-client/get-started/${Platform.isMacOS
                                    ? 'macos'
                                    : Platform.isLinux
                                    ? 'linux'
                                    : 'windows'}/',
                              ),
                              icon: const SvoiIcon(
                                LucideIcons.arrowUpRight,
                                size: 16,
                              ),
                              label: const Text('Помощь Cloudflare'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'WARP не выбирает страну выхода. Доступность и скорость зависят от вашей сети.${installed ? ' После закрытия SVOI служба WARP продолжает работать — отключайте её кнопкой выше.' : ''}',
                    style: TextStyle(color: p.muted, fontSize: 12, height: 1.5),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ],
  );
}
