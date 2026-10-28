part of 'main.dart';

class Overview extends StatelessWidget {
  const Overview({super.key, required this.c, required this.onServers});
  final SvoiController c;
  final VoidCallback onServers;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c.servers, c.subscriptions]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 870;
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: NetworkBackdrop(color: appColors(context).accent),
                  ),
                ),
              ),
            ),
            SingleChildScrollView(
              padding: EdgeInsets.all(constraints.maxWidth < 640 ? 20 : 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (c.servers.value.isEmpty) ...[
                    ImportWelcome(c: c),
                    if (c.subscriptions.value.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      _side(context),
                    ],
                  ] else ...[
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: onServers,
                          icon: const SvoiIcon(LucideIcons.globe, size: 16),
                          label: Text('Серверы · ${c.servers.value.length}'),
                        ),
                        ValueListenableBuilder(
                          valueListenable: c.busy,
                          builder: (context, busy, _) => AppButton(
                            label: 'Добавить подписку',
                            icon: LucideIcons.plus,
                            onPressed: busy
                                ? null
                                : () => importDialog(context, c),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
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
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      SvoiIcon(
                        LucideIcons.flaskConical,
                        size: 14,
                        color: appColors(context).muted,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Beta · профили этой версии хранятся отдельно от прежнего SVOI.',
                          style: TextStyle(
                            color: appColors(context).muted,
                            fontSize: 11,
                          ),
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
    ),
  );

  Widget _connection(BuildContext context) => ConnectionCard(c: c);

  Widget _side(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (c.servers.value.isNotEmpty) ...[
        QuickServers(c: c),
        const SizedBox(height: 18),
      ],
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SvoiIcon(
                  LucideIcons.layers,
                  color: appColors(context).accent,
                  size: 18,
                ),
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
                    style: TextStyle(
                      color: appColors(context).muted,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder(
              valueListenable: c.subscriptions,
              builder: (context, sources, _) => sources.isEmpty
                  ? Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text(
                        'Добавьте ссылку или импортируйте конфигурацию из файла.',
                        style: TextStyle(
                          color: appColors(context).muted,
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
                                style: TextStyle(
                                  color: appColors(context).muted,
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
                                      icon: const SvoiIcon(
                                        LucideIcons.refreshCw,
                                        size: 16,
                                      ),
                                    ),
                                  )
                                : SvoiIcon(
                                    LucideIcons.chevronRight,
                                    color: appColors(context).muted,
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

class ImportWelcome extends StatefulWidget {
  const ImportWelcome({super.key, required this.c});
  final SvoiController c;
  @override
  State<ImportWelcome> createState() => _ImportWelcomeState();
}

class _ImportWelcomeState extends State<ImportWelcome> {
  final link = TextEditingController();
  final form = GlobalKey<FormState>();

  @override
  void dispose() {
    link.dispose();
    super.dispose();
  }

  Future<void> add() async {
    if (widget.c.busy.value || !form.currentState!.validate()) return;
    await widget.c.importText(
      Uri.parse(link.text.trim()).replace(scheme: 'https').toString(),
    );
  }

  @override
  Widget build(BuildContext context) => Panel(
    child: ValueListenableBuilder(
      valueListenable: widget.c.busy,
      builder: (context, busy, _) => Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Eyebrow('НАЧНЁМ С ВАШЕЙ ПОДПИСКИ'),
            const SizedBox(height: 16),
            Text(
              widget.c.subscriptions.value.isEmpty
                  ? 'Добавьте первое подключение'
                  : 'В подписках пока нет серверов',
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Text(
              'Вставьте ссылку от VPN-провайдера или импортируйте профиль SVOI. Серверы появятся здесь после добавления.',
              style: TextStyle(
                color: appColors(context).muted,
                height: 1.5,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 24),
            TextFormField(
              key: const ValueKey('welcome-link'),
              controller: link,
              enabled: !busy,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Ссылка на подписку',
                hintText: 'https://…',
                suffixIcon: IconButton(
                  tooltip: 'Вставить из буфера',
                  onPressed: busy
                      ? null
                      : () async {
                          final data = await Clipboard.getData(
                            Clipboard.kTextPlain,
                          );
                          if (mounted && data?.text != null) {
                            link.text = data!.text!.trim();
                          }
                        },
                  icon: const SvoiIcon(LucideIcons.clipboardPaste, size: 18),
                ),
              ),
              validator: (value) {
                final uri = Uri.tryParse(value?.trim() ?? '');
                return uri?.scheme == 'https' && uri!.host.isNotEmpty
                    ? null
                    : 'Введите HTTPS-ссылку. Для кода или файла выберите импорт профиля.';
              },
              onFieldSubmitted: (_) => add(),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const ValueKey('welcome-add'),
              onPressed: busy ? null : add,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const SvoiIcon(LucideIcons.plus, size: 18),
              label: Text(busy ? 'Добавляем…' : 'Добавить подписку'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('welcome-import'),
              onPressed: busy ? null : () => importDialog(context, widget.c),
              icon: const SvoiIcon(LucideIcons.fileInput, size: 18),
              label: const Text('Импортировать профиль / файл'),
            ),
            if (widget.c.subscriptions.value.any(
              (s) => s['remote'] == true,
            )) ...[
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: busy ? null : widget.c.refreshSubscriptions,
                icon: const SvoiIcon(LucideIcons.refreshCw, size: 16),
                label: const Text('Обновить существующие подписки'),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Для импорта: код SVOI1, файл .svoi / JSON или ссылка на отдельный сервер.',
              style: TextStyle(
                color: appColors(context).muted,
                fontSize: 11,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
