part of 'main.dart';

const clientVersion = String.fromEnvironment(
  'SVOI_VERSION',
  defaultValue: '0.6.0-beta.5',
);

class ConfigPane extends StatelessWidget {
  const ConfigPane({
    super.key,
    required this.c,
    required this.name,
    required this.text,
  });
  final SvoiController c;
  final String name, text;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 12,
        children: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Скопировано'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Копировать'),
          ),
          TextButton.icon(
            onPressed: () => c.action(() => saveText(name, text)),
            icon: const Icon(Icons.save_alt, size: 18),
            label: const Text('Сохранить файл'),
          ),
        ],
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 12),
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
          ),
        ),
      ),
    ],
  );
}

Future<void> saveText(String name, String content) async {
  final path = await windowChannel.invokeMethod<String>('saveFile', name);
  if (path != null) await File(path).writeAsString(content, flush: true);
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String text,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 440, child: Text(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    ) ??
    false;

Future<Map<String, String>?> editFields(
  BuildContext context,
  String title,
  Map<String, String> labels,
  Map<String, dynamic> initial, {
  String? hint,
}) {
  final values = {
    for (final key in labels.keys) key: initial[key]?.toString() ?? '',
  };
  return showDialog<Map<String, String>>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hint != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Text(
                    hint,
                    style: TextStyle(color: appColors(context).muted),
                  ),
                ),
              for (final entry in labels.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TextFormField(
                    initialValue: values[entry.key],
                    maxLines: entry.key == 'processes' ? 7 : 1,
                    decoration: InputDecoration(labelText: entry.value),
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: (value) => values[entry.key] = value,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, values),
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
}

class FeatureBody extends StatelessWidget {
  const FeatureBody({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(28),
    children: [
      for (final child in children)
        Padding(padding: const EdgeInsets.only(bottom: 20), child: child),
    ],
  );
}

class Section extends StatelessWidget {
  const Section(this.title, {super.key, required this.children, this.subtitle});
  final String title;
  final String? subtitle;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              subtitle!,
              style: TextStyle(color: appColors(context).muted, height: 1.5),
            ),
          ),
        const SizedBox(height: 18),
        ...children,
      ],
    ),
  );
}

