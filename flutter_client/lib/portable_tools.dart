part of 'main.dart';

class DnsComparePanel extends StatefulWidget {
  const DnsComparePanel({super.key, required this.c});
  final SvoiController c;
  @override
  State<DnsComparePanel> createState() => _DnsComparePanelState();
}

class _DnsComparePanelState extends State<DnsComparePanel> {
  final requests = <RequestCancellation>[];
  List<Map<String, dynamic>> providers = [];
  final results = <String, Map<String, dynamic>>{};
  bool loading = true, working = false;
  String error = '';
  int generation = 0;
  String routeKey = '';
  SvoiController get c => widget.c;
  String get currentRoute =>
      '${c.connection.value['state']}/${c.connection.value['serverId']}/${c.connection.value['startedAt']}';
  bool get vpnActive =>
      c.busy.value ||
      c.connection.value['state'] != 'stopped' &&
          c.connection.value['state'] != null;

  @override
  void initState() {
    super.initState();
    routeKey = currentRoute;
    c.connection.addListener(routeChanged);
    c.busy.addListener(routeChanged);
    c.foreground.addListener(visibilityChanged);
    load();
  }

  void routeChanged() {
    if (currentRoute == routeKey && !c.busy.value) {
      if (mounted) setState(() {});
      return;
    }
    routeKey = currentRoute;
    if (working) stop();
    if (mounted) setState(() => results.clear());
  }

  void visibilityChanged() {
    if (!c.visible && working) stop();
  }

