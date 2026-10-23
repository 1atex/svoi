part of 'main.dart';

class ZapretPage extends StatefulWidget {
  const ZapretPage({super.key, required this.c});
  final SvoiController c;
  @override
  State<ZapretPage> createState() => _ZapretPageState();
}

class _ZapretPageState extends State<ZapretPage> {
  String? strategy;
  String kind = 'standard';
  int tab = 0;
  bool sweep = false, problemsOnly = false;
  final chosen = <String>{};
  @override
  Widget build(BuildContext context) => FeatureBody(
    children: [
      RemotePanel(
        c: widget.c,
        path: 'zapret',
        builder: (context, z, acting, act) {
          final strategies = List<String>.from(z['strategies'] ?? []);
          final current = strategies.contains(strategy)
              ? strategy
              : strategies.contains(z['strategy'])
              ? z['strategy']?.toString()
              : strategies.firstOrNull;
          final job = Map<String, dynamic>.from(z['job'] ?? {});
          final running = z['running'] == true,
              working = acting || job['busy'] == true;
          final installed = strategies.isNotEmpty;
          final results = (job['results'] as List? ?? [])
              .map((r) => Map<String, dynamic>.from(r))
              .toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      LucideIcons.shield,
                      color: accent,
                      size: 23,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'zapret',
                          style: TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Flowseal · ${z['version']?.toString().isNotEmpty == true ? z['version'] : 'не установлен'}',
                          style: const TextStyle(fontSize: 12, color: muted),
                        ),
                      ],
                    ),
                  ),
                  StatusPill(
                    running
                        ? 'Работает'
                        : installed
                        ? 'Остановлен'
                        : 'Не установлен',
                    active: running,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final entry in [
                    (0, 'Управление', LucideIcons.slidersHorizontal),
                    (1, 'Проверки', LucideIcons.activity),
                    (2, 'Журнал', LucideIcons.scrollText),
                  ])
                    ChoiceChip(
                      showCheckmark: false,
                      selected: tab == entry.$1,
                      avatar: Icon(entry.$3, size: 15),
                      label: Text(entry.$2),
                      onSelected: (_) => setState(() => tab = entry.$1),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              if (job['busy'] == true ||
                  (job['message']?.toString().isNotEmpty == true &&
                      job['state'] != 'idle')) ...[
                _jobStatus(job, acting, act),
                const SizedBox(height: 16),
              ],
              if (z['error']?.toString().isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Text(
                    z['error'],
                    style: const TextStyle(
                      color: Color(0xffffaaa6),
                      fontSize: 12,
                    ),
                  ),
                ),
              if (tab == 0)
                _columns(
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Eyebrow('СТРАТЕГИЯ ОБХОДА'),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          key: ValueKey('strategy-$current'),
                          initialValue: current,
                          isExpanded: true,
                          decoration: const InputDecoration(isDense: true),
                          hint: const Text('Сначала установите zapret'),
                          items: strategies
                              .map(
                                (s) => DropdownMenuItem(
                                  value: s,
                                  child: Text(
                                    s,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: working || running
                              ? null
                              : (v) => setState(() => strategy = v),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          running
                              ? 'Чтобы сменить стратегию, сначала остановите zapret.'
                              : 'Выберите стратегию и запустите. Если сайты недоступны, сравните варианты во вкладке «Проверки».',
                          style: const TextStyle(
                            color: muted,
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 18),
                        AppButton(
                          key: const ValueKey('zapret-power'),
                          label: !installed
                              ? 'Скачать и установить'
                              : running
                              ? 'Остановить zapret'
                              : 'Запустить zapret',
                          icon: !installed
                              ? LucideIcons.download
                              : running
                              ? LucideIcons.square
                              : LucideIcons.play,
                          primary: true,
                          expand: true,
                          onPressed: working
                              ? null
                              : !installed
                              ? () => act('job', {
                                  'kind': 'update',
                                  'sweep': false,
                                  'strategies': [],
                                })
                              : running
                              ? () => act('stop', null)
                              : current == null || z['elevated'] != true
                              ? null
                              : () => act('start', {'strategy': current}),
                        ),
                        if (z['elevated'] != true)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: Text(
                              'Нужны права администратора. В установщике можно включить постоянный запуск с повышением прав.',
                              style: TextStyle(
                                color: accent,
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Установка и обновления',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (installed)
                              TextButton.icon(
                                onPressed: working
                                    ? null
                                    : () => act('job', {
                                        'kind': 'update',
                                        'sweep': false,
                                        'strategies': [],
                                      }),
                                icon: const Icon(
                                  LucideIcons.refreshCw,
                                  size: 15,
                                ),
                                label: const Text('Обновить'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'SVOI скачивает и распаковывает релиз из GitHub Flowseal.',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                        if (z['pendingVersion']?.toString().isNotEmpty == true)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              'Версия ${z['pendingVersion']} готова и применится после остановки.',
                              style: const TextStyle(
                                color: accent,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ListenableBuilder(
                          listenable: Listenable.merge([
                            widget.c.preferences,
                            widget.c.busy,
                          ]),
                          builder: (context, _) => SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              'Обновлять при запуске',
                              style: TextStyle(fontSize: 13),
                            ),
                            value:
                                widget
                                    .c
                                    .preferences
                                    .value['zapretAutoUpdate'] ==
                                true,
                            onChanged: working || widget.c.busy.value
                                ? null
                                : (v) => widget.c.settings({
                                    'zapretAutoUpdate': v,
                                  }),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            icon: const Icon(LucideIcons.folder, size: 15),
                            label: Text(
                              z['managed'] == true
                                  ? 'Использовать свою папку'
                                  : 'Изменить папку zapret',
                            ),
                            onPressed: working || running
                                ? null
                                : () async {
                                    final result = await editFields(
                                      context,
                                      'Папка zapret',
                                      {
                                        'zapretFolder':
                                            'Полный путь к своей папке',
                                      },
                                      widget.c.preferences.value,
                                      hint: 'Оставьте пустым, чтобы использовать версию, скачанную SVOI.',
                                    );
                                    if (result != null) {
                                      await widget.c.settings(result);
                                    }
                                  },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (tab == 1)
                _columns(
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Что проверить',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        RadioGroup<String>(
                          groupValue: kind,
                          onChanged: (v) {
                            if (!working && v != null) setState(() => kind = v);
                          },
                          child: Column(
                            children: [
                              RadioListTile<String>(
                                value: 'standard',
                                enabled: !working,
                                contentPadding: EdgeInsets.zero,
                                title: const Text(
                                  'Доступность сайтов',
                                  style: TextStyle(fontSize: 13),
                                ),
                                subtitle: const Text(
                                  'Ответы сервисов и время запроса',
                                  style: TextStyle(fontSize: 11, color: muted),
                                ),
                              ),
                              RadioListTile<String>(
                                value: 'dpi',
                                enabled: !working,
                                contentPadding: EdgeInsets.zero,
                                title: const Text(
                                  'DPI-checkers · HTTP и TLS',
                                  style: TextStyle(fontSize: 13),
                                ),
                                subtitle: const Text(
                                  'Признаки фильтрации соединений',
                                  style: TextStyle(fontSize: 11, color: muted),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Divider(),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Перебрать стратегии',
                            style: TextStyle(fontSize: 13),
                          ),
                          subtitle: const Text(
                            'Запускает выбранные варианты по очереди',
                            style: TextStyle(color: muted, fontSize: 11),
                          ),
                          value: sweep,
                          onChanged: working
                              ? null
                              : (v) => setState(() => sweep = v),
                        ),
                        if (sweep) ...[
                          Text(
                            'Выбрано ${chosen.intersection(strategies.toSet()).length} из ${strategies.length}',
                            style: const TextStyle(fontSize: 11, color: muted),
                          ),
                          const SizedBox(height: 8),
                          if (strategies.isEmpty)
                            const Text(
                              'Сначала установите zapret во вкладке «Управление».',
                              style: TextStyle(fontSize: 12, color: muted),
                            ),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final s in strategies)
                                FilterChip(
                                  label: Text(s),
                                  selected: chosen.contains(s),
                                  onSelected: working
                                      ? null
                                      : (v) => setState(() {
                                          if (v) {
                                            chosen.add(s);
                                          } else {
                                            chosen.remove(s);
                                          }
                                        }),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                        ],
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            AppButton(
                              label: 'Начать проверку',
                              icon: LucideIcons.activity,
                              primary: true,
                              onPressed:
                                  working ||
                                      (sweep &&
                                          (z['elevated'] != true ||
                                              chosen
                                                  .intersection(
                                                    strategies.toSet(),
                                                  )
                                                  .isEmpty))
                                  ? null
                                  : () => act('job', {
                                      'kind': kind,
                                      'sweep': sweep,
                                      'strategies': sweep
                                          ? chosen
                                                .intersection(
                                                  strategies.toSet(),
                                                )
                                                .toList()
                                          : [],
                                    }),
                            ),
                            AppButton(
                              label: 'Диагностика Windows',
                              icon: LucideIcons.monitor,
                              onPressed: working
                                  ? null
                                  : () => act('job', {
                                      'kind': 'diagnostics',
                                      'sweep': false,
                                      'strategies': [],
                                    }),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Активный VPN влияет на результат. Таймаут сам по себе не доказывает DPI-блокировку.',
                          style: TextStyle(
                            fontSize: 11,
                            color: muted,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _results(results, job),
                ),
              if (tab == 2)
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Журнал zapret',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () => Clipboard.setData(
                              ClipboardData(
                                text: (z['logs'] as List? ?? []).join('\n'),
                              ),
                            ),
                            icon: const Icon(LucideIcons.copy, size: 15),
                            label: const Text('Копировать'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 360,
                        child: SingleChildScrollView(
                          child: SelectableText(
                            (z['logs'] as List? ?? []).isEmpty
                                ? 'Сообщений пока нет.'
                                : (z['logs'] as List).join('\n'),
                            style: const TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 12,
                              color: muted,
                              height: 1.6,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    ],
  );

  Widget _columns(Widget left, Widget right) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth >= 850
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: left),
              const SizedBox(width: 18),
              Expanded(child: right),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [left, const SizedBox(height: 16), right],
          ),
  );

  Widget _jobStatus(Map<String, dynamic> job, bool acting, RemoteAction act) =>
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    job['message']?.toString() ?? 'Подготовка…',
                    style: const TextStyle(fontSize: 12, height: 1.5),
                  ),
                ),
                if (job['busy'] == true)
                  TextButton(
                    onPressed: acting ? null : () => act('cancel', null),
                    child: const Text('Остановить проверку'),
                  ),
              ],
            ),
            if (job['busy'] == true) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(
                value: (job['total'] ?? 0) > 0
                    ? ((job['completed'] ?? 0) / job['total']).clamp(0.0, 1.0)
                    : (job['size'] ?? 0) > 0
                    ? ((job['downloaded'] ?? 0) / job['size']).clamp(0.0, 1.0)
                    : null,
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
              ),
            ],
          ],
        ),
      );

  Widget _results(
    List<Map<String, dynamic>> results,
    Map<String, dynamic> job,
  ) {
    final visible = results
        .where((r) => !problemsOnly || r['state'] != 'ok')
        .toList();
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Результаты',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              if (results.isNotEmpty)
                IconButton(
                  tooltip: 'Сохранить полный отчёт',
                  icon: const Icon(LucideIcons.download, size: 18),
                  onPressed: () => widget.c.action(() async {
                    final report = await widget.c.api.request('zapret');
                    await saveText(
                      'svoi-zapret-report.json',
                      const JsonEncoder.withIndent('  ').convert(report),
                    );
                  }),
                ),
            ],
          ),
          if (results.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 22),
              child: Text(
                'Запустите проверку — здесь появятся ответы и ошибки.',
                style: TextStyle(fontSize: 12, color: muted),
              ),
            ),
          if (results.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${job['successful'] ?? results.where((r) => r['state'] == 'ok').length} успешных из ${job['resultCount'] ?? results.length} · последние ${results.length} в списке',
              style: const TextStyle(fontSize: 11, color: muted),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: FilterChip(
                label: const Text('Только проблемы'),
                selected: problemsOnly,
                onSelected: (v) => setState(() => problemsOnly = v),
              ),
            ),
            const SizedBox(height: 8),
            if (visible.isEmpty)
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'В показанных результатах проблем нет.',
                  style: TextStyle(fontSize: 12, color: success),
                ),
              )
            else
              SizedBox(
                height: (visible.length * 68.0).clamp(68.0, 340.0),
                child: ListView.builder(
                  itemCount: visible.length,
                  itemExtent: 68,
                  itemBuilder: (context, index) {
                    final r = visible[index], ok = r['state'] == 'ok';
                    final title = '${r['target'] ?? ''}'.trim().isNotEmpty
                        ? '${r['target']}'
                        : '${r['check'] ?? 'Проверка'}';
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        ok ? LucideIcons.circleCheck : LucideIcons.circleAlert,
                        color: ok ? success : accent,
                        size: 19,
                      ),
                      title: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      subtitle: Text(
                        '${r['strategy'] ?? ''} ${r['check'] ?? ''} · ${r['detail'] ?? ''}'
                            .trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: muted),
                      ),
                      trailing: Text(
                        ok
                            ? r['millis'] != null
                                  ? '${r['millis']} мс'
                                  : 'OK'
                            : 'Подробнее',
                        style: TextStyle(
                          fontSize: 11,
                          color: ok ? success : accent,
                        ),
                      ),
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (dialog) => AlertDialog(
                          title: Text(title),
                          content: SingleChildScrollView(
                            child: SelectableText(
                              '${r['strategy'] ?? ''}\n${r['check'] ?? ''}\n${r['state'] ?? ''}\n\n${r['detail'] ?? ''}',
                              style: const TextStyle(fontSize: 13, height: 1.6),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialog),
                              child: const Text('Закрыть'),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ],
      ),
    );
  }
}
