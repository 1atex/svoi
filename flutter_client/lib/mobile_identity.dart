part of 'main.dart';

class MobileIdentityPage extends StatefulWidget {
  const MobileIdentityPage({super.key, required this.c});
  final SvoiController c;
  @override
  State<MobileIdentityPage> createState() => _MobileIdentityPageState();
}

class _MobileIdentityPageState extends State<MobileIdentityPage> {
  static const labels = {
    'hwid': 'HWID',
    'os': 'ОС',
    'model': 'Устройство',
    'locale': 'Язык',
    'userAgent': 'User-Agent',
  };
  final form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> fields;
  late final String profileId;
  late bool sendDevice;
  bool saving = false;
  String error = '';
  @override
  void initState() {
    super.initState();
    final identity = widget.c.group.value['identity'] as Map? ?? {};
    profileId = widget.c.group.value['id'].toString();
    sendDevice = identity['omitDeviceHeaders'] != true;
    fields = {
      for (final key in labels.keys)
        key: TextEditingController(text: identity[key]?.toString() ?? ''),
    };
  }

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (saving || widget.c.busy.value || !form.currentState!.validate()) return;
    if (widget.c.group.value['id'].toString() != profileId) {
      setState(
        () => error = 'Активный профиль изменился. Откройте настройки заново.',
      );
      return;
    }
    setState(() {
      saving = true;
      error = '';
    });
    await widget.c.mutateGroup(
      'identity',
      body: {
        'identity': {
          for (final entry in fields.entries)
            entry.key: entry.value.text.trim(),
          'omitDeviceHeaders': !sendDevice,
        },
      },
    );
    if (!mounted) return;
    setState(() {
      saving = false;
      error = widget.c.message.value;
    });
    if (error.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Сохранено. Параметры применятся при следующем обновлении подписок.',
          ),
        ),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Данные устройства')),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton(
          onPressed: saving ? null : save,
          child: Text(saving ? 'Сохраняем…' : 'Сохранить'),
        ),
      ),
    ),
    body: Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Профиль: ${widget.c.group.value['name'] ?? 'Моя сеть'}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Text(
            'Эти параметры используются только при запросе подписок. При переносе профиля сохраняются значения отправителя.',
            style: TextStyle(color: appColors(context).muted),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Отправлять HWID и данные устройства'),
            subtitle: const Text(
              'HWID, ОС, модель и язык. User-Agent отправляется отдельно.',
            ),
            value: sendDevice,
            onChanged: saving ? null : (v) => setState(() => sendDevice = v),
          ),
          if (!sendDevice)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Провайдер может отказать в загрузке подписки без данных устройства. Сохранённые серверы останутся доступны.',
                style: TextStyle(color: appColors(context).accent),
              ),
            ),
          const SizedBox(height: 16),
          for (final entry in labels.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: TextFormField(
                controller: fields[entry.key],
                enabled: !saving,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(labelText: entry.value),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return 'Введите ${entry.value}';
                  if (text.length > 180) return 'Не более 180 символов';
                  if (text.runes.any((r) => r < 32 || r > 126)) {
                    return 'Используйте латиницу, цифры и знаки ASCII';
                  }
                  return null;
                },
              ),
            ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
  );
}

class MobileProbeButton extends StatelessWidget {
  const MobileProbeButton({super.key, required this.c, required this.server});
  final SvoiController c;
  final ServerEntry server;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ProbeState>(
    valueListenable: c.probes[server.id]!,
    builder: (context, result, _) => Tooltip(
      message:
          'Проверить пинг · HTTP GET через профиль, не ICMP\n${result.error ?? 'Доступность тестового адреса'}\n${result.url ?? defaultProbeUrl}\nОшибка не запрещает подключение.',
      child: SizedBox(
        width: 88,
        child: TextButton(
          onPressed:
              result.busy ||
                  c.probing.value ||
                  c.busy.value ||
                  c.connection.value['available'] != true
              ? null
              : () => c.probe([server]),
          child: result.busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : result.error == null && result.latency == null
              ? const SvoiIcon(LucideIcons.activity, size: 22)
              : Text(
                  result.error != null
                      ? result.setupError
                            ? 'Ошибка ядра'
                            : 'Нет ответа'
                      : result.latency != null
                      ? '${result.latency} мс'
                      : 'Пинг',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: result.error != null
                        ? Theme.of(context).colorScheme.error
                        : appColors(context).accent,
                  ),
                ),
        ),
      ),
    ),
  );
}
