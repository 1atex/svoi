part of 'main.dart';

class NetworkToolsPage extends StatelessWidget {
  const NetworkToolsPage({super.key, required this.c});
  final SvoiController c;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: Platform.isLinux ? 2 : 3,
    child: Column(
      children: [
        TabBar(
          tabs: [
            const Tab(text: 'Скорость'),
            const Tab(text: 'Проверить сайт'),
            if (!Platform.isLinux) const Tab(text: 'DNS'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              SpeedTools(c: c),
              SiteCheckPanel(c: c),
              if (!Platform.isLinux) DnsTools(c: c),
            ],
          ),
        ),
      ],
    ),
  );
}

class SiteCheckPanel extends StatefulWidget {
  const SiteCheckPanel({super.key, required this.c});
  final SvoiController c;
  @override
  State<SiteCheckPanel> createState() => _SiteCheckPanelState();
}

class _SiteCheckPanelState extends State<SiteCheckPanel> {
  final input = TextEditingController();
  final requests = <RequestCancellation>[];
  final results = <String, Map<String, dynamic>>{};
  bool working = false;
  int generation = 0;
  String error = '', serverId = '', routeKey = '', testedHost = '';
  SvoiController get c => widget.c;
  @override
  void initState() {
    super.initState();
    c.connection.addListener(routeChanged);
    c.foreground.addListener(visibilityChanged);
    serverId = c.connection.value['state'] == 'running'
        ? c.connection.value['serverId'] ?? c.selected.value
        : c.selected.value;
    routeKey = currentRoute;
  }

  String get currentRoute =>
      '${c.connection.value['state']}/${c.connection.value['serverId']}/${c.connection.value['startedAt']}';

  void routeChanged() {
    if (currentRoute != routeKey) {
      routeKey = currentRoute;
      if (working) stop();
      if (mounted) setState(() => results.clear());
    }
  }

  void visibilityChanged() {
    if (!c.visible && working) stop();
  }

  void stop() {
    generation++;
    for (final r in requests) {
      r.cancel();
    }
    requests.clear();
    if (mounted) setState(() => working = false);
  }

  @override
  void dispose() {
    generation++;
    for (final r in requests) {
      r.cancel();
    }
    c.connection.removeListener(routeChanged);
    c.foreground.removeListener(visibilityChanged);
    input.dispose();
    super.dispose();
  }

  Future<void> run() async {
    if (working) return;
    final raw = input.text.trim();
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
    if (uri == null ||
        uri.host.isEmpty ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty) {
      setState(
        () => error = 'Введите адрес сайта, например https://youtube.com',
      );
      return;
    }
    if (!c.servers.value.any((s) => s.id == serverId)) {
      serverId = c.selected.value;
    }
    if (!c.servers.value.any((s) => s.id == serverId)) serverId = '';
    c.cancelProbes();
    final own = ++generation;
    setState(() {
      working = true;
      error = '';
      results.clear();
      testedHost = uri.host;
    });
    Future<void> check(String route) async {
      final r = RequestCancellation();
      requests.add(r);
      try {
        final data = await c.api.request(
          'tools/site',
          method: 'POST',
          body: {'url': uri.toString(), 'route': route, 'serverId': serverId},
          cancellation: r,
        );
        if (mounted && own == generation) setState(() => results[route] = data);
      } catch (e) {
        if (mounted && own == generation) {
          setState(() => results[route] = {'error': e.toString()});
        }
      } finally {
        requests.remove(r);
      }
    }

    await Future.wait([
      check('direct'),
      if (serverId.isNotEmpty) check('profile'),
    ]);
    if (mounted && own == generation) setState(() => working = false);
  }

  void clearResults() {
    if (results.isNotEmpty || error.isNotEmpty) {
      setState(() {
        results.clear();
        error = '';
      });
    }
  }

  bool? resultOK(String route) {
    final steps = results[route]?['steps'] as List?;
    return steps == null
        ? null
        : steps.isNotEmpty && (steps.last as Map)['ok'] == true;
  }

