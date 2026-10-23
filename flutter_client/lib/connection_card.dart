part of 'main.dart';

Future<void> showServerPicker(
  BuildContext context,
  SvoiController c,
) => showDialog<void>(
  context: context,
  builder: (dialog) => Dialog(
    child: SizedBox(
      width: 860,
      height: MediaQuery.sizeOf(dialog).height * .84,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Выберите сервер',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
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
          Expanded(
            child: ServerPage(c: c, onSelected: () => Navigator.pop(dialog)),
          ),
        ],
      ),
    ),
  ),
);

class ConnectionCard extends StatelessWidget {
  const ConnectionCard({super.key, required this.c});
  final SvoiController c;
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
      final view = ConnectionView(c), state = c.connection.value;
      final selected = c.servers.value
          .where((s) => s.id == c.selected.value)
          .firstOrNull;
      final active = c.servers.value
          .where((s) => s.id == state['serverId'])
          .firstOrNull;
      final pending = c.pendingConnectionChoice;
      final activeName =
          active?.country.title ??
          state['serverName']?.toString() ??
          'Активный сервер';
      final ready = state['available'] == true;
      final hint = c.busy.value
          ? 'Подождите, выполняется операция'
          : view.running
          ? 'Отключить VPN'
          : !ready
          ? 'Ядро Xray недоступно'
          : selected == null
          ? 'Сначала выберите сервер'
          : 'Подключить VPN';
      return Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xff4b402e)),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xff262219), surface, surface],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Eyebrow('ПОДКЛЮЧЕНИЕ'),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    key: const ValueKey('open-server-picker'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => showServerPicker(context, c),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          CountryMark(
                            country:
                                selected?.country ??
                                const ServerCountry(null, ''),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  selected?.country.title ??
                                      'Добавьте подписку',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 19,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  pending
                                      ? 'Выбран для следующего подключения'
                                      : 'Нажмите, чтобы сменить сервер',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            LucideIcons.chevronDown,
                            size: 18,
                            color: muted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Конфигурация сервера',
                  onPressed: selected == null
                      ? null
                      : () => showConfig(context, c, selected),
                  icon: const Icon(LucideIcons.fileCode, size: 19),
                ),
              ],
            ),
            if (pending)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: canvas,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Сейчас: $activeName',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      modeLabel(
                        state['mode'],
                        state['routing'] == null
                            ? null
                            : Map<String, dynamic>.from(state['routing']),
                      ),
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'После применения: ${selected?.country.title ?? 'сервер не выбран'} · ${modeLabel(c.mode.value, Map<String, dynamic>.from(c.preferences.value['routing'] ?? {}))}',
                      style: const TextStyle(fontSize: 12, color: accent),
                    ),
                  ],
                ),
              ),
            Center(
              child: ConnectionOrbit(
                running: view.running,
                verified: view.verified,
                busy: view.phase.isNotEmpty,
                onPressed: c.busy.value
                    ? null
                    : view.running
                    ? c.stop
                    : ready && selected != null
                    ? c.toggleConnection
                    : null,
                hint: hint,
              ),
            ),
            Text(
              view.title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              view.detail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 18),
            ConnectionPath(view: view),
            const SizedBox(height: 20),
            ModePicker(c: c),
            if (pending) ...[
              const SizedBox(height: 16),
              AppButton(
                label: 'Применить выбранный сервер и режим',
                icon: LucideIcons.arrowRight,
                expand: true,
                onPressed: c.busy.value || selected == null || !ready
                    ? null
                    : c.toggleConnection,
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                if (view.running)
                  TextButton.icon(
                    onPressed: c.busy.value ? null : c.check,
                    icon: const Icon(LucideIcons.refreshCw, size: 15),
                    label: Text(
                      view.error.isEmpty
                          ? 'Проверить интернет'
                          : 'Повторить проверку',
                    ),
                  ),
                if (view.error.isNotEmpty)
                  TextButton(
                    onPressed: () => showServerPicker(context, c),
                    child: const Text('Сменить сервер'),
                  ),
                TextButton.icon(
                  onPressed: () => showDiagnostics(context, c),
                  icon: const Icon(LucideIcons.activity, size: 15),
                  label: const Text('Диагностика'),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class QuickServers extends StatelessWidget {
  const QuickServers({super.key, required this.c});
  final SvoiController c;
  @override
  Widget build(BuildContext context) => Panel(
    child: ListenableBuilder(
      listenable: Listenable.merge([
        c.servers,
        c.favorites,
        c.lastUsed,
        c.selected,
      ]),
      builder: (context, _) {
        final servers = c
            .orderedServers(
              c.servers.value.where(
                (s) =>
                    c.favorites.value.contains(s.id) ||
                    s.id == c.lastUsed.value,
              ),
            )
            .take(4)
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Быстрый доступ',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (servers.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Отметьте сервер звёздочкой. Избранные и последний запущенный появятся здесь.',
                  style: TextStyle(fontSize: 12, color: muted, height: 1.5),
                ),
              ),
            for (final s in servers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CountryMark(country: s.country),
                title: Text(
                  s.country.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  s.id == c.lastUsed.value ? 'Последний запуск' : 'Избранный',
                  style: const TextStyle(fontSize: 11, color: muted),
                ),
                trailing: Icon(
                  s.id == c.selected.value
                      ? LucideIcons.check
                      : LucideIcons.chevronRight,
                  size: 17,
                  color: accent,
                ),
                onTap: () => c.select(s.id),
              ),
            const SizedBox(height: 8),
            AppButton(
              label: 'Все серверы',
              icon: LucideIcons.globe,
              expand: true,
              onPressed: () => showServerPicker(context, c),
            ),
          ],
        );
      },
    ),
  );
}
