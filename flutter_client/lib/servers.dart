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
                        hintText: 'Поиск сервера или страны',
                        prefixIcon: const Icon(LucideIcons.search, size: 18),
                        isDense: true,
                        suffixIcon: query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Очистить поиск',
                                icon: const Icon(LucideIcons.x, size: 16),
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
                    avatar: const Icon(LucideIcons.star, size: 14),
                    label: const Text('Избранные'),
                    selected: favoritesOnly,
                    onSelected: (v) => setState(() => favoritesOnly = v),
                  ),
                  Tooltip(
                    message: 'Сначала избранные и последний запуск, затем остальные. Внутри групп — по задержке.',
                    child: FilterChip(
                      avatar: const Icon(LucideIcons.arrowDownUp, size: 14),
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
                      style: const TextStyle(color: muted, fontSize: 11),
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
                    icon: Icon(
                      c.probing.value
                          ? LucideIcons.square
                          : LucideIcons.activity,
                      size: 16,
                    ),
                    label: Text(
                      c.probing.value ? 'Остановить' : 'Проверить пинг',
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
                          style: const TextStyle(color: muted, fontSize: 11),
                        ),
                      ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              LucideIcons.search,
                              size: 28,
                              color: muted,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              c.servers.value.isEmpty
                                  ? 'Добавьте первую подписку'
                                  : 'Нет серверов по этим условиям',
                              style: const TextStyle(color: muted),
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
                  style: const TextStyle(fontSize: 10, color: muted),
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
          color: selected ? raised : surface,
          border: Border.all(
            color: selected
                ? accent.withValues(alpha: .5)
                : edge.withValues(alpha: .6),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            RadioGroup<String>(
              groupValue: c.selected.value,
              onChanged: (id) async {
                if (id != null) {
                  await c.select(id);
                  if (context.mounted) onSelected?.call();
                }
              },
              child: Tooltip(
                message: 'Выбрать сервер',
                child: Radio<String>(value: server.id),
              ),
            ),
            CountryMark(country: server.country),
            const SizedBox(width: 12),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onSelected == null
                    ? () => showConfig(context, c, server)
                    : () async {
                        await c.select(server.id);
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
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Tooltip(
                                message: 'Через этот сервер запущен VPN',
                                child: Icon(
                                  LucideIcons.radio,
                                  color: success,
                                  size: 15,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${active
                            ? 'Активен · '
                            : server.id == c.lastUsed.value
                            ? 'Последний · '
                            : ''}${server.details}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: muted),
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
              icon: Icon(
                c.favorites.value.contains(server.id)
                    ? Icons.star
                    : LucideIcons.star,
                size: 17,
                color: c.favorites.value.contains(server.id) ? accent : muted,
              ),
            ),
            IconButton(
              tooltip: 'Конфигурация сервера',
              onPressed: () => showConfig(context, c, server),
              icon: const Icon(LucideIcons.fileCode, size: 16),
            ),
            ValueListenableBuilder(
              valueListenable: c.probes.putIfAbsent(
                server.id,
                () => ValueNotifier(const ProbeState()),
              ),
              builder: (context, result, _) => Tooltip(
                message:
                    '${result.error ?? 'HTTPS-проверка через профиль'}\n${clockLabel(result.checkedAt)}. Ошибка не запрещает подключение.',
                child: SizedBox(
                  width: 96,
                  child: TextButton(
                    onPressed:
                        result.busy ||
                            c.probing.value ||
                            c.connection.value['available'] != true
                        ? null
                        : () => c.probe([server]),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          result.busy
                              ? 'Проверка…'
                              : result.error != null
                              ? 'Нет ответа'
                              : result.latency != null
                              ? '${result.latency} мс'
                              : 'Пинг',
                          style: TextStyle(
                            fontSize: 12,
                            color: result.error != null
                                ? const Color(0xffffaaa6)
                                : result.latency != null
                                ? success
                                : accent,
                          ),
                        ),
                        if (result.checkedAt != null)
                          Text(
                            clockLabel(result.checkedAt),
                            style: const TextStyle(fontSize: 9, color: muted),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
