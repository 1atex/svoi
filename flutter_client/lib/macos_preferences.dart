part of 'main.dart';

class MacOSPreferences extends StatelessWidget {
  const MacOSPreferences({super.key, required this.c});
  final SvoiController c;

  @override
  Widget build(BuildContext context) => SettingsBody(
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
            icon: const SvoiIcon(Icons.refresh),
            label: const Text('Обновить подписки'),
          ),
        ],
      ),
      Section(
        'macOS Preview',
        children: [
          const Text('Версия $clientVersion · Apple Silicon'),
          const SizedBox(height: 12),
          const Text(
            'Системный прокси подключает браузеры и приложения, которые учитывают настройки macOS. Система может запросить разрешение на изменение сети. При отключении прежние настройки восстанавливаются.',
          ),
          const SizedBox(height: 12),
          const Text(
            'TUN, выбор приложений и автозапуск появятся после отдельной проверки на Mac. DNS управляется macOS. Обновления этой тестовой версии устанавливаются вручную.',
          ),
          const SizedBox(height: 12),
          const SelectableText('Данные: ~/Library/Application Support/SVOI'),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () => showLogs(context, c),
            icon: const SvoiIcon(Icons.article_outlined),
            label: const Text('Журнал Xray'),
          ),
        ],
      ),
    ],
  );
}