Future<void> editSource(
  BuildContext context,
  SvoiController c,
  Map<String, dynamic> source,
) async {
  await showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(subscriptionDisplayName(source)),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${source['count']} серверов · ${source['remote'] == true ? source['host'] : 'Импорт из файла'}',
              ),
              const SizedBox(height: 12),
              if (source['report'] != null)
                Text('Обновлено: ${source['report']['fetchedAt']}'),
              SubscriptionDetails(source: source),
              for (final warning in source['report']?['warnings'] ?? [])
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    warning.toString(),
                    style: TextStyle(color: appColors(context).accent),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            Navigator.pop(dialog);
            final fields = await editFields(
              context,
              'Настройки подписки',
              {
                'name': 'Название',
                if (source['remote'] == true)
                  'url': 'Новая HTTPS-ссылка (необязательно)',
              },
              {'name': source['name']},
              hint: 'Пустая ссылка сохраняет текущую. Изменения URL применятся после обновления подписки.',
            );
            if (fields == null) return;
            await c.mutateGroup(
              'subscriptions/${Uri.encodeComponent(source['id'])}',
              body: fields,
            );
            if (c.message.value.isEmpty &&
                (fields['url']?.isNotEmpty ?? false)) {
              await c.refreshSource(source['id']);
            }
          },
          child: const Text('Изменить'),
        ),
        if (source['remote'] == true)
          TextButton(
            onPressed: () async {
              await c.action(() async {
                final exported = await c.api.request(
                  'subscription/export?id=${Uri.encodeComponent(source['id'])}',
                );
                await saveText(
                  'svoi-subscription.txt',
                  exported['text'] ?? jsonEncode(exported),
                );
              });
            },
            child: const Text('Сохранить'),
          ),
        TextButton(
          onPressed: () async {
            Navigator.pop(dialog);
            if (!await confirmAction(
              context,
              'Удалить подписку?',
              '«${source['name']}» и ${source['count']} серверов будут удалены из списка. Активное соединение сохранится до отключения.',
            )) {
              return;
            }
            await c.mutateGroup(
              'subscriptions/${Uri.encodeComponent(source['id'])}',
              method: 'DELETE',
            );
          },
          child: Text(
            'Удалить',
            style: TextStyle(color: appColors(context).error),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
}

Future<void> receivePreview(
  BuildContext context,
  SvoiController c,
  String code,
) async {
  try {
    final data = await c.api.request(
      'transfer/preview',
      method: 'POST',
      body: {'code': code},
    );
    if (!context.mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Получить «${data['name']}»'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Источников: ${(data['sources'] as List).length}. Серверов в файле: ${data['servers']}.',
                ),
                const SizedBox(height: 12),
                for (final source in data['sources'])
                  Text(
                    '• ${source['name']} · ${source['remote'] == true ? 'загрузится с ${source['host']}' : 'из файла'}',
                  ),
                const SizedBox(height: 16),
                const Text(
                  'Будут перенесены параметры профиля и ссылки подписок. Подписки загрузятся на этом ПК. Текущее VPN-соединение будет остановлено.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'replace'),
            child: const Text('Заменить текущий'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'new'),
            child: const Text('Добавить профиль'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'replace' &&
        !await confirmAction(
          context,
          'Заменить текущий профиль?',
          'Параметры запроса и все подписки текущего профиля будут заменены.',
        )) {
      return;
    }
    await c.receiveProfile(code, replace: choice == 'replace');
  } catch (e) {
    c.message.value = e.toString();
  }
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key, required this.c});
  final SvoiController c;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c.group, c.sessions, c.busy]),
    builder: (context, _) {
      final group = c.group.value,
          identity = Map<String, dynamic>.from(group['identity'] ?? {});
      return FeatureBody(
        children: [
          Section(
            'Ваши профили',
            subtitle:
                'Каждый профиль хранит свои подписки и параметры запроса.',
            children: [
              for (final session in c.sessions.value)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    session['token'] == c.api.token
                        ? Icons.check_circle
                        : Icons.account_circle_outlined,
                    color: appColors(context).accent,
                  ),
                  title: Text(session['name']),
                  trailing: session['token'] == c.api.token
                      ? Text(
                          'Активный',
                          style: TextStyle(color: appColors(context).muted),
                        )
                      : null,
                  onTap: c.busy.value || session['token'] == c.api.token
                      ? null
                      : () async {
                          if (c.connection.value['state'] == 'running' &&
                              !await confirmAction(
                                context,
                                'Сменить профиль?',
                                'Текущий VPN будет отключён.',
                              )) {
                            return;
                          }
                          await c.switchProfile(session['token']);
                        },
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: c.busy.value
                        ? null
                        : () async {
                            final fields = await editFields(
                              context,
                              'Новый профиль',
                              {'name': 'Название'},
                              {'name': 'Моя сеть'},
                              hint: 'При создании профиля текущее VPN-соединение отключится.',
                            );
                            if (fields != null) {
                              await c.createProfile(fields['name']!.trim());
                            }
                          },
                    icon: const Icon(Icons.add),
                    label: const Text('Создать'),
                  ),
                  OutlinedButton.icon(
                    onPressed: c.busy.value
                        ? null
                        : () => importDialog(context, c),
                    icon: const Icon(Icons.move_to_inbox_outlined),
                    label: const Text('Получить профиль'),
                  ),
                  FilledButton.icon(
                    onPressed: c.busy.value
                        ? null
                        : () async {
                            await c.action(() async {
                              final result = await c.api.request(
                                'transfer/export',
                                method: 'POST',
                              );
                              if (!context.mounted) return;
                              await showDialog<void>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Поделиться профилем'),
                                  content: SizedBox(
                                    width: 560,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Ссылок подписок: ${result['remoteSources']}. Встроенных серверов: ${result['servers']}.',
                                        ),
                                        const SizedBox(height: 16),
                                        const Text(
                                          'Код содержит доступ к подпискам. Устройства работают независимо: автоматической синхронизации и удалённого отзыва перенесённого кода нет.',
                                        ),
                                        const SizedBox(height: 16),
                                        SizedBox(
                                          height: 110,
                                          child: SingleChildScrollView(
                                            child: SelectableText(
                                              result['code'],
                                              style: const TextStyle(
                                                fontFamily: 'Consolas',
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () async {
                                        await saveText(
                                          'svoi-profile.svoi',
                                          result['code'],
                                        );
                                      },
                                      child: const Text('Сохранить .svoi'),
                                    ),
                                    FilledButton(
                                      onPressed: () async {
                                        await Clipboard.setData(
                                          ClipboardData(text: result['code']),
                                        );
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }
                                      },
                                      child: const Text('Копировать код'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Закрыть'),
                                    ),
                                  ],
                                ),
                              );
                            });
                          },
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Поделиться'),
                  ),
                ],
              ),
            ],
          ),
          Section(
            'Параметры запроса',
            subtitle: 'Используются при загрузке подписок этого профиля.',
            children: [
              for (final entry in {
                'hwid': 'HWID',
                'os': 'ОС',
                'model': 'Устройство',
                'locale': 'Язык',
                'userAgent': 'User-Agent',
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.value,
                        style: TextStyle(
                          color: appColors(context).muted,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(identity[entry.key]?.toString() ?? '—'),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: c.busy.value
                      ? null
                      : () async {
                          final result = await editFields(
                            context,
                            'Параметры запроса',
                            {
                              'hwid': 'HWID',
                              'os': 'ОС',
                              'model': 'Устройство',
                              'locale': 'Язык',
                              'userAgent': 'User-Agent',
                            },
                            identity,
                            hint: 'Печатные ASCII-символы, до 180 в каждом поле. Новые значения применятся при следующем обновлении подписок.',
                          );
                          if (result != null) {
                            await c.mutateGroup(
                              'identity',
                              body: {'identity': result},
                            );
                          }
                        },
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Изменить параметры'),
                ),
              ),
            ],
          ),
          Section(
            'Локальные устройства',
            subtitle: 'Это сеансы локальной группы. Получатели перенесённого кода сюда автоматически не добавляются.',
            children: [
              for (final device in group['devices'] ?? [])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.computer),
                  title: Text(
                    device['name'] == 'Windows · Flutter'
                        ? 'Windows'
                        : device['name'],
                  ),
                  subtitle: Text(device['platform']),
                  trailing: device['owner'] == true
                      ? const Text('Владелец')
                      : IconButton(
                          tooltip: 'Отозвать доступ',
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: c.busy.value
                              ? null
                              : () async {
                                  if (await confirmAction(
                                    context,
                                    'Отозвать доступ?',
                                    'Скачанные ранее конфигурации останутся на устройстве.',
                                  )) {
                                    await c.mutateGroup(
                                      'devices/${Uri.encodeComponent(device['id'])}',
                                      method: 'DELETE',
                                    );
                                  }
                                },
                        ),
                ),
            ],
          ),
        ],
      );
    },
  );
}

