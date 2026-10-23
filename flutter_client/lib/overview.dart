part of 'main.dart';

class Overview extends StatelessWidget {
  const Overview({super.key, required this.c, required this.onServers});
  final SvoiController c;
  final VoidCallback onServers;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 870;
      return Stack(
        children: [
          const Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(painter: NetworkBackdrop()),
              ),
            ),
          ),
          SingleChildScrollView(
            padding: EdgeInsets.all(constraints.maxWidth < 640 ? 20 : 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 11, child: _connection(context)),
                      const SizedBox(width: 20),
                      Expanded(flex: 9, child: _side(context)),
                    ],
                  )
                else ...[
                  _connection(context),
                  const SizedBox(height: 18),
                  _side(context),
                ],
                const SizedBox(height: 20),
                const Row(
                  children: [
                    Icon(LucideIcons.flaskConical, size: 14, color: muted),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Prebeta · профили этой версии хранятся отдельно от прежнего SVOI.',
                        style: TextStyle(color: muted, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _connection(BuildContext context) => ConnectionCard(c: c);

  Widget _side(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      QuickServers(c: c),
      const SizedBox(height: 18),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(LucideIcons.layers, color: accent, size: 18),
                const SizedBox(width: 10),
                const Text(
                  'Подписки',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
                const Spacer(),
                ValueListenableBuilder(
                  valueListenable: c.subscriptions,
                  builder: (context, sources, _) => Text(
                    '${sources.length}',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder(
              valueListenable: c.subscriptions,
              builder: (context, sources, _) => sources.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        'Добавьте ссылку или импортируйте конфигурацию из файла.',
                        style: TextStyle(
                          color: muted,
                          fontSize: 12,
                          height: 1.6,
                        ),
                      ),
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 230),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: sources.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (context, index) {
                          final s = sources[index];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            minTileHeight: 72,
                            onTap: () => editSource(context, c, s),
                            title: Text(
                              s['name'],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Text(
                                '${s['count']} серверов · ${s['host'] ?? 'Из файла'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: muted,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            trailing: s['remote'] == true
                                ? ValueListenableBuilder(
                                    valueListenable: c.busy,
                                    builder: (context, busy, _) => IconButton(
                                      tooltip: 'Обновить подписку',
                                      onPressed: busy
                                          ? null
                                          : () => c.refreshSource(s['id']),
                                      icon: const Icon(
                                        LucideIcons.refreshCw,
                                        size: 16,
                                      ),
                                    ),
                                  )
                                : const Icon(
                                    LucideIcons.chevronRight,
                                    color: muted,
                                    size: 16,
                                  ),
                          );
                        },
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            AppButton(
              label: 'Добавить подписку',
              icon: LucideIcons.plus,
              onPressed: () => importDialog(context, c),
              expand: true,
            ),
          ],
        ),
      ),
    ],
  );
}
