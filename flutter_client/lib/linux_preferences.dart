part of 'main.dart';

class LinuxPreferences extends StatelessWidget {
  const LinuxPreferences({super.key, required this.c});
  final SvoiController c;
  @override
  Widget build(BuildContext context) => FeatureBody(
    children: [
      const AppearancePanel(),
      ProbeSettingsPanel(c: c),
      Section(
        'Подписки',
        children: [
          ValueListenableBuilder(
            valueListenable: c.preferences,
            builder: (context, preferences, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Обновлять подписки при запуске'),
              subtitle: const Text('Загрузка выполняется в фоне.'),
              value: preferences['autoRefresh'] == true,
              onChanged: (value) => c.settings({'autoRefresh': value}),
            ),
          ),
          OutlinedButton.icon(
            onPressed: c.refreshSubscriptions,
            icon: const Icon(Icons.refresh),
            label: const Text('Обновить подписки'),
          ),
        ],
      ),
      Section(
        'Linux Preview',
        children: [
          const Text('Версия $clientVersion · x86_64'),
          const SizedBox(height: 12),
          const Text(
            'TUN использует сетевые права ядра Xray. Пакет .deb настраивает их при установке; приложение работает без sudo. Для переносимого архива инструкция находится в LINUX.md.',
          ),
          const SizedBox(height: 12),
          const Text(
            'DNS управляется вашей системой. Настройки системного прокси и выбор приложений пока доступны только в Windows. В Linux можно использовать TUN, ручной прокси и исключения сайтов.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => windowChannel.invokeMethod(
              'openExternal',
              'https://github.com/1atex/svoi/releases?q=linux',
            ),
            icon: const Icon(Icons.download),
            label: const Text('Сборки Linux на GitHub'),
          ),
          TextButton.icon(
            onPressed: () => showLogs(context, c),
            icon: const Icon(Icons.article_outlined),
            label: const Text('Журнал Xray'),
          ),
        ],
      ),
    ],
  );
}
