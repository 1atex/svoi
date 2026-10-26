part of 'main.dart';

Future<void> showDesktopSheet(
  BuildContext context,
  String title,
  Widget child,
) => showDialog<void>(
  context: context,
  builder: (dialog) => Dialog(
    child: SizedBox(
      width: 780,
      height: MediaQuery.sizeOf(dialog).height * .85,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Закрыть',
                  onPressed: () => Navigator.pop(dialog),
                  icon: const Icon(LucideIcons.x),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(child: child),
        ],
      ),
    ),
  ),
);

class DesktopWorkspace extends StatelessWidget {
  const DesktopWorkspace({super.key, required this.c});
  final SvoiController c;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: c.servers,
    builder: (context, servers, _) {
      if (servers.isEmpty) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                children: [
                  ImportWelcome(c: c),
                  for (final source in c.subscriptions.value)
                    ListTile(
                      title: Text(source['name']?.toString() ?? 'Подписка'),
                      subtitle: const Text(
                        'Серверов пока нет · открыть настройки подписки',
                      ),
                      trailing: const Icon(LucideIcons.chevronRight),
                      onTap: () => editSource(context, c, source),
                    ),
                ],
              ),
            ),
          ),
        );
      }
      return LayoutBuilder(
        builder: (context, bounds) {
          final compact =
              bounds.maxWidth < 900 ||
              bounds.maxHeight < 620 ||
              MediaQuery.textScalerOf(context).scale(14) > 19;
          final library = DesktopLibrary(c: c);
          final dock = DesktopConnection(c: c, compact: compact);
          if (compact) {
            return Column(
              children: [
                Expanded(child: library),
                const Divider(),
                dock,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: library),
              const VerticalDivider(width: 1),
              SizedBox(width: 360, child: dock),
            ],
          );
        },
      );
    },
  );
}

class DesktopLibrary extends StatefulWidget {
  const DesktopLibrary({super.key, required this.c});
  final SvoiController c;
  @override
  State<DesktopLibrary> createState() => _DesktopLibraryState();
}

