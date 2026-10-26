part of 'main.dart';

class ProbeSettingsPanel extends StatefulWidget {
  const ProbeSettingsPanel({super.key, required this.c});
  final SvoiController c;

  @override
  State<ProbeSettingsPanel> createState() => _ProbeSettingsPanelState();
}

class _ProbeSettingsPanelState extends State<ProbeSettingsPanel> {
  final form = GlobalKey<FormState>();
  late final TextEditingController url;
  late int timeout, parallel;
  bool saved = false;
  int get maxParallel =>
      widget.c.api.mobile ? widget.c.api.probeConcurrency : 10;

  @override
  void initState() {
    super.initState();
    final prefs = widget.c.preferences.value['probe'] as Map? ?? {};
    url = TextEditingController(
      text: prefs['url'] as String? ?? defaultProbeUrl,
    );
    timeout = ((prefs['timeoutSeconds'] as num?)?.toInt() ?? 4).clamp(1, 15);
    parallel = ((prefs['parallel'] as num?)?.toInt() ?? 4).clamp(
      1,
      maxParallel,
    );
  }

  @override
  void dispose() {
    url.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    final draft = {
      'url': url.text.trim(),
      'timeoutSeconds': timeout,
      'parallel': parallel,
    };
    setState(() => saved = false);
    await widget.c.settings({'probe': draft});
    if (!mounted) return;
    final stored = widget.c.preferences.value['probe'] as Map? ?? {};
    setState(
      () => saved =
          widget.c.message.value.isEmpty &&
          draft.entries.every((entry) => stored[entry.key] == entry.value),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.c.busy, widget.c.probing]),
    builder: (context, _) {
      final locked = widget.c.busy.value || widget.c.probing.value;
      return Section(
        'Проверка задержки',
        subtitle: 'GET-запрос через выбранный профиль. Результат показывает доступность тестового адреса, а не всего интернета или DNS в TUN.',
        children: [
          Form(
            key: form,
            child: TextFormField(
              key: const ValueKey('probe-url'),
              controller: url,
              enabled: !locked,
              autocorrect: false,
              keyboardType: TextInputType.url,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              decoration: const InputDecoration(
                labelText: 'Тестовый URL',
                hintText: 'https://example.org/generate_204',
              ),
              onChanged: (_) => setState(() => saved = false),
              validator: (text) {
                final value = text?.trim() ?? '';
                final uri = Uri.tryParse(value);
                if (value.isEmpty ||
                    value.length > 2048 ||
                    RegExp(r'[\s\\]').hasMatch(value) ||
                    uri == null ||
                    !['http', 'https'].contains(uri.scheme) ||
                    uri.host.isEmpty ||
                    uri.userInfo.isNotEmpty ||
                    uri.hasFragment) {
                  return 'Введите HTTP(S)-адрес без логина, пароля и фрагмента';
                }
                return null;
              },
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in {
                'Gstatic': defaultProbeUrl,
                'HiCloud': 'http://connectivitycheck.platform.hicloud.com/generate_204',
              }.entries)
                TextButton(
                  onPressed: locked
                      ? null
                      : () => setState(() {
                          url.text = preset.value;
                          saved = false;
                        }),
                  child: Text(preset.key),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<int>(
                  key: ValueKey('probe-timeout-$timeout'),
                  initialValue: timeout,
                  decoration: const InputDecoration(labelText: 'Тайм-аут'),
                  items: [
                    for (var i = 1; i <= 15; i++)
                      DropdownMenuItem(value: i, child: Text('$i с')),
                  ],
                  onChanged: locked
                      ? null
                      : (v) => setState(() {
                          timeout = v!;
                          saved = false;
                        }),
                ),
              ),
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<int>(
                  key: ValueKey('probe-parallel-$parallel'),
                  initialValue: parallel,
                  decoration: const InputDecoration(labelText: 'Одновременно'),
                  items: [
                    for (var i = 1; i <= maxParallel; i++)
                      DropdownMenuItem(value: i, child: Text('$i')),
                  ],
                  onChanged: locked
                      ? null
                      : (v) => setState(() {
                          parallel = v!;
                          saved = false;
                        }),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            widget.c.api.mobile
                ? 'Тайм-аут отсчитывается после готовности ядра. На телефоне доступны до $maxParallel одновременных проверок, чтобы снизить нагрузку.'
                : 'Тайм-аут отсчитывается после готовности ядра; подготовка занимает до 5 с. Больше одновременных проверок — выше нагрузка; для большинства ПК достаточно 4. TCP-тест остаётся в меню сервера с лимитом 2 с.',
            style: TextStyle(color: muted, height: 1.5),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(
                onPressed: locked ? null : save,
                child: const Text('Сохранить настройки'),
              ),
              if (widget.c.probing.value)
                const Text(
                  'Дождитесь проверки или остановите её в списке серверов.',
                )
              else if (saved)
                const Text(
                  'Настройки сохранены',
                  style: TextStyle(color: accent),
                ),
            ],
          ),
        ],
      );
    },
  );
}