class RoutingPage extends StatelessWidget {
  const RoutingPage({super.key, required this.c});
  final SvoiController c;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c.preferences, c.busy]),
    builder: (context, _) {
      final routing = Map<String, dynamic>.from(
        c.preferences.value['routing'] ?? {'mode': 'all', 'processes': []},
      );
      final processes = List<String>.from(routing['processes'] ?? []);
      return FeatureBody(
        children: [
          Section(
            'Трафик приложений',
            subtitle: 'Работает в режиме TUN. Изменения применятся после переподключения VPN.',
            children: [
              for (final entry in {
                'all': 'Все приложения',
                'include': 'Только выбранные',
                'exclude': 'Все, кроме выбранных',
              }.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    routing['mode'] == entry.key
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: appColors(context).accent,
                  ),
                  title: Text(entry.value),
                  onTap: c.busy.value
                      ? null
                      : () async {
                          if (entry.key != 'all' && processes.isEmpty) {
                            c.message.value =
                                'Сначала добавьте хотя бы одно приложение.';
                            return;
                          }
                          await c.settings({
                            'routing': {...routing, 'mode': entry.key},
                          });
                        },
                ),
              const Divider(),
              const SizedBox(height: 12),
              for (final process in processes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.apps),
                  title: Text(process),
                  trailing: IconButton(
                    tooltip: 'Убрать из списка',
                    icon: const Icon(Icons.close),
                    onPressed: c.busy.value
                        ? null
                        : () {
                            final next = processes
                                .where((p) => p != process)
                                .toList();
                            c.settings({
                              'routing': {
                                'mode': next.isEmpty ? 'all' : routing['mode'],
                                'processes': next,
                              },
                            });
                          },
                  ),
                ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: c.busy.value
                        ? null
                        : () => c.action(() async {
                            final path = await windowChannel
                                .invokeMethod<String>('openExe');
                            if (path != null) {
                              c.preferences.value = await c.api.request(
                                'settings',
                                method: 'PUT',
                                body: {
                                  ...c.preferences.value,
                                  'routing': {
                                    ...routing,
                                    'processes': {...processes, path}.toList(),
                                  },
                                },
                              );
                            }
                          }),
                    icon: const Icon(Icons.add),
                    label: const Text('Выбрать EXE'),
                  ),
                  OutlinedButton(
                    onPressed: c.busy.value
                        ? null
                        : () async {
                            final result = await editFields(
                              context,
                              'Список приложений',
                              {
                                'processes': 'Имя EXE или полный путь, по одному на строку',
                              },
                              {'processes': processes.join('\n')},
                            );
                            if (result == null) return;
                            final list = result['processes']!
                                .split('\n')
                                .map((s) => s.trim())
                                .where((s) => s.isNotEmpty)
                                .toList();
                            await c.settings({
                              'routing': {
                                'mode': list.isEmpty ? 'all' : routing['mode'],
                                'processes': list,
                              },
                            });
                          },
                    child: const Text('Ввести вручную'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Дочерние процессы приложения могут иметь другие имена. Добавьте их отдельно, если часть трафика идёт вне выбранного правила.',
                style: TextStyle(color: appColors(context).muted, height: 1.5),
              ),
            ],
          ),
        ],
      );
    },
  );
}

