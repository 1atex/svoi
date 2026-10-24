part of 'main.dart';

class MobileShell extends StatefulWidget {
  const MobileShell({super.key, required this.c});
  final SvoiController c;
  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  int page = 0;
  String search = '';
  final searchController = TextEditingController();
  SvoiController get c => widget.c;
  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      c.group,
      c.sessions,
      c.servers,
      c.subscriptions,
      c.selected,
      c.connection,
      c.connectionPhase,
      c.connectionIssue,
      c.message,
      c.busy,
      c.preferences,
      c.favorites,
    ]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(['SVOI', 'Серверы', 'Профиль', 'Настройки'][page]),
        actions: [
          IconButton(
            tooltip: 'Импортировать подписку',
            onPressed: c.busy.value ? null : () => importDialog(context, c),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: page,
        onDestinationSelected: (i) => setState(() => page = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.power_settings_new),
            label: 'VPN',
          ),
          NavigationDestination(icon: Icon(Icons.public), label: 'Серверы'),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            label: 'Профиль',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Настройки',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (c.message.value.isNotEmpty)
              MaterialBanner(
                content: Text(c.message.value),
                actions: [
                  TextButton(
                    onPressed: () => c.message.value = '',
                    child: const Text('Закрыть'),
                  ),
                ],
              ),
            Expanded(
              child: switch (page) {
                0 => home(),
                1 => servers(),
                2 => profile(),
                _ => settings(),
              },
            ),
          ],
        ),
      ),
    ),
  );
  Widget home() {
    final view = ConnectionView(c);
    final server = c.servers.value
        .where((s) => s.id == c.selected.value)
        .firstOrNull;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'На своих условиях.',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Android · экспериментальная сборка',
          style: TextStyle(color: muted),
        ),
        TextButton.icon(
          onPressed: () => setState(() => page = 2),
          icon: const Icon(Icons.people_outline, size: 18),
          label: Text('Профиль: ${c.group.value['name'] ?? 'Моя сеть'}'),
        ),
        if (server == null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    c.sessions.value.length > 1
                        ? 'В этом профиле нет серверов'
                        : 'Начните с подписки',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    c.sessions.value.length > 1
                        ? 'У вас есть другие сохранённые профили. Подписки каждого профиля хранятся отдельно.'
                        : 'Вставьте ссылку от провайдера или код переноса из SVOI на компьютере.',
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: c.busy.value
                        ? null
                        : () => importDialog(context, c),
                    icon: const Icon(Icons.add_link),
                    label: const Text('Добавить подписку'),
                  ),
                  if (c.sessions.value.length > 1)
                    TextButton.icon(
                      onPressed: () => setState(() => page = 2),
                      icon: const Icon(Icons.switch_account_outlined),
                      label: const Text('Выбрать сохранённый профиль'),
                    ),
                ],
              ),
            ),
          )
        else ...[
          Card(
            child: ListTile(
              leading: CountryMark(country: server.country),
              title: Text(server.country.title),
              subtitle: Text(server.protocol),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => page = 1),
            ),
          ),
          const SizedBox(height: 28),
          Center(
            child: SizedBox(
              width: 144,
              height: 144,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  backgroundColor: view.running ? success : accent,
                ),
                onPressed: c.busy.value || view.phase.isNotEmpty
                    ? null
                    : c.toggleConnection,
                child: const Icon(Icons.power_settings_new, size: 60),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            view.title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            view.detail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: muted),
          ),
          if (view.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                view.error,
                style: const TextStyle(color: Color(0xffffaaa6)),
              ),
            ),
          const SizedBox(height: 16),
          if (view.running)
            TextButton.icon(
              onPressed: c.busy.value ? null : c.check,
              icon: const Icon(Icons.network_check),
              label: const Text('Проверить интернет'),
            ),
          const SizedBox(height: 20),
        ],
        const Text(
          'Подписки',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        for (final source in c.subscriptions.value)
          Card(
            child: ListTile(
              title: Text(source['name']?.toString() ?? 'Подписка'),
              subtitle: Text('${source['count'] ?? 0} серверов'),
              onTap: () => editSource(context, c, source),
            ),
          ),
        if (c.subscriptions.value.isNotEmpty)
          TextButton.icon(
            onPressed: c.busy.value ? null : c.refreshSubscriptions,
            icon: const Icon(Icons.refresh),
            label: const Text('Обновить подписки'),
          ),
      ],
    );
  }

  Widget servers() {
    final list = c.orderedServers(
      c.servers.value.where((s) => s.search.contains(search.toLowerCase())),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: searchController,
            onChanged: (v) => setState(() => search = v),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Название, страна, адрес',
              suffixIcon: search.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Сбросить поиск',
                      onPressed: () => setState(() {
                        searchController.clear();
                        search = '';
                      }),
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          search.isNotEmpty
                              ? 'По запросу ничего не найдено'
                              : 'В выбранном профиле нет серверов',
                          textAlign: TextAlign.center,
                        ),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              if (search.isNotEmpty) {
                                searchController.clear();
                                search = '';
                              } else {
                                page = 2;
                              }
                            });
                          },
                          child: Text(
                            search.isNotEmpty
                                ? 'Сбросить поиск'
                                : 'Выбрать профиль',
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final s = list[i];
                    return ListTile(
                      selected: s.id == c.selected.value,
                      leading: CountryMark(country: s.country),
                      title: Text(
                        s.country.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(s.protocol),
                      trailing: IconButton(
                        tooltip: 'Конфигурация',
                        icon: const Icon(Icons.code),
                        onPressed: () => showConfig(context, c, s),
                      ),
                      onTap: c.busy.value
                          ? null
                          : () async {
                              await c.select(s.id);
                              if (mounted) setState(() => page = 0);
                            },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget profile() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        'Сохранённые профили',
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 16),
      const Text(
        'Активен один профиль. При переключении VPN отключается; подписки остаются в своём профиле.',
      ),
      const SizedBox(height: 12),
      for (final (index, s) in c.sessions.value.indexed)
        Card(
          child: ListTile(
            leading: Icon(
              s['token'] == c.api.token
                  ? Icons.check_circle
                  : Icons.account_circle_outlined,
            ),
            title: Text('${s['name']} · ${index + 1}'),
            subtitle: Text(
              [
                if (s['token'] == c.api.token) 'Активный профиль',
                if (s.containsKey('serverCount'))
                  'Серверов: ${s['serverCount']} · подписок: ${s['subscriptionCount']}'
                else
                  'Открыть сохранённый профиль',
                if (s['sources']?.toString().isNotEmpty == true)
                  s['sources'].toString(),
              ].join('\n'),
            ),
            selected: s['token'] == c.api.token,
            onTap: c.busy.value || s['token'] == c.api.token
                ? null
                : () => c.switchProfile(s['token'] as String),
          ),
        ),
      const SizedBox(height: 24),
      const Text(
        'Перенос подписок между ПК и телефоном. Код содержит доступ к подпискам; передавайте его только получателю.',
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: c.busy.value ? null : () => importDialog(context, c),
        icon: const Icon(Icons.download),
        label: const Text('Получить профиль'),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: c.busy.value
            ? null
            : () => c.action(() async {
                final result = await c.api.request(
                  'transfer/export',
                  method: 'POST',
                );
                await Clipboard.setData(
                  ClipboardData(text: result['code'] as String),
                );
                c.message.value = 'Код профиля скопирован';
              }),
        icon: const Icon(Icons.copy),
        label: const Text('Скопировать код переноса'),
      ),
    ],
  );
  Widget settings() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Обновлять подписки при запуске'),
        value: c.preferences.value['autoRefresh'] == true,
        onChanged: (v) => c.settings({'autoRefresh': v}),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.apps),
        title: const Text('Приложения через VPN'),
        subtitle: const Text('Все, выбранные или исключения'),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => AndroidAppsPage(c: c)),
        ),
      ),
      const Divider(),
      const Text('SVOI · Android Preview 1'),
      const SizedBox(height: 12),
      const Text(
        'Обновления этой тестовой сборки устанавливаются APK-файлом. zapret и настройки автозапуска Windows здесь недоступны.',
        style: TextStyle(color: muted),
      ),
      const SizedBox(height: 12),
      const Text(
        'При смене сети переподключите VPN, если соединение не восстановилось. Работа на физических устройствах ещё требует проверки.',
        style: TextStyle(color: muted),
      ),
    ],
  );
}