class _DesktopLibraryState extends State<DesktopLibrary> {
  final search = TextEditingController();
  final collapsed = <String>{};
  String query = '';
  bool favoritesOnly = false, byLatency = false;

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return ListenableBuilder(
      listenable: Listenable.merge([
        c.servers,
        c.subscriptions,
        c.favorites,
        c.lastUsed,
        c.probing,
        c.probeRevision,
        c.busy,
        c.connection,
      ]),
      builder: (context, _) {
        final filtered = c.orderedServers(
          c.servers.value.where(
            (s) =>
                s.search.contains(query) &&
                (!favoritesOnly || c.favorites.value.contains(s.id)),
          ),
          latency: byLatency,
        );
        final quick = filtered
            .where(
              (s) =>
                  c.favorites.value.contains(s.id) || s.id == c.lastUsed.value,
            )
            .toList();
        final knownSources = c.subscriptions.value
            .map((s) => s['id'].toString())
            .toSet();
        final groups =
            <(String, String, List<ServerEntry>, Map<String, dynamic>?)>[
              if (quick.isNotEmpty)
                ('quick', 'Избранные и недавние', quick, null),
              for (final source in c.subscriptions.value)
                (
                  'source:${source['id']}',
                  subscriptionDisplayName(source),
                  filtered
                      .where((s) => s.json['subscriptionId'] == source['id'])
                      .toList(),
                  source,
                ),
              (
                'imported',
                'Другие конфигурации',
                filtered
                    .where(
                      (s) => !knownSources.contains(s.json['subscriptionId']),
                    )
                    .toList(),
                null,
              ),
            ];
        final rows = <Object>[];
        for (final group in groups) {
          if (group.$3.isEmpty &&
              (query.isNotEmpty || favoritesOnly || group.$4 == null)) {
            continue;
          }
          rows.add(group);
          if (!collapsed.contains(group.$1) || query.isNotEmpty) {
            rows.addAll(group.$3);
          }
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (MediaQuery.sizeOf(context).width >= 900) ...[
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Серверы',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    AppButton(
                      label: 'Добавить подписку',
                      icon: LucideIcons.plus,
                      onPressed: c.busy.value
                          ? null
                          : () => importDialog(context, c),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('desktop-server-search'),
                  controller: search,
                  onChanged: (value) =>
                      setState(() => query = value.trim().toLowerCase()),
                  decoration: InputDecoration(
                    hintText: 'Поиск по имени, стране или адресу',
                    isDense: true,
                    prefixIcon: const Icon(LucideIcons.search, size: 18),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Очистить поиск',
                            icon: const Icon(LucideIcons.x, size: 16),
                            onPressed: () {
                              search.clear();
                              setState(() => query = '');
                            },
                          ),
                  ),
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('desktop-server-search'),
                        controller: search,
                        onChanged: (value) =>
                            setState(() => query = value.trim().toLowerCase()),
                        decoration: InputDecoration(
                          hintText: 'Поиск по имени, стране или адресу',
                          isDense: true,
                          prefixIcon: const Icon(LucideIcons.search, size: 18),
                          suffixIcon: query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Очистить поиск',
                                  icon: const Icon(LucideIcons.x, size: 16),
                                  onPressed: () {
                                    search.clear();
                                    setState(() => query = '');
                                  },
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    AppButton(
                      label: 'Добавить подписку',
                      icon: LucideIcons.plus,
                      onPressed: c.busy.value
                          ? null
                          : () => importDialog(context, c),
                    ),
                  ],
                ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilterChip(
                    label: const Text('Избранные'),
                    avatar: const Icon(LucideIcons.star, size: 14),
                    selected: favoritesOnly,
                    onSelected: (v) => setState(() => favoritesOnly = v),
                  ),
                  FilterChip(
                    label: const Text('По задержке'),
                    selected: byLatency,
                    onSelected: (v) => setState(() => byLatency = v),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: filtered.isEmpty && (query.isNotEmpty || favoritesOnly)
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Серверы не найдены',
                              style: TextStyle(color: muted),
                            ),
                            TextButton(
                              onPressed: () {
                                search.clear();
                                setState(() {
                                  query = '';
                                  favoritesOnly = false;
                                });
                              },
                              child: const Text('Сбросить фильтры'),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        key: const PageStorageKey('desktop-library'),
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          if (row is ServerEntry) {
                            return DesktopServerRow(
                              key: ValueKey('row-$index-${row.id}'),
                              c: c,
                              server: row,
                            );
                          }
                          final group =
                              row
                                  as (
                                    String,
                                    String,
                                    List<ServerEntry>,
                                    Map<String, dynamic>?,
                                  );
                          return SubscriptionHeader(
                            name: group.$2,
                            source: group.$4,
                            count: group.$3.length,
                            collapsed:
                                collapsed.contains(group.$1) && query.isEmpty,
                            onToggle: () => setState(() {
                              if (!collapsed.add(group.$1)) {
                                collapsed.remove(group.$1);
                              }
                            }),
                            onRefresh:
                                group.$4?['remote'] == true && !c.busy.value
                                ? () => c.refreshSource(
                                    group.$4!['id'].toString(),
                                  )
                                : null,
                            onProbe:
                                group.$3.isNotEmpty &&
                                    !c.probing.value &&
                                    c.connection.value['available'] == true
                                ? () => c.probe(group.$3)
                                : null,
                            onDetails: group.$4 == null
                                ? null
                                : () => editSource(context, c, group.$4!),
                          );
                        },
                      ),
              ),
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      filtered.length == c.servers.value.length
                          ? '${filtered.length} серверов'
                          : '${filtered.length} из ${c.servers.value.length} серверов',
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: c.probing.value
                        ? c.cancelProbes
                        : c.connection.value['available'] == true &&
                              filtered.isNotEmpty
                        ? () => c.probe(filtered)
                        : null,
                    icon: Icon(
                      c.probing.value
                          ? LucideIcons.square
                          : LucideIcons.activity,
                      size: 16,
                    ),
                    label: Text(
                      c.probing.value ? 'Остановить' : 'Проверить задержку',
                    ),
                  ),
                ],
              ),
              ValueListenableBuilder(
                valueListenable: c.probeProgress,
                builder: (context, value, _) => value.isEmpty
                    ? const SizedBox.shrink()
                    : Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class DesktopServerRow extends StatelessWidget {
  const DesktopServerRow({super.key, required this.c, required this.server});
  final SvoiController c;
  final ServerEntry server;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      c.selected,
      c.connection,
      c.favorites,
      c.busy,
      c.probing,
    ]),
    builder: (context, _) {
      final selected = c.selected.value == server.id;
      final active =
          c.connection.value['state'] == 'running' &&
          c.connection.value['serverId'] == server.id;
      return Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Material(
          color: selected ? const Color(0xff30291e) : surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected
                  ? accent.withValues(alpha: .5)
                  : Colors.transparent,
            ),
          ),
          child: InkWell(
            key: ValueKey('select-server-${server.id}'),
            borderRadius: BorderRadius.circular(12),
            onTap: c.busy.value ? null : () => c.select(server.id),
            child: Semantics(
              selected: selected,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  children: [
                    CountryMark(country: server.country),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            server.country.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            active
                                ? 'Подключён'
                                : selected
                                ? 'Выбран'
                                : c.favorites.value.contains(server.id)
                                ? 'Избранный'
                                : server.id == c.lastUsed.value
                                ? 'Последний запуск'
                                : server.country.label,
                            style: TextStyle(
                              fontSize: 11,
                              color: active ? success : muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    ValueListenableBuilder(
                      valueListenable: c.probes.putIfAbsent(
                        server.id,
                        () => ValueNotifier(const ProbeState()),
                      ),
                      builder: (context, probe, _) => Tooltip(
                        message:
                            '${probe.error ?? 'Задержка HTTPS через профиль, не ICMP-пинг'}\n${clockLabel(probe.checkedAt)}${probe.busy && probe.latency != null ? '\nПредыдущий результат: ${probe.latency} мс' : ''}',
                        child: TextButton(
                          onPressed:
                              probe.busy ||
                                  c.probing.value ||
                                  c.connection.value['available'] != true
                              ? null
                              : () => c.probe([server]),
                          child: Text(
                            probe.busy
                                ? 'Проверяется'
                                : probe.error != null
                                ? 'Нет ответа'
                                : probe.latency != null
                                ? '${probe.latency} мс'
                                : 'Не проверен',
                            style: TextStyle(
                              fontSize: 11,
                              color: probe.error != null
                                  ? const Color(0xffffaaa6)
                                  : probe.latency != null
                                  ? success
                                  : muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Действия сервера',
                      icon: const Icon(
                        LucideIcons.ellipsis,
                        size: 18,
                        color: muted,
                      ),
                      onSelected: (value) {
                        if (value == 'config') {
                          showConfig(context, c, server);
                        } else if (value == 'tcp') {
                          showTCPCheck(context, c, server);
                        } else {
                          c.toggleFavorite(server.id);
                        }
                      },
                      itemBuilder: (context) => [
                        if (server.json['fullProfile'] != true &&
                            !server.usesQuic)
                          const PopupMenuItem(
                            value: 'tcp',
                            child: Text('Проверить адрес · TCP'),
                          ),
                        const PopupMenuItem(
                          value: 'config',
                          child: Text('Конфигурация'),
                        ),
                        PopupMenuItem(
                          value: 'favorite',
                          child: Text(
                            c.favorites.value.contains(server.id)
                                ? 'Убрать из избранного'
                                : 'В избранное',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class DesktopConnection extends StatelessWidget {
  const DesktopConnection({super.key, required this.c, required this.compact});
  final SvoiController c;
  final bool compact;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      c.connection,
      c.selected,
      c.servers,
      c.mode,
      c.busy,
      c.connectionPhase,
      c.connectionIssue,
      c.preferences,
    ]),
    builder: (context, _) {
      final view = ConnectionView(c);
      final server = c.servers.value
          .where((s) => s.id == c.selected.value)
          .firstOrNull;
      final pending = c.pendingConnectionChoice;
      final locked = c.busy.value || view.phase.isNotEmpty;
      final ready = c.connection.value['available'] == true && server != null;
      final action = view.running ? 'Отключить VPN' : 'Подключить';
      final VoidCallback? toggle = locked || (!view.running && !ready)
          ? null
          : view.running
          ? c.stop
          : c.toggleConnection;
      final active = c.servers.value
          .where((s) => s.id == c.connection.value['serverId'])
          .firstOrNull;
      final detail = view.phase.isNotEmpty
          ? view.detail
          : view.error.isNotEmpty
          ? view.running
                ? 'Проверка интернета не прошла. VPN остаётся включён.'
                : 'Подключение не удалось. Посмотрите подробности.'
          : view.verified
          ? 'Интернет проверен'
          : view.running
          ? 'Соединение запущено'
          : 'Выберите сервер и подключитесь';
      final selection = Row(
        children: [
          CountryMark(
            country: server?.country ?? const ServerCountry(null, ''),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  server?.country.title ?? 'Выберите сервер',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  pending ? 'Выбран для переключения' : 'Выбранный сервер',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Конфигурация сервера',
            onPressed: server == null
                ? null
                : () => showConfig(context, c, server),
            icon: const Icon(LucideIcons.fileCode, size: 18),
          ),
        ],
      );
      final controls = Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          if (pending)
            FilledButton(
              key: const ValueKey('switch-server'),
              onPressed: locked || !ready ? null : c.toggleConnection,
              child: const Text('Переключиться'),
            ),
          if (compact && pending)
            OutlinedButton(onPressed: toggle, child: Text(action))
          else if (compact)
            FilledButton(
              key: const ValueKey('desktop-connect'),
              onPressed: toggle,
              child: Text(view.phase.isNotEmpty ? view.title : action),
            ),
        ],
      );
      if (compact) {
        return Material(
          color: surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: selection),
                    const SizedBox(width: 16),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * .48,
                      ),
                      child: controls,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      view.verified ? LucideIcons.check : LucideIcons.power,
                      size: 14,
                      color: view.verified ? success : accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        pending
                            ? '${view.title} · сейчас ${active?.country.title ?? c.connection.value['serverName'] ?? 'другой сервер'}'
                            : view.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    Flexible(
                      fit: FlexFit.tight,
                      child: TextButton.icon(
                        onPressed: () => showDesktopSheet(
                          context,
                          'Параметры подключения',
                          SingleChildScrollView(
                            padding: const EdgeInsets.all(20),
                            child: ListenableBuilder(
                              listenable: Listenable.merge([
                                c.mode,
                                c.preferences,
                                c.busy,
                                c.connection,
                              ]),
                              builder: (context, _) => ModePicker(c: c),
                            ),
                          ),
                        ),
                        icon: const Icon(LucideIcons.chevronDown, size: 14),
                        label: Text(
                          modeLabel(
                            c.mode.value,
                            Map<String, dynamic>.from(
                              c.preferences.value['routing'] ?? {},
                            ),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Подробнее о соединении',
                      onPressed: () => showDiagnostics(context, c),
                      icon: const Icon(LucideIcons.info, size: 18),
                    ),
                  ],
                ),
                if (view.error.isNotEmpty)
                  Text(
                    detail,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xffffaaa6),
                    ),
                  ),
              ],
            ),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Eyebrow('ВАШЕ ПОДКЛЮЧЕНИЕ'),
            const SizedBox(height: 16),
            selection,
            const SizedBox(height: 8),
            Center(
              child: ConnectionOrbit(
                running: view.running,
                verified: view.verified,
                busy: view.phase.isNotEmpty,
                onPressed: toggle,
                hint: action,
              ),
            ),
            Text(
              view.title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: muted, height: 1.5),
            ),
            if (pending)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Сейчас: ${active?.country.title ?? c.connection.value['serverName'] ?? 'другой сервер'} · ${modeLabel(c.connection.value['mode'], null)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: accent),
                ),
              ),
            if (pending) ...[const SizedBox(height: 16), controls],
            const SizedBox(height: 20),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: 24),
                child: Column(
                  children: [
                    ModePicker(c: c),
                    const SizedBox(height: 12),
                    if (view.running)
                      TextButton.icon(
                        onPressed: locked ? null : c.check,
                        icon: const Icon(LucideIcons.refreshCw, size: 15),
                        label: const Text('Проверить интернет'),
                      ),
                    TextButton.icon(
                      onPressed: () => showDiagnostics(context, c),
                      icon: const Icon(LucideIcons.info, size: 15),
                      label: const Text('Подробнее о соединении'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