  String get summary {
    final direct = resultOK('direct'), profile = resultOK('profile');
    final rejections = <String>[];
    for (final route in ['direct', 'profile']) {
      final steps = results[route]?['steps'] as List? ?? [];
      if (steps.isNotEmpty &&
          steps.last['responded'] == true &&
          steps.last['ok'] != true) {
        rejections.add(
          '${route == 'direct' ? 'Напрямую' : 'Через профиль'}: ${steps.last['detail']}',
        );
      }
    }
    if (rejections.isNotEmpty) {
      return '${rejections.join('. ')}. Сеть до сайта доступна; попробуйте открыть его в браузере. Ответ приложения может отличаться.';
    }
    if (direct == true && profile == true) {
      return 'Сайт ответил по обоим маршрутам.';
    }
    if (direct == false && profile == true) {
      return 'Через профиль сайт отвечает, напрямую — нет. Используйте этот профиль и проверьте DNS вашей сети.';
    }
    if (direct == true && profile == false) {
      return 'Напрямую сайт отвечает, через профиль — нет. Попробуйте другой сервер или добавьте сайт в исключения.';
    }
    if (direct == false && profile == false) {
      return 'Оба запроса не прошли. Проверьте интернет и адрес сайта; сайт также может быть временно недоступен.';
    }
    return 'Результаты относятся только к указанному адресу и текущей проверке.';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c.servers, c.connection]),
    builder: (context, _) => FeatureBody(
      children: [
        Section(
          'Почему не открывается сайт?',
          subtitle: 'Проверка по запросу. Напрямую: DNS IPv4, TCP и HTTP(S) через физический адаптер Windows. Через профиль: HTTP(S) с его маршрутизацией.',
          children: [
            TextField(
              key: const ValueKey('site-url'),
              controller: input,
              enabled: !working,
              onSubmitted: (_) => run(),
              onChanged: (_) => clearResults(),
              decoration: InputDecoration(
                labelText: 'Адрес сайта',
                hintText: 'https://youtube.com',
                errorText: error.isEmpty ? null : error,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('site-server-$serverId'),
              initialValue: c.servers.value.any((s) => s.id == serverId)
                  ? serverId
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Профиль для сравнения',
              ),
              items: [
                for (final s in c.servers.value)
                  DropdownMenuItem(
                    value: s.id,
                    child: Text(
                      s.country.title,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: working
                  ? null
                  : (v) => setState(() {
                      serverId = v ?? '';
                      results.clear();
                    }),
            ),
            if (c.connection.value['state'] == 'running' &&
                c.connection.value['mode'] == 'tun' &&
                c.connection.value['serverId'] != serverId)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Работает TUN. Для сравнения другого профиля отключите VPN.',
                      style: TextStyle(color: appColors(context).accent),
                    ),
                    TextButton(
                      onPressed: working
                          ? null
                          : () => setState(() {
                              serverId = c.connection.value['serverId'] ?? '';
                              results.clear();
                            }),
                      child: const Text('Выбрать активный сервер'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: working ? stop : run,
                icon: Icon(
                  working ? LucideIcons.square : LucideIcons.search,
                  size: 16,
                ),
                label: Text(working ? 'Остановить' : 'Проверить сайт'),
              ),
            ),
            const SizedBox(height: 16),
            if (working) const LinearProgressIndicator(),
            if (!working && results.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  summary,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    height: 1.5,
                  ),
                ),
              ),
            for (final route in ['direct', 'profile'])
              if (results.containsKey(route)) ...[
                Text(
                  route == 'direct' ? 'Напрямую' : 'Через профиль',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (results[route]!['label'] != null)
                  Text(
                    results[route]!['label'].toString(),
                    style: TextStyle(
                      color: appColors(context).muted,
                      fontSize: 12,
                    ),
                  ),
                if (results[route]!['error'] != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      results[route]!['error'].toString(),
                      style: TextStyle(color: appColors(context).error),
                    ),
                  ),
                for (final raw in results[route]!['steps'] as List? ?? [])
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      raw['ok'] == true ? LucideIcons.check : LucideIcons.info,
                      color: raw['ok'] == true
                          ? appColors(context).success
                          : appColors(context).accent,
                      size: 18,
                    ),
                    title: Text('${raw['name']} · ${raw['ms']} мс'),
                    subtitle: Text(raw['detail'].toString()),
                  ),
                const Divider(height: 24),
              ],
            if (resultOK('direct') == true &&
                resultOK('profile') == false &&
                !((results['profile']?['steps'] as List? ?? [])
                        .lastOrNull?['responded'] ==
                    true))
              TextButton.icon(
                onPressed: () async {
                  if (!await confirmAction(
                    context,
                    'Открывать $testedHost напрямую?',
                    'Домен и поддомены будут обходить VPN. Для работающего соединения потребуется применить правила заново.',
                  )) {
                    return;
                  }
                  await c.settings({
                    'directDomains': [
                      ...List<String>.from(
                        c.preferences.value['directDomains'] ?? [],
                      ),
                      testedHost,
                    ],
                  });
                  if (context.mounted && c.message.value.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Исключение сохранено. Примените правила на экране подключения.',
                        ),
                      ),
                    );
                  }
                },
                icon: const Icon(LucideIcons.arrowUpRight, size: 16),
                label: const Text('Добавить сайт в исключения'),
              ),
            Text(
              'Проверка профиля учитывает исключения сайтов. DNS и TCP внутри профиля отдельно не измеряются. Его правила могут направлять сайт напрямую. Для проверки другого профиля отключите работающий TUN.',
              style: TextStyle(
                color: appColors(context).muted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
