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
                  icon: const SvoiIcon(LucideIcons.x),
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
      if (servers.isEmpty && c.subscriptions.value.isEmpty) {
        return ListenableBuilder(
          listenable: Listenable.merge([
            c.subscriptions,
            c.refreshingSources,
            c.refreshErrors,
            c.busy,
          ]),
          builder: (context, _) => SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  children: [
                    if (c.subscriptions.value.isEmpty)
                      ImportWelcome(c: c)
                    else ...[
                      CorePicker(c: c),
                      const SizedBox(height: 20),
                      const Text(
                        'Нет конфигураций для выбранного ядра. Обновите подписку или выберите другое ядро.',
                      ),
                      const SizedBox(height: 20),
                    ],
                    for (final source in c.subscriptions.value)
                      SubscriptionHeader(
                        name: subscriptionDisplayName(source),
                        source: source,
                        count: 0,
                        collapsed: true,
                        onToggle: () => editSource(context, c, source),
                        onDetails: () => editSource(context, c, source),
                        refreshing: c.refreshingSources.value.contains(
                          source['id'],
                        ),
                        refreshError: c.sourceIssue(source),
                        onCancelRefresh: () =>
                            c.cancelRefresh(source['id'].toString()),
                        onRefresh: source['remote'] == true && !c.busy.value
                            ? () => c.refreshSource(source['id'].toString())
                            : null,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
      return LayoutBuilder(
        builder: (context, bounds) {
          final compact =
              bounds.maxWidth < 860 ||
              bounds.maxHeight < 520 ||
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
              SizedBox(width: 312, child: dock),
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
        final knownSources = c.subscriptions.value
            .map((s) => s['id'].toString())
            .toSet();
        final groups =
            <(String, String, List<ServerEntry>, Map<String, dynamic>?)>[
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
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ConnectionSearch(
                      controller: search,
                      onChanged: (value) =>
                          setState(() => query = value.trim().toLowerCase()),
                      onClear: () {
                        search.clear();
                        setState(() => query = '');
                      },
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
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilterChip(
                    label: const Text('Избранные'),
                    avatar: const SvoiIcon(LucideIcons.star, size: 14),
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
              const SizedBox(height: 6),
              Expanded(
                child: filtered.isEmpty && (query.isNotEmpty || favoritesOnly)
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Серверы не найдены',
                              style: TextStyle(color: appColors(context).muted),
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
                          return ListenableBuilder(
                            listenable: Listenable.merge([
                              c.refreshingSources,
                              c.refreshErrors,
                            ]),
                            builder: (context, _) => SubscriptionDropRegion(
                              c: c,
                              sourceId: group.$4?['id']?.toString(),
                              child: SubscriptionHeader(
                                reorderHandle: group.$4 == null
                                    ? null
                                    : SubscriptionDragHandle(
                                        c: c,
                                        source: group.$4!,
                                      ),
                                availabilityNote: c.sourceAvailabilityNote(
                                  group.$4,
                                ),
                                refreshing: c.refreshingSources.value.contains(
                                  group.$4?['id'],
                                ),
                                refreshError: c.sourceIssue(group.$4),
                                onCancelRefresh: () =>
                                    c.cancelRefresh(group.$4!['id'].toString()),
                                name: group.$2,
                                source: group.$4,
                                count: group.$3.length,
                                collapsed:
                                    collapsed.contains(group.$1) &&
                                    query.isEmpty,
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
                                    group.$3.any((s) => s.availableForCore) &&
                                        !c.probing.value &&
                                        c.connection.value['available'] == true
                                    ? () => c.probe(group.$3)
                                    : null,
                                onDetails: group.$4 == null
                                    ? null
                                    : () => editSource(context, c, group.$4!),
                              ),
                            ),
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
                      style: TextStyle(
                        color: appColors(context).muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: c.probing.value
                        ? c.cancelProbes
                        : c.connection.value['available'] == true &&
                              filtered.any((s) => s.availableForCore)
                        ? () => c.probe(filtered)
                        : null,
                    icon: SvoiIcon(
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
                valueListenable: c.refreshProgress,
                builder: (context, value, _) => value.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          value,
                          maxLines: 2,
                          style: TextStyle(
                            color: appColors(context).muted,
                            fontSize: 11,
                          ),
                        ),
                      ),
              ),
              ValueListenableBuilder(
                valueListenable: c.probeProgress,
                builder: (context, value, _) => value.isEmpty
                    ? const SizedBox.shrink()
                    : Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: appColors(context).muted,
                          fontSize: 11,
                        ),
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
          animationDuration: connectionMotion(context),
          color: selected
              ? appColors(context).selected
              : appColors(context).surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected
                  ? appColors(context).accent.withValues(alpha: .5)
                  : Colors.transparent,
            ),
          ),
          child: InkWell(
            key: ValueKey('select-server-${server.id}'),
            borderRadius: BorderRadius.circular(12),
            onTap: c.busy.value || !server.availableForCore
                ? null
                : () => c.selectServer(server.id),
            child: Semantics(
              selected: selected,
              enabled: server.availableForCore,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 0, 4),
                child: Row(
                  children: [
                    AnimatedScale(
                      scale: selected ? 1 : .92,
                      duration: connectionMotion(context),
                      curve: Curves.easeOutCubic,
                      child: CountryMark(country: server.country),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            server.country.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: server.availableForCore
                                  ? appColors(context).ink
                                  : appColors(context).muted,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${server.protocol} · ${active
                                ? 'Подключён'
                                : selected
                                ? 'Выбран'
                                : c.favorites.value.contains(server.id)
                                ? 'Избранный'
                                : server.id == c.lastUsed.value
                                ? 'Последний запуск'
                                : server.country.label}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: active
                                  ? appColors(context).success
                                  : appColors(context).muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 144),
                      child: ServerPingButton(c: c, server: server),
                    ),
                    PopupMenuButton<String>(
                      enabled: server.availableForCore,
                      tooltip: 'Действия сервера',
                      icon: SvoiIcon(
                        LucideIcons.ellipsis,
                        size: 18,
                        color: appColors(context).muted,
                      ),
                      onSelected: (value) {
                        if (value == 'config') {
                          showConfig(context, c, server);
                        } else if (value == 'tcp') {
                          showTCPCheck(context, c, server);
                        } else if (value == 'nodes') {
                          showProfileNodes(context, c, server);
                        } else {
                          c.toggleFavorite(server.id);
                        }
                      },
                      itemBuilder: (context) => [
                        if (server.json['fullProfile'] == true &&
                            server.json['sourceProfileCore'] == null)
                          const PopupMenuItem(
                            value: 'nodes',
                            child: Text('Создать отдельные узлы'),
                          ),
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
      c.foreground,
      c.selected,
      c.servers,
      c.mode,
      c.busy,
      c.connectionPhase,
      c.connectionIssue,
      c.checking,
      c.scenarioApplying,
      c.preferences,
    ]),
    builder: (context, _) {
      final view = ConnectionView(c);
      final server = c.servers.value
          .where((s) => s.id == c.selected.value)
          .firstOrNull;
      final pending = c.pendingConnectionChoice && !view.switching;
      final locked = c.busy.value || view.switching;
      final ready =
          c.connection.value['available'] == true &&
          server?.availableForCore == true;
      final action = view.running ? 'Отключить VPN' : 'Подключить';
      final VoidCallback? toggle = locked || (!view.running && !ready)
          ? null
          : view.running
          ? c.stop
          : c.toggleConnection;
      final active = c.servers.value
          .where((s) => s.id == c.connection.value['serverId'])
          .firstOrNull;
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
                  server == null
                      ? 'Выбранный сервер'
                      : '${server.protocol}${pending ? ' · Для переключения' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: appColors(context).muted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Конфигурация сервера',
            onPressed: server == null
                ? null
                : () => showConfig(context, c, server),
            icon: const SvoiIcon(LucideIcons.fileCode, size: 18),
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (appColors(context).halloween) ...[
                    ExcludeSemantics(
                      child: Image.asset(
                        'assets/themes/pumpkin-power.png',
                        width: 24,
                        height: 24,
                        cacheWidth: 64,
                        cacheHeight: 64,
                      ),
                    ),
                    const SizedBox(width: 7),
                  ],
                  Text(view.switching ? view.title : action),
                ],
              ),
            ),
        ],
      );
      if (compact) {
        return Material(
          color: appColors(context).surface,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(child: selection),
                    const SizedBox(width: 12),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * .48,
                      ),
                      child: controls,
                    ),
                  ],
                ),
                SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => showDiagnostics(context, c),
                        child: ValueListenableBuilder(
                          valueListenable: c.publicIP,
                          builder: (context, ip, _) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              '${view.title}${view.error.isNotEmpty ? ' · нужна проверка' : ''}${ip['ip'] == null ? '' : ' · ${ip['ip']}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: view.error.isNotEmpty
                                    ? appColors(context).accent
                                    : appColors(context).ink,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    ScenarioLauncher(c: c),
                    IconButton(
                      tooltip: 'Режим и правила трафика',
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
                      icon: const SvoiIcon(
                        LucideIcons.slidersHorizontal,
                        size: 17,
                      ),
                    ),
                    TextButton(
                      onPressed: () => showDiagnostics(context, c),
                      child: Text(
                        view.error.isNotEmpty ? 'Что делать' : 'Подробнее',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }

      return ConnectionPreviewPane(
        c: c,
        view: view,
        selection: selection,
        toggle: toggle,
        action: action,
        pending: pending,
        controls: controls,
        activeName:
            active?.country.title ??
            c.connection.value['serverName']?.toString() ??
            'другой сервер',
        server: server,
      );
    },
  );
}
