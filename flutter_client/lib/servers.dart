part of 'main.dart';

class ServerPage extends StatefulWidget {
  const ServerPage({super.key, required this.c, this.onSelected});
  final SvoiController c;
  final VoidCallback? onSelected;
  @override
  State<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  String query = '', sourceFilter = '';
  bool favoritesOnly = false, sortByLatency = false;
  Timer? debounce;
  final search = TextEditingController();
  bool matches(ServerEntry s) =>
      s.search.contains(query) &&
      (!favoritesOnly || widget.c.favorites.value.contains(s.id)) &&
      (sourceFilter.isEmpty ||
          !widget.c.subscriptions.value.any((s) => s['id'] == sourceFilter) ||
          s.json['subscriptionId'] == sourceFilter);
  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: ListenableBuilder(
        listenable: Listenable.merge([
          c.servers,
          c.subscriptions,
          c.favorites,
          c.lastUsed,
          c.probeRevision,
          c.connection,
          c.probing,
        ]),
        builder: (context, _) {
          final filtered = c.orderedServers(
            c.servers.value.where(matches),
            latency: sortByLatency,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: search,
                      decoration: InputDecoration(
                        hintText: 'Поиск сервера, страны или протокола',
                        prefixIcon: const SvoiIcon(
                          LucideIcons.search,
                          size: 18,
                        ),
                        isDense: true,
                        suffixIcon: query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Очистить поиск',
                                icon: const SvoiIcon(LucideIcons.x, size: 16),
                                onPressed: () {
                                  debounce?.cancel();
                                  search.clear();
                                  setState(() => query = '');
                                },
                              ),
                      ),
                      onChanged: (value) {
                        debounce?.cancel();
                        debounce = Timer(
                          const Duration(milliseconds: 120),
                          () => setState(
                            () => query = value.trim().toLowerCase(),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  AppButton(
                    label: 'Добавить',
                    icon: LucideIcons.plus,
                    onPressed: () => importDialog(context, c),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 250,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(
                        'source-$sourceFilter-${c.subscriptions.value.length}',
                      ),
                      initialValue:
                          c.subscriptions.value.any(
                            (s) => s['id'] == sourceFilter,
                          )
                          ? sourceFilter
                          : '',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text(
                            'Все подписки',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                        for (final s in c.subscriptions.value)
                          DropdownMenuItem(
                            value: s['id'].toString(),
                            child: Text(
                              '${s['name']}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => sourceFilter = value ?? ''),
                    ),
                  ),
                  FilterChip(
                    avatar: const SvoiIcon(LucideIcons.star, size: 14),
                    label: const Text('Избранные'),
                    selected: favoritesOnly,
                    onSelected: (v) => setState(() => favoritesOnly = v),
                  ),
                  Tooltip(
                    message: 'Сначала избранные и последний запуск, затем остальные. Внутри групп — по задержке.',
                    child: FilterChip(
                      avatar: const SvoiIcon(LucideIcons.arrowDownUp, size: 14),
                      label: const Text('По задержке'),
                      selected: sortByLatency,
                      onSelected: (v) => setState(() => sortByLatency = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      filtered.length == c.servers.value.length
                          ? '${filtered.length} серверов'
                          : '${filtered.length} из ${c.servers.value.length} серверов',
                      style: TextStyle(
                        color: appColors(context).muted,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed:
                        c.connection.value['available'] != true ||
                            (!c.probing.value && filtered.isEmpty)
                        ? null
                        : () => c.probing.value
                              ? c.cancelProbes()
                              : c.probe(filtered),
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
                valueListenable: c.probeProgress,
                builder: (context, text, _) => text.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: appColors(context).muted,
                            fontSize: 11,
                          ),
                        ),
                      ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SvoiIcon(
                              LucideIcons.search,
                              size: 28,
                              color: appColors(context).muted,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              c.servers.value.isEmpty
                                  ? 'Добавьте первую подписку'
                                  : 'Нет серверов по этим условиям',
                              style: TextStyle(color: appColors(context).muted),
                            ),
                            if (c.servers.value.isNotEmpty)
                              TextButton(
                                onPressed: () {
                                  search.clear();
                                  debounce?.cancel();
                                  setState(() {
                                    query = '';
                                    sourceFilter = '';
                                    favoritesOnly = false;
                                  });
                                },
                                child: const Text('Сбросить фильтры'),
                              ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        key: const PageStorageKey('servers'),
                        itemExtent: 78,
                        itemCount: filtered.length,
                        itemBuilder: (context, index) => ServerRow(
                          key: ValueKey(filtered[index].id),
                          server: filtered[index],
                          c: c,
                          onSelected: widget.onSelected,
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  widget.onSelected == null
                      ? 'Кружок — выбрать · название — конфигурация · «Нет ответа» не запрещает подключение'
                      : 'Нажмите на сервер для выбора · значок документа открывает конфигурацию',
                  style: TextStyle(
                    fontSize: 10,
                    color: appColors(context).muted,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class ServerRow extends StatelessWidget {
  const ServerRow({
    super.key,
    required this.server,
    required this.c,
    this.onSelected,
  });
  final ServerEntry server;
  final SvoiController c;
  final VoidCallback? onSelected;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c.selected, c.connection, c.favorites]),
    builder: (context, _) {
      final selected = c.selected.value == server.id;
      final active =
          c.connection.value['state'] == 'running' &&
          c.connection.value['serverId'] == server.id;
      return Container(
        margin: const EdgeInsets.only(bottom: 5),
        decoration: BoxDecoration(
          color: selected
              ? appColors(context).raised
              : appColors(context).surface,
          border: Border.all(
            color: selected
                ? appColors(context).accent.withValues(alpha: .5)
                : appColors(context).edge.withValues(alpha: .6),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            RadioGroup<String>(
              groupValue: c.selected.value,
              onChanged: (id) async {
                if (id != null) {
                  await c.selectServer(id);
                  if (context.mounted) onSelected?.call();
                }
              },
              child: Tooltip(
                message: 'Выбрать сервер',
                child: Radio<String>(
                  value: server.id,
                  enabled: server.availableForCore,
                ),
              ),
            ),
            CountryMark(country: server.country),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: !server.availableForCore
                    ? null
                    : onSelected == null
                    ? () => showConfig(context, c, server)
                    : () async {
                        await c.selectServer(server.id);
                        if (context.mounted) onSelected?.call();
                      },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              server.country.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (active)
                            Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Tooltip(
                                message: 'Через этот сервер запущен VPN',
                                child: SvoiIcon(
                                  LucideIcons.radio,
                                  color: appColors(context).success,
                                  size: 15,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${server.protocol} · ${active
                            ? 'Активен · '
                            : server.id == c.lastUsed.value
                            ? 'Последний · '
                            : ''}${server.details}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: appColors(context).muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              key: ValueKey('favorite-${server.id}'),
              tooltip: c.favorites.value.contains(server.id)
                  ? 'Убрать из избранного'
                  : 'В избранное',
              onPressed: () => c.toggleFavorite(server.id),
              icon: SvoiIcon(
                c.favorites.value.contains(server.id)
                    ? Icons.star
                    : LucideIcons.star,
                size: 17,
                color: c.favorites.value.contains(server.id)
                    ? appColors(context).accent
                    : appColors(context).muted,
              ),
            ),
            IconButton(
              tooltip: 'Конфигурация сервера',
              onPressed: server.availableForCore
                  ? () => showConfig(context, c, server)
                  : null,
              icon: const SvoiIcon(LucideIcons.fileCode, size: 16),
            ),
            ServerPingButton(c: c, server: server),
          ],
        ),
      );
    },
  );
}

/// HTTP GET latency through the selected proxy profile; this is not ICMP.
class ServerPingButton extends StatelessWidget {
  const ServerPingButton({super.key, required this.c, required this.server});
  final SvoiController c;
  final ServerEntry server;

  @override
  Widget build(BuildContext context) {
    if (!server.availableForCore) {
      return Tooltip(
        message:
            server.json['coreAvailabilityNote']?.toString() ??
            'Выберите другое ядро для этой подписки',
        child: SizedBox(
          width: 44,
          height: 36,
          child: Center(
            child: SvoiIcon(
              LucideIcons.circleMinus,
              size: 16,
              color: appColors(context).muted,
            ),
          ),
        ),
      );
    }
    final probe = c.probes.putIfAbsent(
      server.id,
      () => ValueNotifier(const ProbeState()),
    );
    return ListenableBuilder(
      listenable: Listenable.merge([probe, c.probing, c.connection]),
      builder: (context, _) {
        final result = probe.value;
        final available = c.connection.value['available'] == true;
        final label = result.busy
            ? 'Проверка…'
            : !available
            ? 'Ядро недоступно'
            : result.error != null
            ? 'n/a'
            : result.latency != null
            ? '${result.latency} мс'
            : 'Проверить пинг';
        final color = result.error != null
            ? appColors(context).muted
            : result.latency != null
            ? appColors(context).success
            : appColors(context).accent;
        final routeDescription = server.json['profileNode'] == true
            ? 'HTTP GET через выбранный узел · не ICMP'
            : server.json['fullProfile'] == true
            ? 'Проверка по маршрутам профиля · возможен прямой маршрут'
            : 'HTTP GET через сервер · не ICMP';
        return Tooltip(
          message:
              'Проверить пинг\n$routeDescription\n'
              '${result.error == null ? result.url ?? defaultProbeUrl : '${result.failureLabel}: ${result.error}'}\n'
              '${clockLabel(result.checkedAt)}. Ошибка не запрещает подключение.',
          child: TextButton.icon(
            key: ValueKey('ping-${server.id}'),
            onPressed: !available || result.busy || c.probing.value
                ? null
                : () {
                    if (result.error == null) {
                      c.probe([server]);
                      return;
                    }
                    showDialog<void>(
                      context: context,
                      builder: (dialog) => AlertDialog(
                        title: Text(result.failureLabel),
                        content: Text(result.error!),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialog),
                            child: const Text('Закрыть'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(dialog);
                              c.probe([server]);
                            },
                            child: const Text('Проверить ещё раз'),
                          ),
                        ],
                      ),
                    );
                  },
            icon: result.busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : SvoiIcon(
                    result.error != null
                        ? LucideIcons.refreshCw
                        : LucideIcons.activity,
                    size: 16,
                    color: color,
                  ),
            label: Text(label, style: TextStyle(fontSize: 12, color: color)),
          ),
        );
      },
    );
  }
}