  Future<void> load() async {
    final request = RequestCancellation();
    requests.add(request);
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final data = await c.api.request('dns/catalog', cancellation: request);
      if (!mounted || request.cancelled) return;
      setState(
        () => providers = (data['candidates'] as List)
            .map((p) => Map<String, dynamic>.from(p as Map))
            .toList(),
      );
    } catch (e) {
      if (mounted && !request.cancelled) {
        setState(
          () => error = 'Не удалось загрузить список DNS. Повторите попытку.',
        );
      }
    } finally {
      requests.remove(request);
      if (mounted && !request.cancelled) setState(() => loading = false);
    }
  }

  void stop() {
    generation++;
    for (final request in requests.toList()) {
      request.cancel();
    }
    requests.clear();
    if (mounted) setState(() => working = false);
  }

  Future<void> run() async {
    if (working || loading || vpnActive || providers.isEmpty) return;
    final own = ++generation;
    setState(() {
      working = true;
      results.clear();
    });
    var next = 0;
    Future<void> worker() async {
      while (mounted && own == generation && next < providers.length) {
        final address = providers[next++]['address'] as String;
        final request = RequestCancellation();
        requests.add(request);
        try {
          final data = await c.api.request(
            'dns/benchmark',
            method: 'POST',
            body: {'address': address},
            cancellation: request,
          );
          if (mounted && own == generation) {
            setState(() => results[address] = data);
          }
        } catch (e) {
          if (mounted && own == generation) {
            setState(() => results[address] = {'error': e.toString()});
          }
        } finally {
          requests.remove(request);
        }
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));
    if (mounted && own == generation) setState(() => working = false);
  }

  @override
  void dispose() {
    generation++;
    for (final request in requests) {
      request.cancel();
    }
    c.connection.removeListener(routeChanged);
    c.busy.removeListener(routeChanged);
    c.foreground.removeListener(visibilityChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ranked =
        providers.where((p) {
          final r = results[p['address']];
          return r != null &&
              r['success'] == 6 &&
              r['total'] == 6 &&
              r['medianMs'] is num;
        }).toList()..sort(
          (a, b) => (results[a['address']]!['medianMs'] as num).compareTo(
            results[b['address']]!['medianMs'] as num,
          ),
        );
    final best = ranked.firstOrNull?['address'];
    final ordered = [...ranked, ...providers.where((p) => !ranked.contains(p))];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Сравнить DNS', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        Text(
          'Отклик и стабильность DNS, а не скорость загрузки. Настройки устройства не меняются. Каждый адрес получает 6 запросов; проверяем до трёх адресов одновременно.',
          style: TextStyle(color: appColors(context).muted),
        ),
        const SizedBox(height: 16),
        if (vpnActive)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              'Отключите VPN перед сравнением, чтобы туннель не перенаправлял DNS-запросы.',
            ),
          ),
        if (loading) const LinearProgressIndicator(),
        if (error.isNotEmpty) ...[
          Text(error, style: TextStyle(color: appColors(context).error)),
          TextButton(onPressed: load, child: const Text('Повторить')),
        ],
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AppButton(
              label: working ? 'Остановить' : 'Сравнить DNS',
              icon: working ? LucideIcons.square : LucideIcons.gauge,
              primary: true,
              onPressed: working
                  ? stop
                  : loading || vpnActive || providers.isEmpty
                  ? null
                  : run,
            ),
            Text(
              '${results.length} из ${providers.length}',
              style: TextStyle(color: appColors(context).muted),
            ),
          ],
        ),
        const SizedBox(height: 16),
        for (final p in ordered)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: appColors(context).surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: p['address'] == best
                      ? appColors(context).accent
                      : appColors(context).edge,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${p['name']} · ${p['address']}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    if (results[p['address']] case final Map<String, dynamic> r)
                      Text(
                        r['error']?.toString() ??
                            ((r['success'] as num? ?? 0) == 0
                                ? 'Нет ответа · 0/6'
                                : 'Медиана ${(r['medianMs'] as num).toStringAsFixed(1)} мс · ответов ${r['success']}/${r['total']}'),
                        style: TextStyle(color: appColors(context).muted),
                      )
                    else
                      Text(
                        working ? 'Ожидает проверки…' : 'Не проверен',
                        style: TextStyle(color: appColors(context).muted),
                      ),
                    if (p['address'] == best)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          working
                              ? 'Лучший из проверенных · 6/6'
                              : 'Самый быстрый из ответивших 6/6',
                          style: TextStyle(color: appColors(context).accent),
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: p['address'] as String),
                      ),
                      icon: const Icon(LucideIcons.copy, size: 16),
                      label: const Text('Скопировать адрес'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class CurrentSitePanel extends StatefulWidget {
  const CurrentSitePanel({super.key, required this.c});
  final SvoiController c;
  @override
  State<CurrentSitePanel> createState() => _CurrentSitePanelState();
}

class _CurrentSitePanelState extends State<CurrentSitePanel> {
  final input = TextEditingController();
  HttpClient? client;
  bool working = false;
  String result = '', error = '';
  int generation = 0;
  String routeKey = '';
  SvoiController get c => widget.c;
  String get currentRoute =>
      '${c.connection.value['state']}/${c.connection.value['serverId']}/${c.connection.value['startedAt']}';
  @override
  void initState() {
    super.initState();
    routeKey = currentRoute;
    c.connection.addListener(routeChanged);
    c.foreground.addListener(visibilityChanged);
  }

  void routeChanged() {
    if (routeKey == currentRoute) return;
    routeKey = currentRoute;
    stop();
    if (mounted) {
      setState(() {
        result = '';
        error = '';
      });
    }
  }

  void visibilityChanged() {
    if (!c.visible) stop();
  }

  void stop() {
    generation++;
    client?.close(force: true);
    client = null;
    if (mounted) setState(() => working = false);
  }

  Future<void> run() async {
    if (working) return;
    final raw = input.text.trim();
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      setState(
        () => error = 'Введите HTTPS-адрес, например https://example.com',
      );
      return;
    }
    final own = ++generation;
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 7);
    client = http;
    setState(() {
      working = true;
      result = '';
      error = '';
    });
    final elapsed = Stopwatch()..start();
    final timer = Timer(
      const Duration(seconds: 7),
      () => http.close(force: true),
    );
    try {
      final request = await http.openUrl('HEAD', uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'SVOI-Site-Check/1');
      final response = await request.close();
      if (!mounted || own != generation) return;
      final code = response.statusCode;
      setState(
        () => result =
            'Сайт ответил: HTTP $code · ${elapsed.elapsedMilliseconds} мс${code >= 300 && code < 400
                ? '\nСайт перенаправляет на другой адрес; переход не выполнялся.'
                : code >= 400
                ? '\nСервер доступен, но отклонил запрос. Попробуйте открыть сайт в браузере.'
                : ''}',
      );
    } catch (e) {
      if (mounted && own == generation) {
        setState(
          () => error = 'Ответ не получен. Проверьте адрес, интернет или выберите другой VPN-сервер.',
        );
      }
    } finally {
      timer.cancel();
      http.close(force: true);
      if (identical(client, http)) client = null;
      if (mounted && own == generation) setState(() => working = false);
    }
  }

  @override
  void dispose() {
    generation++;
    client?.close(force: true);
    c.connection.removeListener(routeChanged);
    c.foreground.removeListener(visibilityChanged);
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text('Проверить сайт', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      Text(
        c.connection.value['state'] == 'running'
            ? 'Через VPN · по правилам выбранного профиля'
            : 'По текущему подключению устройства',
        style: TextStyle(color: appColors(context).accent),
      ),
      const SizedBox(height: 12),
      const Text(
        'HEAD-запрос без загрузки страницы, до 7 секунд. Ответ 403 или 405 означает, что сервер доступен, но отклонил запрос приложения.',
      ),
      const SizedBox(height: 20),
      TextField(
        controller: input,
        keyboardType: TextInputType.url,
        autocorrect: false,
        enabled: !working,
        decoration: const InputDecoration(
          labelText: 'Адрес сайта',
          hintText: 'https://example.com',
        ),
        onSubmitted: (_) => run(),
      ),
      const SizedBox(height: 16),
      AppButton(
        label: working ? 'Остановить' : 'Проверить сайт',
        icon: LucideIcons.globe,
        primary: true,
        onPressed: working ? stop : run,
      ),
      const SizedBox(height: 20),
      if (result.isNotEmpty)
        Text(result, style: TextStyle(color: appColors(context).success)),
      if (error.isNotEmpty)
        Text(error, style: TextStyle(color: appColors(context).error)),
    ],
  );
}

