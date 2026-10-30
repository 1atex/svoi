part of 'main.dart';

class SettingsBody extends StatelessWidget {
  const SettingsBody({
    super.key,
    required this.children,
    this.actions = const {},
  });
  final List<Widget> children;
  final Map<String, VoidCallback> actions;

  String title(Widget child) => switch (child) {
    Section s => s.title,
    AppearancePanel _ => 'Оформление',
    ProbeSettingsPanel _ => 'Проверка задержки',
    _ => 'Настройки',
  };

  IconData icon(String name) => switch (name) {
    'Оформление' => Icons.palette_outlined,
    'Проверка задержки' => Icons.network_check,
    'Автоматизация' => Icons.schedule,
    'Подписки' => Icons.link,
    'Общий профиль' => Icons.people_outline,
    'Подключение' => Icons.shield_outlined,
    'Обновления SVOI' => Icons.system_update_alt,
    'Сценарии' => Icons.layers_outlined,
    'Сетевые инструменты' => Icons.build_outlined,
    _ => Icons.info_outline,
  };

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      for (final child in children)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            key: ValueKey('settings-section-${title(child)}'),
            minVerticalPadding: 16,
            leading: SvoiIcon(icon(title(child)), size: 22),
            title: Text(title(child)),
            trailing: const SvoiIcon(Icons.chevron_right, size: 20),
            onTap:
                actions[title(child)] ??
                () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SettingsDetailPage(title: title(child), child: child),
                  ),
                ),
          ),
        ),
    ],
  );
}

class SettingsDetailPage extends StatelessWidget {
  const SettingsDetailPage({
    super.key,
    required this.title,
    required this.child,
  });
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final page = Scaffold(
      appBar: AppBar(
        leading: BackButton(
          key: const ValueKey('settings-back'),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(title),
      ),
      body: SafeArea(child: FeatureBody(children: [child])),
    );
    if (!Platform.isWindows) return page;
    return Scaffold(
      body: Column(
        children: [
          const DesktopTitlebar(),
          Expanded(child: page),
        ],
      ),
    );
  }
}
