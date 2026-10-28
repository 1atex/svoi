part of 'main.dart';

Future<void> showTCPCheck(
  BuildContext context,
  SvoiController c,
  ServerEntry server,
) async {
  final cancellation = RequestCancellation();
  final result = c.api.request(
    'servers/${Uri.encodeComponent(server.id)}/tcp',
    method: 'POST',
    cancellation: cancellation,
  );
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Доступность · ${server.country.title}'),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<Map<String, dynamic>>(
          future: result,
          builder: (context, snapshot) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (snapshot.connectionState != ConnectionState.done)
                const LinearProgressIndicator()
              else
                Text(
                  snapshot.hasError
                      ? snapshot.error.toString()
                      : 'TCP-соединение: ${snapshot.data!['latency']} мс',
                  style: TextStyle(
                    color: snapshot.hasError
                        ? appColors(context).error
                        : appColors(context).success,
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                'Проверяется только соединение с адресом сервера, максимум 2 секунды. Это не проверка VPN или скорости загрузки. При включённом TUN запрос следует текущим маршрутам.',
                style: TextStyle(color: appColors(context).muted, height: 1.5),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
  cancellation.cancel();
}

class DnsTools extends StatefulWidget {
  const DnsTools({super.key, required this.c});
  final SvoiController c;
  @override
  State<DnsTools> createState() => _DnsToolsState();
}

class _DnsToolsState extends State<DnsTools> {
  Map<String, dynamic> data = {};
  final results = <String, Map<String, dynamic>>{};
  final requests = <RequestCancellation>{};
  String error = '', selected = '', progress = '';
  bool loading = false, testing = false, changing = false;
  int generation = 0;
  String routeKey = '';
  SvoiController get c => widget.c;
  List<Map<String, dynamic>> get adapters => (data['adapters'] as List? ?? [])
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
  Map<String, String> get candidates => {
    for (final adapter in adapters)
      for (final address in adapter['servers'] as List? ?? [])
        address.toString(): 'Текущий · ${adapter['name']}',
    for (final candidate in data['candidates'] as List? ?? [])
      candidate['address'].toString(): candidate['name'].toString(),
  };
  bool get vpnRunning => c.connection.value['state'] == 'running';
  String get connectionKey => jsonEncode([
    c.connection.value['state'],
    c.connection.value['serverId'],
    c.connection.value['mode'],
    c.connection.value['startedAt'],
  ]);

  @override
  void initState() {
    super.initState();
    routeKey = connectionKey;
    c.connection.addListener(routeChanged);
    unawaited(load());
  }

  void routeChanged() {
    if (routeKey == connectionKey) return;
    routeKey = connectionKey;
    cancel();
    if (mounted) {
      setState(() {
        results.clear();
        progress = 'Подключение изменилось. Повторите проверку.';
      });
    }
  }

  Future<void> load() async {
    if (loading) return;
    setState(() {
      loading = true;
      error = '';
    });
    final cancellation = RequestCancellation();
    requests.add(cancellation);
    try {
      final next = await c.api.request('dns', cancellation: cancellation);
      if (mounted) {
        setState(() {
          data = next;
          if (!adapters.any((a) => a['id'] == selected)) {
            selected = adapters.firstOrNull?['id']?.toString() ?? '';
          }
        });
      }
    } catch (e) {
      if (mounted && !cancellation.cancelled) {
        setState(() => error = e.toString());
      }
    } finally {
      requests.remove(cancellation);
      if (mounted) setState(() => loading = false);
    }
  }

  void cancel() {
    generation++;
    for (final request in requests) {
      request.cancel();
    }
    requests.clear();
    if (mounted) {
      setState(() {
        testing = false;
        progress = 'Проверка остановлена. Готовые результаты сохранены.';
      });
    }
  }

  Future<void> benchmark() async {
    if (testing || loading || changing) return;
    if (!mounted || error.isNotEmpty) return;
    final current = ++generation;
    final addresses = candidates.keys.toList();
    setState(() {
      testing = true;
      results.clear();
      progress = '0 из ${addresses.length}';
    });
    var next = 0, done = 0;
    Future<void> worker() async {
      while (mounted && current == generation && next < addresses.length) {
        final address = addresses[next++];
        final request = RequestCancellation();
        requests.add(request);
        try {
          final response = await c.api.request(
            'dns/benchmark',
            method: 'POST',
            body: {'address': address},
            cancellation: request,
          );
          if (mounted && current == generation) {
            setState(() => results[address] = response);
          }
        } catch (e) {
          if (mounted && current == generation) {
            setState(() => results[address] = {'error': e.toString()});
          }
        } finally {
          requests.remove(request);
        }
        if (mounted && current == generation) {
          setState(() {
            done++;
            progress = '$done из ${addresses.length} · 6 DNS-запросов на адрес';
          });
        }
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));
    if (mounted && current == generation) setState(() => testing = false);
  }

  Future<void> change({String? address}) async {
    final restore = address == null;
    final adapter = adapters.where((a) => a['id'] == selected).firstOrNull;
    if (!await confirmAction(
      context,
      restore ? 'Восстановить DNS?' : 'Применить DNS $address?',
      restore
          ? 'SVOI вернёт прежний IPv4 DNS, включая автоматическое получение, на сохранённом адаптере.'
          : 'Будет изменён IPv4 DNS адаптера «${adapter?['name']}». Прежние настройки сохранятся для восстановления. DNS профиля VPN и настройки DNS в браузере не меняются.',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      changing = true;
      error = '';
    });
    try {
      await c.api.request(
        restore ? 'dns/restore' : 'dns/apply',
        method: 'POST',
        body: restore ? null : {'id': selected, 'address': address},
      );
      if (mounted) {
        setState(() {
          results.clear();
          progress = restore
              ? 'Прежний DNS восстановлен.'
              : 'DNS применён. Можно повторить тест.';
        });
        await load();
      }
    } catch (e) {
      if (mounted) {
        await load();
        if (mounted) setState(() => error = e.toString());
      }
    } finally {
      if (mounted) setState(() => changing = false);
    }
  }

  @override
  void dispose() {
    generation++;
    for (final request in requests) {
      request.cancel();
    }
    c.connection.removeListener(routeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reliable =
        results.entries
            .where((e) => e.value['success'] == 6 && e.value['total'] == 6)
            .toList()
          ..sort(
            (a, b) => (a.value['medianMs'] as num).compareTo(
              b.value['medianMs'] as num,
            ),
          );
    final winner =
        !testing &&
            !vpnRunning &&
            results.length == candidates.length &&
            reliable.isNotEmpty
        ? reliable.first.key
        : null;
    final public = (data['candidates'] as List? ?? [])
        .map((e) => e['address'])
        .toSet();
    final disabled = testing || loading || changing;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      children: [
        const Text(
          'Подобрать DNS',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'Сравнение реальными запросами к трём доменам: первый и повторный проход. Быстрый DNS не означает более высокую скорость скачивания.',
          style: TextStyle(color: appColors(context).muted, height: 1.5),
        ),
        const SizedBox(height: 16),
        Text(
          vpnRunning
              ? 'VPN включён · результаты зависят от маршрутов. TUN может перенаправлять DNS на сервер из профиля.'
              : 'VPN выключен · проверка по текущей сети Windows',
          style: TextStyle(color: appColors(context).accent),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: testing
                  ? cancel
                  : disabled || candidates.isEmpty
                  ? null
                  : benchmark,
              icon: SvoiIcon(testing ? Icons.stop : Icons.speed),
              label: Text(testing ? 'Остановить' : 'Сравнить DNS'),
            ),
            OutlinedButton(
              onPressed: disabled ? null : load,
              child: const Text('Обновить адаптеры'),
            ),
          ],
        ),
        if (loading || changing)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error,
              style: TextStyle(color: appColors(context).error),
            ),
          ),
        if (progress.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              progress,
              style: TextStyle(color: appColors(context).muted),
            ),
          ),
        const SizedBox(height: 12),
        for (final candidate in candidates.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: appColors(context).surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: winner == candidate.key
                      ? appColors(context).accent
                      : appColors(context).edge,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${candidate.value} · ${candidate.key}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  if (results[candidate.key] case final result?) ...[
                    if (result['error'] != null)
                      Text(
                        result['error'].toString(),
                        style: TextStyle(color: appColors(context).error),
                      )
                    else if (result['success'] == 0)
                      Text(
                        'Нет ответов · 0 из 6',
                        style: TextStyle(color: appColors(context).error),
                      )
                    else
                      Text(
                        'Медиана ${(result['medianMs'] as num).toStringAsFixed(1)} мс · максимум ${(result['worstMs'] as num).toStringAsFixed(1)} мс · ответов ${result['success']}/${result['total']}',
                        style: TextStyle(color: appColors(context).muted),
                      ),
                    if (winner == candidate.key)
                      Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'Лучший результат этого теста',
                          style: TextStyle(color: appColors(context).accent),
                        ),
                      ),
                    if (public.contains(candidate.key) &&
                        result['success'] == 6)
                      TextButton(
                        onPressed:
                            disabled ||
                                vpnRunning ||
                                data['elevated'] != true ||
                                selected.isEmpty
                            ? null
                            : () => change(address: candidate.key),
                        child: const Text('Применить для адаптера'),
                      ),
                  ] else
                    Text(
                      testing ? 'Ожидает результата…' : 'Ещё не проверен',
                      style: TextStyle(color: appColors(context).muted),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        if (adapters.isNotEmpty)
          DropdownButtonFormField<String>(
            key: ValueKey(selected),
            initialValue: selected,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Адаптер для изменения DNS',
            ),
            items: [
              for (final a in adapters)
                DropdownMenuItem(
                  value: a['id'].toString(),
                  child: Text(
                    a['name'].toString(),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: disabled
                ? null
                : (value) => setState(() => selected = value ?? ''),
          ),
        const SizedBox(height: 12),
        Text(
          'Тест обычного DNS (UDP/TCP, IPv4). DoH, IPv6 и DNS внутри VPN не изменяются. Результат зависит от сети и кэша; перед выбором повторите тест. Для изменения DNS отключите VPN и запустите SVOI от администратора.',
          style: TextStyle(
            color: appColors(context).muted,
            fontSize: 12,
            height: 1.5,
          ),
        ),
        if (data['backup'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton(
              onPressed: disabled || vpnRunning || data['elevated'] != true
                  ? null
                  : () => change(),
              child: Text('Восстановить DNS · ${data['backup']['name']}'),
            ),
          ),
      ],
    );
  }
}
