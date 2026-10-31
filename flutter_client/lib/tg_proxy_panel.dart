part of 'main.dart';

class TelegramProxyPanel extends StatelessWidget {
  const TelegramProxyPanel({super.key, required this.c});
  final SvoiController c;

  Future<void> openTelegram(BuildContext context, String link) async {
    try {
      await windowChannel.invokeMethod('openTelegramProxy', link);
    } catch (_) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Откройте Telegram Desktop'),
          content: const Text(
            'Установите Telegram Desktop или скопируйте ссылку и откройте её в Telegram. Подтвердите подключение к прокси в появившемся окне.',
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: link)),
              child: const Text('Скопировать ссылку'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Section(
    'Telegram',
    children: [
      RemotePanel(
        c: c,
        path: 'tg-proxy',
        builder: (context, data, acting, act) {
          final running = data['running'] == true;
          final installed = data['installed'] == true;
          final link = data['link']?.toString() ?? '';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SvoiIcon(
                    Icons.telegram,
                    size: 24,
                    color: appColors(context).accent,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'tg-ws-proxy · Flowseal',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  StatusPill(
                    running ? 'Работает' : 'Остановлен',
                    active: running,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Локальный прокси для Telegram Desktop. Запустите его и подтвердите подключение в Telegram. Работает отдельно от zapret и VPN.',
                style: TextStyle(color: appColors(context).muted, height: 1.5),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('tg-proxy-power'),
                    onPressed: acting || !installed
                        ? null
                        : () => act(running ? 'stop' : 'start', null),
                    icon: SvoiIcon(
                      running ? LucideIcons.square : LucideIcons.play,
                      size: 16,
                    ),
                    label: Text(
                      acting
                          ? 'Подождите…'
                          : running
                          ? 'Остановить'
                          : 'Запустить',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: running && !acting && link.isNotEmpty
                        ? () => openTelegram(context, link)
                        : null,
                    icon: const SvoiIcon(Icons.telegram, size: 17),
                    label: const Text('Подключить Telegram'),
                  ),
                  IconButton(
                    tooltip: 'Скопировать ссылку прокси',
                    onPressed: running && link.isNotEmpty
                        ? () async {
                            await Clipboard.setData(ClipboardData(text: link));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Ссылка скопирована'),
                                ),
                              );
                            }
                          }
                        : null,
                    icon: const SvoiIcon(LucideIcons.copy, size: 18),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                running
                    ? 'Прокси доступен, пока открыт SVOI, в том числе в трее.'
                    : 'Если прокси уже добавлен в Telegram, после остановки отключите его в настройках Telegram.',
                style: TextStyle(fontSize: 12, color: appColors(context).muted),
              ),
              if (!installed)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Компонент отсутствует. Установите полную сборку SVOI.',
                  ),
                ),
              if ((data['error'] ?? '').toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${data['error']}',
                    style: TextStyle(color: appColors(context).accent),
                  ),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                children: [
                  TextButton(
                    onPressed: running || acting
                        ? null
                        : () async {
                            final input = TextEditingController(
                              text: '${data['port'] ?? 1443}',
                            );
                            final port = await showDialog<int>(
                              context: context,
                              builder: (dialog) => AlertDialog(
                                title: const Text('Порт Telegram-прокси'),
                                content: TextField(
                                  controller: input,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'От 1024 до 65535',
                                    helperText: 'После изменения повторно подключите Telegram.',
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(dialog),
                                    child: const Text('Отмена'),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      final value = int.tryParse(input.text);
                                      if (value != null &&
                                          value >= 1024 &&
                                          value <= 65535) {
                                        Navigator.pop(dialog, value);
                                      }
                                    },
                                    child: const Text('Сохранить'),
                                  ),
                                ],
                              ),
                            );
                            input.dispose();
                            if (port != null) {
                              await act('config', {'port': port});
                            }
                          },
                    child: Text('Порт ${data['port'] ?? 1443}'),
                  ),
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (dialog) => AlertDialog(
                        title: const Text('Журнал Telegram-прокси'),
                        content: SizedBox(
                          width: 650,
                          child: SingleChildScrollView(
                            child: SelectableText(
                              (data['logs'] as List? ?? []).isEmpty
                                  ? 'Журнал пока пуст.'
                                  : (data['logs'] as List).join('\n'),
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialog),
                            child: const Text('Закрыть'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('Журнал'),
                  ),
                  TextButton(
                    onPressed: () => windowChannel.invokeMethod(
                      'openExternal',
                      'https://github.com/Flowseal/tg-ws-proxy',
                    ),
                    child: Text('О проекте · ${data['version'] ?? ''}'),
                  ),
                ],
              ),
              Text(
                'Встроен в SVOI и обновляется вместе с приложением.',
                style: TextStyle(fontSize: 11, color: appColors(context).muted),
              ),
            ],
          );
        },
      ),
      const SizedBox(height: 16),
      const Divider(),
      StartupPanel(c: c, telegramOnly: true),
    ],
  );
}