class PortableToolsPage extends StatelessWidget {
  const PortableToolsPage({super.key, required this.c});
  final SvoiController c;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text(
        'Понятные проверки вашей сети.',
        style: TextStyle(color: appColors(context).muted),
      ),
      const SizedBox(height: 16),
      tool(
        context,
        'Интернетометр',
        'Без VPN и через выбранные серверы',
        LucideIcons.gauge,
        SpeedTools(c: c),
      ),
      tool(
        context,
        'Проверить сайт',
        'Ответ сайта в текущем подключении',
        LucideIcons.globe,
        CurrentSitePanel(c: c),
      ),
      tool(
        context,
        'Сравнить DNS',
        '12 адресов · отклик и стабильность',
        LucideIcons.network,
        DnsComparePanel(c: c),
      ),
      const SizedBox(height: 12),
      Text(
        'Проверки запускаются вручную. Скорость измеряется до svoi.space; DNS-тест не меняет настройки устройства.',
        style: TextStyle(color: appColors(context).muted),
      ),
    ],
  );

  Widget tool(
    BuildContext context,
    String title,
    String description,
    IconData icon,
    Widget panel,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Card(
      color: appColors(context).surface,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 14,
        ),
        leading: Icon(icon, color: appColors(context).accent),
        title: Text(title),
        subtitle: Text(description),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(title: Text(title)),
              body: SafeArea(child: panel),
            ),
          ),
        ),
      ),
    ),
  );
}