class AndroidAppsPage extends StatefulWidget {
  const AndroidAppsPage({super.key, required this.c});
  final SvoiController c;
  @override
  State<AndroidAppsPage> createState() => _AndroidAppsPageState();
}

class _AndroidAppsPageState extends State<AndroidAppsPage> {
  List<dynamic> apps = [];
  Set<String> selected = {};
  String mode = 'all', error = '';
  bool loading = true;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final route = await widget.c.api.request('android/routing');
      final result = await widget.c.api.request('android/apps');
      if (mounted) {
        setState(() {
          mode = route['mode'] as String;
          selected = Set<String>.from(route['packages']);
          apps = result['apps'] as List;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Приложения через VPN')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: DropdownButtonFormField<String>(
                  initialValue: mode,
                  items: const [
                    DropdownMenuItem(
                      value: 'all',
                      child: Text('Все приложения'),
                    ),
                    DropdownMenuItem(
                      value: 'include',
                      child: Text('Только выбранные'),
                    ),
                    DropdownMenuItem(
                      value: 'exclude',
                      child: Text('Все, кроме выбранных'),
                    ),
                  ],
                  onChanged: (v) => setState(() => mode = v!),
                ),
              ),
              if (error.isNotEmpty) Text(error),
              Expanded(
                child: ListView.builder(
                  itemCount: apps.length,
                  itemBuilder: (context, i) {
                    final a = apps[i] as Map;
                    return CheckboxListTile(
                      title: Text(a['name'] as String),
                      subtitle: Text(a['package'] as String),
                      value: selected.contains(a['package']),
                      onChanged: mode == 'all'
                          ? null
                          : (v) => setState(() {
                              if (v == true) {
                                selected.add(a['package'] as String);
                              } else {
                                selected.remove(a['package']);
                              }
                            }),
                    );
                  },
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                    onPressed: () async {
                      try {
                        await widget.c.api.request(
                          'android/routing',
                          method: 'PUT',
                          body: {'mode': mode, 'packages': selected.toList()},
                        );
                        if (context.mounted) {
                          widget.c.message.value = 'Правила сохранены. Переподключите VPN, чтобы применить.';
                          Navigator.pop(context);
                        }
                      } catch (e) {
                        setState(() => error = e.toString());
                      }
                    },
                    child: const Text('Сохранить'),
                  ),
                ),
              ),
            ],
          ),
  );
}
