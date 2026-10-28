part of 'main.dart';

Future<void> showTrafficRules(
  BuildContext context,
  SvoiController c, {
  int tab = 0,
}) => !Platform.isWindows
    ? showDesktopSheet(context, 'Сайты напрямую', DirectSitesPanel(c: c))
    : showDesktopSheet(
        context,
        'Правила трафика',
        DefaultTabController(
          length: 2,
          initialIndex: tab,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: 'Приложения'),
                  Tab(text: 'Сайты напрямую'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    RoutingPage(c: c),
                    DirectSitesPanel(c: c),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

class DirectSitesPanel extends StatefulWidget {
  const DirectSitesPanel({super.key, required this.c});
  final SvoiController c;
  @override
  State<DirectSitesPanel> createState() => _DirectSitesPanelState();
}

class _DirectSitesPanelState extends State<DirectSitesPanel> {
  final input = TextEditingController();
  String error = '';
  SvoiController get c => widget.c;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> add() async {
    var domain = input.text.trim().toLowerCase();
    if (domain.contains('://')) domain = Uri.tryParse(domain)?.host ?? domain;
    if (domain.isEmpty) return;
    await c.settings({
      'directDomains': [
        ...List<String>.from(c.preferences.value['directDomains'] ?? []),
        domain,
      ],
    });
    if (!mounted) return;
    setState(() => error = c.message.value);
    if (error.isEmpty) input.clear();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c.preferences, c.busy, c.connection]),
    builder: (context, _) {
      final domains = List<String>.from(
        c.preferences.value['directDomains'] ?? [],
      );
      return FeatureBody(
        children: [
          Section(
            'Сайты напрямую',
            subtitle: 'Домен и его поддомены будут открываться без VPN. Ваши исключения имеют приоритет над правилами подписки. DNS может по-прежнему обрабатываться профилем.',
            children: [
              TextField(
                key: const ValueKey('direct-domain'),
                controller: input,
                enabled: !c.busy.value,
                onSubmitted: (_) => add(),
                decoration: InputDecoration(
                  labelText: 'Домен сайта',
                  hintText: 'yandex.ru',
                  errorText: error.isEmpty ? null : error,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: c.busy.value ? null : add,
                  icon: const SvoiIcon(LucideIcons.plus, size: 16),
                  label: const Text('Добавить исключение'),
                ),
              ),
              const SizedBox(height: 12),
              if (domains.isEmpty)
                Text(
                  'Список пуст. Все сайты используют маршруты профиля.',
                  style: TextStyle(color: appColors(context).muted),
                ),
              for (final domain in domains)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(domain),
                  subtitle: const Text('Включая поддомены'),
                  trailing: IconButton(
                    tooltip: 'Удалить исключение $domain',
                    onPressed: c.busy.value
                        ? null
                        : () => c.settings({
                            'directDomains': domains
                                .where((d) => d != domain)
                                .toList(),
                          }),
                    icon: const SvoiIcon(LucideIcons.x, size: 18),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                c.connection.value['state'] == 'running'
                    ? 'Для применения изменений нажмите «Переключиться» на экране подключения.'
                    : 'Изменения применятся при следующем подключении.',
                style: TextStyle(color: appColors(context).muted),
              ),
            ],
          ),
        ],
      );
    },
  );
}
