part of 'main.dart';

class SpeedTools extends StatefulWidget {
  const SpeedTools({super.key, required this.c});
  final SvoiController c;
  @override
  State<SpeedTools> createState() => _SpeedToolsState();
}

class _SpeedToolsState extends State<SpeedTools> {
  SvoiController get c => widget.c;
  final selected = <String>{};
  final search = TextEditingController();
  Timer? timer;
  TabController? toolTabs;
  RequestCancellation? polling;
  Map<String, dynamic> data = {};
  String error = '', query = '', groupId = '', routeKey = '';
  bool working = false, stopping = false, starting = false, showSetup = true;
  int generation = 0;
  String get currentRoute =>
      '${c.connection.value['state']}/${c.connection.value['serverId']}/${c.connection.value['startedAt']}';
  bool get tunActive =>
      c.connection.value['state'] == 'running' &&
      c.connection.value['mode'] == 'tun';
  List<Map<String, dynamic>> get results => (data['results'] as List? ?? [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  @override
  void initState() {
    super.initState();
    groupId = c.group.value['id']?.toString() ?? '';
    routeKey = currentRoute;
    final saved = c.speedView.value;
    if (saved['groupId'] == groupId) {
      data = Map<String, dynamic>.from(saved['data'] as Map? ?? {});
      selected.addAll(
        (saved['selected'] as List? ?? []).map((e) => e.toString()),
      );
    }
    if (selected.isEmpty &&
        c.servers.value.any((s) => s.id == c.selected.value)) {
      selected.add(c.selected.value);
    }
    selected.removeWhere((id) => !c.servers.value.any((s) => s.id == id));
    working = data['state'] == 'running';
    showSetup = results.isEmpty;
    if (working) _schedule();
    c.group.addListener(_groupChanged);
    c.connection.addListener(_routeChanged);
    c.connectionPhase.addListener(_phaseChanged);
    c.busy.addListener(_busyChanged);
    c.foreground.addListener(_visibilityChanged);
    c.servers.addListener(_serversChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = DefaultTabController.maybeOf(context);
    if (next != toolTabs) {
      toolTabs?.removeListener(_tabChanged);
      toolTabs = next;
      toolTabs?.addListener(_tabChanged);
    }
  }

  void _tabChanged() {
    if (toolTabs?.index != 0 && working) unawaited(stop());
  }

  void _save() {
    c.speedView.value = {
      'groupId': groupId,
      'selected': selected.toList(),
      'data': data,
    };
  }

  void _groupChanged() {
    final next = c.group.value['id']?.toString() ?? '';
    if (next == groupId) return;
    if (working) unawaited(_cancel());
    generation++;
    timer?.cancel();
    polling?.cancel();
    groupId = next;
    selected.clear();
    showSetup = true;
    data = {};
    working = false;
    starting = false;
    stopping = false;
    error = '';
    _save();
    if (mounted) setState(() {});
  }

  void _routeChanged() {
    if (routeKey == currentRoute) return;
    routeKey = currentRoute;
    if (working) unawaited(stop());
    if (mounted) setState(() {});
  }

  void _phaseChanged() {
    if (c.connectionPhase.value.isNotEmpty && working) unawaited(stop());
    if (mounted) setState(() {});
  }

  void _busyChanged() {
    if (mounted) setState(() {});
  }

  void _visibilityChanged() {
    if (!c.visible && working) unawaited(stop());
  }

  void _serversChanged() {
    if (!working) {
      selected.removeWhere((id) => !c.servers.value.any((s) => s.id == id));
    }
    if (mounted) setState(() {});
  }

  Future<void> _cancel() async {
    try {
      await c.api.request('tools/speed/cancel', method: 'POST');
    } catch (_) {}
  }

  Future<void> stop() async {
    if (!working || stopping) return;
    setState(() => stopping = true);
    await _cancel();
    if (!starting && mounted) _schedule(immediate: true);
  }

  Future<void> start() async {
    if (working ||
        tunActive ||
        c.busy.value ||
        c.connectionPhase.value.isNotEmpty) {
      return;
    }
    c.cancelProbes();
    final own = ++generation;
    final previous = data;
    setState(() {
      working = true;
      showSetup = false;
      starting = true;
      stopping = false;
      error = '';
      data = {};
    });
    try {
      final started = await c.api.request(
        'tools/speed/start',
        method: 'POST',
        body: {'serverIds': selected.toList()},
      );
      if (!mounted || own != generation) {
        await _cancel();
        return;
      }
      data = {'id': started['id'], 'state': 'running', 'results': []};
      _save();
      if (stopping) await _cancel();
      starting = false;
      await poll();
    } catch (e) {
      if (mounted && own == generation) {
        setState(() {
          working = false;
          starting = false;
          stopping = false;
          error = e.toString();
          showSetup = true;
          data = previous;
        });
      }
    }
  }

  void _schedule({bool immediate = false}) {
    timer?.cancel();
    if (working && mounted) {
      timer = Timer(
        Duration(milliseconds: immediate ? 1 : 500),
        () => unawaited(poll()),
      );
    }
  }

  Future<void> poll() async {
    if (!working || data['id'] == null) return;
    final own = generation;
    final request = RequestCancellation();
    polling = request;
    try {
      final result = await c.api.request(
        'tools/speed/status?id=${Uri.encodeQueryComponent(data['id'].toString())}',
        cancellation: request,
      );
      if (!mounted || own != generation) return;
      setState(() {
        data = result;
        working = result['state'] == 'running';
        if (!working) stopping = false;
      });
      _save();
      _schedule();
    } catch (e) {
      if (mounted && own == generation) {
        await _cancel();
        if (mounted && own == generation) {
          setState(() {
            working = false;
            stopping = false;
            error = 'Не удалось получить результат. ${e.toString()}';
            data = {
              ...data,
              'state': 'cancelled',
              'results': results
                  .map(
                    (row) =>
                        row['state'] == 'running' || row['state'] == 'queued'
                        ? {...row, 'state': 'cancelled'}
                        : row,
                  )
                  .toList(),
            };
          });
          _save();
        }
      }
    } finally {
      if (polling == request) polling = null;
    }
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    polling?.cancel();
    toolTabs?.removeListener(_tabChanged);
    if (working) unawaited(_cancel());
    c.group.removeListener(_groupChanged);
    c.connection.removeListener(_routeChanged);
    c.connectionPhase.removeListener(_phaseChanged);
    c.busy.removeListener(_busyChanged);
    c.foreground.removeListener(_visibilityChanged);
    c.servers.removeListener(_serversChanged);
    search.dispose();
    super.dispose();
  }

  String phase(Map<String, dynamic> row) => switch (row['state']) {
    'queued' => 'Ожидает',
    'error' => 'Ошибка замера',
    'cancelled' => 'Остановлено',
    'done' => 'Готово',
    _ => switch (row['phase']) {
      'latency' => 'Проверяем отклик',
      'download' => 'Измеряем загрузку',
      'upload' => 'Измеряем отдачу',
      _ => 'Готовим маршрут',
    },
  };
  String number(Object? value) =>
      value is num ? value.toStringAsFixed(value >= 100 ? 0 : 1) : '—';

  @override
  Widget build(BuildContext context) {
    final p = appColors(context);
    final visible = c.servers.value
        .where((s) => query.isEmpty || s.search.contains(query))
        .toList();
    final rows = results;
    final active = rows.where((r) => r['state'] == 'running').firstOrNull;
    final completed = rows.where((r) => r['state'] == 'done').length;
    return Column(
      children: [
        Expanded(
          child: ListView(
            key: const ValueKey('speed-results-scroll'),
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'Сравните своё подключение',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Сначала без VPN, затем через выбранные серверы. Один тестовый узел, одинаковые условия.',
                style: TextStyle(color: p.muted, height: 1.6),
              ),
              const SizedBox(height: 22),
              if (showSetup)
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.speed_rounded, color: p.accent),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Серверы для сравнения',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Text(
                            '${selected.length} / 3',
                            style: TextStyle(color: p.muted, fontSize: 12),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Прямое соединение добавляется автоматически. Выберите до трёх серверов — они проверяются по очереди.',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: search,
                        onChanged: (v) =>
                            setState(() => query = v.trim().toLowerCase()),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search, size: 18),
                          hintText: 'Найти сервер',
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (c.servers.value.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Text(
                            'Добавьте подписку для сравнения серверов. Прямое соединение можно проверить уже сейчас.',
                            style: TextStyle(color: p.muted, height: 1.6),
                          ),
                        ),
                      if (c.servers.value.isNotEmpty)
                        SizedBox(
                          height: visible.length < 4
                              ? visible.length * 64.0 + 8
                              : 220,
                          child: Scrollbar(
                            child: ListView.builder(
                              itemCount: visible.length,
                              itemBuilder: (context, i) {
                                final s = visible[i];
                                return CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  value: selected.contains(s.id),
                                  onChanged: working
                                      ? null
                                      : (value) {
                                          if (value == true &&
                                              selected.length >= 3) {
                                            setState(
                                              () => error = 'Можно сравнить до трёх серверов за один запуск.',
                                            );
                                            return;
                                          }
                                          setState(() {
                                            if (value == true) {
                                              selected.add(s.id);
                                            } else {
                                              selected.remove(s.id);
                                            }
                                            error = '';
                                          });
                                          _save();
                                        },
                                  title: Text(
                                    s.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    s.json['fullProfile'] == true
                                        ? 'Полный профиль Xray'
                                        : '${s.protocol.toUpperCase()} · ${s.country.title}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      if (visible.isEmpty && c.servers.value.isNotEmpty)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('Серверы не найдены. Измените поиск.'),
                        ),
                      const SizedBox(height: 14),
                      Text(
                        'Тестовый узел: svoi.space. Измеряется скорость до него, а не максимальная скорость всех сайтов.',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          height: 1.6,
                        ),
                      ),
                    ],
                  ),
                ),
              if (!showSetup)
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      selected.isEmpty
                          ? 'Только напрямую'
                          : 'Напрямую + ${selected.length} сервер${selected.length == 1 ? '' : 'а'}',
                      style: TextStyle(color: p.muted),
                    ),
                    if (!working)
                      TextButton(
                        onPressed: () => setState(() => showSetup = true),
                        child: const Text('Изменить серверы'),
                      ),
                  ],
                ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    error,
                    style: TextStyle(color: p.error, height: 1.6),
                  ),
                ),
              if (working)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(
                        starting
                            ? 'Запускаем сравнение…'
                            : stopping
                            ? 'Завершаем текущий замер…'
                            : '${active?['name'] ?? ''} · ${active == null ? 'Готовим маршрут' : phase(active)} · готово $completed из ${rows.length}',
                        style: TextStyle(color: p.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              if (rows.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  working
                      ? 'Результаты по мере готовности'
                      : data['state'] == 'cancelled'
                      ? 'Проверка остановлена · готовые результаты сохранены'
                      : 'Последнее сравнение',
                  style: TextStyle(
                    color: p.ink,
                    fontWeight: FontWeight.w600,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 14),
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            spacing: 18,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    row['name']?.toString() ?? '',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    row['protocol']?.toString() ?? '',
                                    style: TextStyle(
                                      color: p.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                phase(row),
                                style: TextStyle(
                                  color: row['state'] == 'error'
                                      ? p.error
                                      : p.muted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 28,
                            runSpacing: 14,
                            children: [
                              _metric(
                                'Загрузка',
                                number(row['downloadMbps']),
                                'Мбит/с',
                                p,
                              ),
                              _metric(
                                'Отдача',
                                number(row['uploadMbps']),
                                'Мбит/с',
                                p,
                              ),
                              _metric(
                                'Отклик',
                                number(row['latencyMs']),
                                'мс',
                                p,
                              ),
                            ],
                          ),
                          if (row['serverId'] != '' &&
                              rows.firstOrNull?['state'] == 'done' &&
                              row['state'] == 'done' &&
                              rows.firstOrNull?['downloadMbps'] is num &&
                              row['downloadMbps'] is num &&
                              ((rows.first['downloadMbps'] as num) > 0))
                            Padding(
                              padding: const EdgeInsets.only(top: 15),
                              child: Text(
                                '${((row['downloadMbps'] as num) / (rows.first['downloadMbps'] as num) * 100).toStringAsFixed(0)}% от загрузки напрямую',
                                style: TextStyle(color: p.muted, fontSize: 12),
                              ),
                            ),
                          if (row['warning']?.toString().isNotEmpty == true)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                row['warning'].toString(),
                                style: TextStyle(
                                  color: p.accent,
                                  fontSize: 12,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          if (row['error']?.toString().isNotEmpty == true)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                row['error'].toString(),
                                style: TextStyle(
                                  color: p.error,
                                  fontSize: 12,
                                  height: 1.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                Text(
                  'Отклик — медиана HTTPS-запросов без нагрузки. Сравниваются конкретные серверы и маршруты; результат не является рейтингом протоколов.',
                  style: TextStyle(color: p.muted, fontSize: 12, height: 1.6),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'До ${(selected.length + 1) * 48} МиБ · обычно 10–20 с на маршрут',
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
              if (tunActive)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    'Для сравнения сначала отключите TUN на вкладке «Подключение». SVOI не отключает VPN автоматически.',
                    style: TextStyle(color: p.accent, height: 1.6),
                  ),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed:
                        working ||
                            tunActive ||
                            c.busy.value ||
                            c.connectionPhase.value.isNotEmpty
                        ? null
                        : start,
                    icon: const Icon(Icons.play_arrow_rounded, size: 19),
                    label: Text(working ? 'Идёт замер…' : 'Сравнить скорость'),
                  ),
                  if (working)
                    OutlinedButton.icon(
                      onPressed: stopping ? null : stop,
                      icon: const Icon(Icons.stop_rounded, size: 18),
                      label: Text(stopping ? 'Останавливаем…' : 'Остановить'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _metric(String label, String value, String unit, SvoiColors p) =>
      SizedBox(
        width: 130,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: p.muted, fontSize: 12)),
            const SizedBox(height: 5),
            RichText(
              text: TextSpan(
                style: TextStyle(color: p.ink, fontFamily: 'Segoe UI'),
                children: [
                  TextSpan(
                    text: value,
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(
                    text: ' $unit',
                    style: TextStyle(color: p.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}
