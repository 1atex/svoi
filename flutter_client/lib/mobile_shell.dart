part of 'main.dart';

class MobileShell extends StatefulWidget {
  const MobileShell({super.key, required this.c});
  final SvoiController c;
  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  MobileUpdateModel? updates;
  @override
  void initState() {
    super.initState();
    if (c.api is AndroidBackend) {
      final directory = (c.api as AndroidBackend).directory;
      updates = MobileUpdateModel(
        releaseNotice: ReleaseNoticeStore(
          File('${directory.path}/release-notice.json'),
        ),
      )..start();
    }
  }

  int page = 0;
  String search = '';
  bool sortLatency = false;
  final searchController = TextEditingController();
  SvoiController get c => widget.c;
  @override
  void dispose() {
    updates?.releaseNotice?.dispose();
    updates?.dispose();
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      ?updates,
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
      c.probing,
      c.probeProgress,
      c.probeRevision,
    ]),
    builder: (context, _) => OnboardingHost(
      store: updates?.releaseNotice,
      controller: c,
      platform: 'android',
      child: Theme(
        data: mobileTheme(Theme.of(context)),
        child: Scaffold(
          appBar: AppBar(
            title: page == 0
                ? FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.asset(
                            'assets/svoi-mark.png',
                            width: 34,
                            height: 34,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'svoi',
                          style: TextStyle(
                            fontSize: 29,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1,
                          ),
                        ),
                        Text(
                          '·',
                          style: TextStyle(
                            color: appColors(context).accent,
                            fontSize: 29,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  )
                : Text(['SVOI', 'Серверы', 'Профиль', 'Настройки'][page]),
            actions: [
              const CommunityButton(),
              if (updates?.available == true)
                IconButton(
                  tooltip: 'Доступно обновление SVOI',
                  onPressed: () => setState(() => page = 3),
                  icon: Icon(
                    Icons.system_update,
                    color: appColors(context).accent,
                  ),
                ),
              IconButton(
                tooltip: 'Импортировать подписку',
                onPressed: c.busy.value ? null : () => importDialog(context, c),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          bottomNavigationBar: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: appColors(context).edge)),
            ),
            child: NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (i) => setState(() => page = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(LucideIcons.power, size: 22),
                  label: 'VPN',
                ),
                NavigationDestination(
                  icon: Icon(LucideIcons.globe, size: 22),
                  label: 'Серверы',
                ),
                NavigationDestination(
                  icon: Icon(LucideIcons.users, size: 22),
                  label: 'Профиль',
                ),
                NavigationDestination(
                  icon: Icon(LucideIcons.settings2, size: 22),
                  label: 'Настройки',
                ),
              ],
            ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                if (updates?.releaseNotice != null)
                  ReleaseNoticeBanner(
                    store: updates!.releaseNotice!,
                    platform: 'android',
                    open: (uri) => windowChannel.invokeMethod<void>(
                      'openExternal',
                      uri.toString(),
                    ),
                  ),
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
      ),
    ),
  );
  Widget home() {
    final server = c.servers.value
        .where((s) => s.id == c.selected.value)
        .firstOrNull;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        if (server == null)
          MobilePanel(
            hero: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(
                    Icons.add_link_rounded,
                    color: appColors(context).accent,
                    size: 36,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  c.sessions.value.length > 1
                      ? 'В этом профиле нет серверов'
                      : 'Начните с подписки',
                  style: const TextStyle(
                    fontSize: 26,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  c.sessions.value.length > 1
                      ? 'Подписки каждого профиля хранятся отдельно. Выберите сохранённый профиль или добавьте подписку.'
                      : 'Вставьте ссылку от провайдера или перенесите профиль из SVOI на компьютере.',
                  style: TextStyle(
                    color: appColors(context).muted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: c.busy.value
                      ? null
                      : () => importDialog(context, c),
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить подписку'),
                ),
                if (c.sessions.value.length > 1)
                  TextButton(
                    onPressed: () => setState(() => page = 2),
                    child: const Text('Выбрать сохранённый профиль'),
                  ),
              ],
            ),
          )
        else
          MobileConnectionCard(
            c: c,
            server: server,
            onServer: () => setState(() => page = 1),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Подписки',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
              ),
            ),
            if (c.subscriptions.value.isNotEmpty)
              IconButton(
                tooltip: 'Обновить подписки',
                onPressed: c.busy.value ? null : c.refreshSubscriptions,
                icon: const Icon(Icons.refresh_rounded, size: 21),
              ),
            IconButton(
              tooltip: 'Добавить подписку',
              onPressed: c.busy.value ? null : () => importDialog(context, c),
              icon: const Icon(Icons.add_rounded, size: 21),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final source in c.subscriptions.value)
          Card(
            child: ListTile(
              leading: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: appColors(context).accent.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.link_rounded,
                  color: appColors(context).accent,
                  size: 22,
                ),
              ),
              title: Text(
                subscriptionDisplayName(source),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${source['count'] ?? 0} серверов'),
                  if (subscriptionTraffic(subscriptionMetadata(source))
                      .isNotEmpty)
                    Text(subscriptionTraffic(subscriptionMetadata(source))),
                  if (subscriptionExpiry(subscriptionMetadata(source))
                      .isNotEmpty)
                    Text(subscriptionExpiry(subscriptionMetadata(source))),
                  if (subscriptionMetadata(source)['announcement'] != null)
                    Text(
                      subscriptionMetadata(source)['announcement'].toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: appColors(context).accent),
                    ),
                ],
              ),
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: () => editSource(context, c, source),
            ),
          ),
        if (c.subscriptions.value.isEmpty)
          Text(
            'Здесь появятся ваши источники серверов.',
            style: TextStyle(color: appColors(context).muted, fontSize: 13),
          ),
      ],
    );
  }

  Widget servers() {
    final list = c.orderedServers(
      c.servers.value.where((s) => s.search.contains(search.toLowerCase())),
      latency: sortLatency,
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            children: [
              Text(
                '${list.length} серверов',
                style: TextStyle(color: appColors(context).muted),
              ),
              FilterChip(
                label: const Text('По пингу'),
                selected: sortLatency,
                onSelected: (v) => setState(() => sortLatency = v),
              ),
              TextButton.icon(
                onPressed: c.probing.value
                    ? c.cancelProbes
                    : c.busy.value ||
                          list.isEmpty ||
                          c.connection.value['available'] != true
                    ? null
                    : () => c.probe(list),
                icon: Icon(
                  c.probing.value ? Icons.stop : Icons.network_check,
                  size: 18,
                ),
                label: Text(c.probing.value ? 'Остановить' : 'Проверить пинг'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            c.probeProgress.value.isEmpty
                ? 'GET через профиль · до ${c.api.probeConcurrency} одновременно · ${(c.preferences.value['probe'] as Map?)?['timeoutSeconds'] ?? 4} с'
                : c.probeProgress.value,
            style: TextStyle(color: appColors(context).muted, fontSize: 12),
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? SingleChildScrollView(
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
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final s = list[i];
                    return Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                        side: BorderSide(
                          color: s.id == c.selected.value
                              ? appColors(context).accent.withValues(alpha: .5)
                              : appColors(context).edge,
                        ),
                      ),
                      color: s.id == c.selected.value
                          ? const Color(0xff25221d)
                          : appColors(context).surface,
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        horizontalTitleGap: 10,
                        selected: s.id == c.selected.value,
                        leading: CountryMark(country: s.country),
                        title: Text(
                          s.country.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(s.protocol),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            MobileProbeButton(c: c, server: s),
                            IconButton(
                              tooltip: 'Конфигурация',
                              icon: const Icon(Icons.code),
                              onPressed: () => showConfig(context, c, s),
                            ),
                          ],
                        ),
                        onTap: c.busy.value
                            ? null
                            : () async {
                                await c.select(s.id);
                                if (mounted) setState(() => page = 0);
                              },
                      ),
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
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.fingerprint),
        title: const Text('HWID и данные устройства'),
        subtitle: const Text('Что отправлять при загрузке подписок'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => MobileIdentityPage(c: c)),
        ),
      ),
      const SizedBox(height: 16),
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
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.speed),
        title: const Text('Интернетометр'),
        subtitle: const Text('Без VPN и через выбранные серверы'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Скорость интернета')),
              body: SafeArea(child: SpeedTools(c: c)),
            ),
          ),
        ),
      ),

      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.palette_outlined),
        title: const Text('Оформление'),
        subtitle: const Text('8 тем, включая Хэллоуин'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Оформление')),
              body: SafeArea(
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: const [AppearancePanel()],
                ),
              ),
            ),
          ),
        ),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.fingerprint),
        title: const Text('HWID и данные устройства'),
        subtitle: const Text('Параметры активного профиля'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => MobileIdentityPage(c: c)),
        ),
      ),
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
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.network_check),
        title: const Text('Проверка задержки'),
        subtitle: const Text('Адрес, тайм-аут и число проверок'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Проверка задержки')),
              body: SafeArea(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [ProbeSettingsPanel(c: c)],
                ),
              ),
            ),
          ),
        ),
      ),
      const Divider(),
      if (updates != null)
        MobileUpdatesPanel(model: updates!)
      else
        const Text('SVOI · Android Preview 8'),
      const SizedBox(height: 12),
      Text(
        'Новая версия устанавливается через системное окно Android. Профили и подписки сохраняются.',
        style: TextStyle(color: appColors(context).muted),
      ),
      const SizedBox(height: 12),
      Text(
        'При смене сети переподключите VPN, если соединение не восстановилось. Работа на физических устройствах ещё требует проверки.',
        style: TextStyle(color: appColors(context).muted),
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
