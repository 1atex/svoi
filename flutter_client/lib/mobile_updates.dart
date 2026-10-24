part of 'main.dart';

class MobileUpdateModel extends ChangeNotifier with WidgetsBindingObserver {
  static const channel = MethodChannel('dev.svoi/updates');
  Map<String, dynamic> data = {};
  bool busy = false;
  bool _closed = false;
  bool _visible = true;
  Timer? _timer;
  String get state => data['state'] as String? ?? 'idle';
  bool get available => data['available'] == true;
  bool get active =>
      const ['checking', 'downloading', 'waiting', 'verifying'].contains(state);

  void start() {
    WidgetsBinding.instance.addObserver(this);
    unawaited(call('check', {'force': false}));
  }

  Future<void> call(String method, [Map<String, dynamic>? args]) async {
    if (_closed || busy) return;
    busy = true;
    notifyListeners();
    try {
      if (method == 'install') {
        await channel.invokeMethod<void>('install');
      }
      final raw = await channel.invokeMethod<String>(
        method == 'install' ? 'status' : method,
        args,
      );
      if (!_closed) {
        data = Map<String, dynamic>.from(jsonDecode(raw ?? '{}') as Map);
      }
    } on PlatformException catch (e) {
      if (!_closed) {
        data = {
          ...data,
          'error': e.message ?? 'Не удалось выполнить обновление',
        };
      }
    } on MissingPluginException {
      if (!_closed) {
        data = {...data, 'error': 'Обновления доступны в Android-сборке'};
      }
    } finally {
      if (!_closed) {
        busy = false;
        notifyListeners();
        _schedule();
      }
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (_visible && active) {
      _timer = Timer(
        const Duration(seconds: 1),
        () => unawaited(call('status')),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    _timer?.cancel();
    if (_visible) unawaited(call('status'));
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class MobileUpdatesPanel extends StatelessWidget {
  const MobileUpdatesPanel({super.key, required this.model});
  final MobileUpdateModel model;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final d = model.data;
      final state = model.state;
      final downloading = state == 'downloading' || state == 'waiting';
      final ready = state == 'ready';
      final size = (d['size'] as num?)?.toDouble() ?? 0;
      final received = (d['downloaded'] as num?)?.toDouble() ?? 0;
      final label = switch (state) {
        'checking' => 'Проверяем новую версию…',
        'current' => 'Установлена последняя доступная версия',
        'available' => 'Доступна версия ${d['version']}',
        'downloading' => 'Скачиваем обновление',
        'waiting' => 'Ожидаем доступную сеть · автозагрузка по Wi-Fi',
        'verifying' => 'Проверяем APK и подпись…',
        'ready' => 'Обновление ${d['version']} готово к установке',
        _ => 'Обновления из GitHub Releases',
      };
      return MobilePanel(
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Обновления SVOI',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Версия ${d['currentVersion'] ?? '…'}',
                style: const TextStyle(color: muted),
              ),
              const SizedBox(height: 16),
              Text(label),
              if (model.active) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: downloading && size > 0
                      ? (received / size).clamp(0, 1)
                      : null,
                ),
                if (downloading && size > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${(received / 1048576).toStringAsFixed(1)} / ${(size / 1048576).toStringAsFixed(1)} МБ',
                    style: const TextStyle(color: muted),
                  ),
                ],
              ],
              if ((d['error'] as String? ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  d['error'] as String,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (ready && d['canInstall'] != true) ...[
                const SizedBox(height: 12),
                const Text(
                  'Разрешите установку из SVOI в настройках Android, затем вернитесь и нажмите «Установить обновление».',
                  style: TextStyle(color: muted),
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (ready)
                    FilledButton.icon(
                      onPressed: model.busy
                          ? null
                          : () => model.call('install'),
                      icon: const Icon(Icons.system_update),
                      label: Text(
                        d['canInstall'] == true
                            ? 'Установить обновление'
                            : 'Разрешить установку',
                      ),
                    )
                  else if (model.available && !model.active)
                    FilledButton.icon(
                      onPressed: model.busy
                          ? null
                          : () => model.call('download'),
                      icon: const Icon(Icons.download),
                      label: const Text('Скачать обновление'),
                    ),
                  if (downloading || ready)
                    TextButton(
                      onPressed: model.busy ? null : () => model.call('cancel'),
                      child: Text(
                        ready ? 'Удалить загрузку' : 'Отменить загрузку',
                      ),
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: model.busy || model.active
                          ? null
                          : () => model.call('check', {'force': true}),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Проверить обновления'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Проверять при запуске'),
                value: d['autoCheck'] != false,
                onChanged: model.busy
                    ? null
                    : (value) => model.call('settings', {
                        'autoCheck': value,
                        'autoDownload': d['autoDownload'] != false,
                      }),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Скачивать автоматически по Wi-Fi'),
                subtitle: const Text('Установка — после вашего подтверждения'),
                value: d['autoDownload'] != false,
                onChanged: model.busy
                    ? null
                    : (value) => model.call('settings', {
                        'autoCheck': d['autoCheck'] != false,
                        'autoDownload': value,
                      }),
              ),
            ],
          ),
        ),
      );
    },
  );
}