typedef RemoteAction = Future<void> Function(String action, Object? body);

class RemotePanel extends StatefulWidget {
  const RemotePanel({
    super.key,
    required this.c,
    required this.path,
    required this.builder,
  });
  final SvoiController c;
  final String path;
  final Widget Function(BuildContext, Map<String, dynamic>, bool, RemoteAction)
  builder;
  @override
  State<RemotePanel> createState() => _RemotePanelState();
}

class _RemotePanelState extends State<RemotePanel> {
  Map<String, dynamic> data = {};
  bool loading = false, acting = false;
  String error = '';
  Timer? timer;
  @override
  void initState() {
    super.initState();
    widget.c.foreground.addListener(visibilityChanged);
    unawaited(refresh());
  }

  void visibilityChanged() {
    timer?.cancel();
    if (widget.c.visible) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (loading || !mounted) return;
    loading = true;
    try {
      if (widget.c.visible) {
        final result = await widget.c.api.request(
          widget.path == 'zapret'
              ? 'zapret?summary=1${data['resultsRevision'] != null ? '&since=${data['resultsRevision']}' : ''}'
              : widget.path,
        );
        final sameResults = result.remove('resultsUnchanged') == true;
        final previous = sameResults
            ? {
                ...data,
                'job': {
                  ...Map<String, dynamic>.from(data['job'] ?? {}),
                  'results': [],
                },
              }
            : data;
        final changed = jsonEncode(previous) != jsonEncode(result);
        if (widget.path == 'zapret' && sameResults) {
          result['job']['results'] = data['job']?['results'] ?? [];
        }
        if (mounted && (changed || error.isNotEmpty)) {
          setState(() {
            data = result;
            error = '';
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      loading = false;
      timer?.cancel();
      if (mounted && widget.c.visible) {
        timer = Timer(
          Duration(
            seconds:
                data['job']?['busy'] == true ||
                    ['checking', 'downloading'].contains(data['state'])
                ? 2
                : 10,
          ),
          refresh,
        );
      }
    }
  }

  Future<void> act(String action, Object? body) async {
    if (acting) return;
    setState(() => acting = true);
    try {
      await widget.c.api.request(
        '${widget.path}/$action',
        method: 'POST',
        body: body,
      );
      if (widget.path == 'updates' && action == 'install') {
        await widget.c.close();
        await windowChannel.invokeMethod('close');
        return;
      }
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => acting = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.c.foreground.removeListener(visibilityChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(error, style: TextStyle(color: appColors(context).error)),
        ),
      if (data.isEmpty)
        error.isEmpty
            ? const LinearProgressIndicator()
            : OutlinedButton(onPressed: refresh, child: const Text('Повторить'))
      else
        widget.builder(context, data, acting, act),
    ],
  );
}

class PreferencesPage extends StatelessWidget {
  const PreferencesPage({super.key, required this.c});
  final SvoiController c;
  @override
  Widget build(BuildContext context) => Platform.isLinux
      ? LinuxPreferences(c: c)
      : Platform.isMacOS
      ? MacOSPreferences(c: c)
      : FeatureBody(
          children: [
            const AppearancePanel(),
            Section(
              'Сценарии',
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => showDesktopSheet(
                      context,
                      'Сценарии',
                      ScenarioManager(c: c),
                    ),
                    icon: const Icon(LucideIcons.layers, size: 16),
                    label: const Text('Управлять сценариями'),
                  ),
                ),
              ],
            ),
            ProbeSettingsPanel(c: c),
            Section(
              'Автоматизация',
              children: [
                StartupPanel(c: c),
                const Divider(height: 28),
                ListenableBuilder(
                  listenable: Listenable.merge([c.preferences, c.busy]),
                  builder: (context, _) => Column(
                    children: [
                      for (final entry in {
                        'autoRefresh': 'Обновлять при запуске',
                        'autoUpdate': 'Проверять обновления приложения',
                        'autoDownload': 'Скачивать обновления автоматически',
                        'autoPauseZapret':
                            'Переключать zapret и VPN автоматически',
                      }.entries)
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(entry.value),
                          subtitle: entry.key == 'autoRefresh'
                              ? const Text('Подписки загрузятся в фоне.')
                              : entry.key == 'autoPauseZapret'
                              ? const Text(
                                  'Приостанавливать zapret из SVOI перед TUN и возвращать после отключения VPN.',
                                )
                              : null,
                          value: c.preferences.value[entry.key] == true,
                          onChanged: c.busy.value
                              ? null
                              : (value) => c.settings({entry.key: value}),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                ListenableBuilder(
                  listenable: Listenable.merge([
                    c.refreshingSources,
                    c.refreshProgress,
                  ]),
                  builder: (context, _) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OutlinedButton.icon(
                        onPressed: c.refreshingSources.value.isEmpty
                            ? c.refreshSubscriptions
                            : null,
                        icon: const Icon(Icons.refresh),
                        label: Text(
                          c.refreshingSources.value.isEmpty
                              ? 'Обновить подписки сейчас'
                              : 'Подписки обновляются…',
                        ),
                      ),
                      if (c.refreshProgress.value.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            c.refreshProgress.value,
                            style: TextStyle(
                              color: appColors(context).muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            Section(
              'Обновления SVOI',
              subtitle:
                  'Версия $clientVersion. Проверка и загрузка выполняются в приложении.',
              children: [
                RemotePanel(
                  c: c,
                  path: 'updates',
                  builder: (context, u, acting, act) {
                    final state = u['state'];
                    final working =
                        acting ||
                        [
                          'checking',
                          'downloading',
                          'installing',
                        ].contains(state);
                    final labels = {
                      'idle': 'Проверка ещё не выполнялась',
                      'checking': 'Проверяем релизы…',
                      'current': 'Установлена актуальная версия',
                      'available': 'Доступна ${u['version']}',
                      'downloading': 'Загружаем ${u['version']}',
                      'ready': '${u['version']} скачана и проверена',
                      'installing': 'Запускаем установщик…',
                      'error': 'Не удалось обновить приложение',
                    };
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          labels[state] ?? state ?? '',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (state == 'downloading')
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: LinearProgressIndicator(
                              value: (u['size'] ?? 0) > 0
                                  ? (u['downloaded'] ?? 0) / u['size']
                                  : null,
                            ),
                          ),
                        if (u['error']?.toString().isNotEmpty == true)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              u['error'],
                              style: TextStyle(color: appColors(context).error),
                            ),
                          ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            OutlinedButton(
                              onPressed: working
                                  ? null
                                  : () => act('check', null),
                              child: const Text('Проверить обновления'),
                            ),
                            if (state == 'available')
                              FilledButton(
                                onPressed: working
                                    ? null
                                    : () => act('download', null),
                                child: const Text('Скачать'),
                              ),
                            if (state == 'ready')
                              FilledButton(
                                onPressed: working
                                    ? null
                                    : () async {
                                        if (await confirmAction(
                                          context,
                                          'Установить обновление?',
                                          'VPN и zapret будут остановлены. Приложение закроется и откроет установщик новой версии.',
                                        )) {
                                          await act('install', null);
                                        }
                                      },
                                child: const Text('Установить и перезапустить'),
                              ),
                          ],
                        ),
                        if (u['notes']?.toString().isNotEmpty == true)
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text('Что нового'),
                            children: [SelectableText(u['notes'])],
                          ),
                        const SizedBox(height: 12),
                        Text(
                          'Установка начинается по вашей команде; скачанный файл проверяется по SHA-256.',
                          style: TextStyle(
                            color: appColors(context).muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
            Section(
              'Сетевые инструменты',
              children: [
                Text(
                  'Сравните текущий DNS с альтернативами и сохраните возможность вернуть прежние настройки.',
                  style: TextStyle(
                    color: appColors(context).muted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => showDesktopSheet(
                      context,
                      'Сетевые инструменты',
                      DnsTools(c: c),
                    ),
                    icon: const Icon(Icons.dns_outlined),
                    label: const Text('Подобрать DNS'),
                  ),
                ),
              ],
            ),
            Section(
              'SVOI',
              subtitle: 'На связи со своими.',
              children: [
                Text(
                  'SVOI · Xray Core',
                  style: TextStyle(color: appColors(context).muted),
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder(
                  valueListenable: c.connection,
                  builder: (context, status, _) =>
                      Text(status['version']?.toString() ?? ''),
                ),
                const SizedBox(height: 16),
                Text(
                  'Данные приложения находятся в %APPDATA%\\SVOI. Подписки и настройки сохраняются при обновлении.',
                  style: TextStyle(
                    color: appColors(context).muted,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ],
        );
}
