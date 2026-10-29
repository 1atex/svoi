part of 'main.dart';

String clockLabel(DateTime? time) {
  if (time == null) return 'ещё не проверено';
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  final day =
      local.year == now.year && local.month == now.month && local.day == now.day
      ? ''
      : '${two(local.day)}.${two(local.month)} ';
  return '$day${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String modeLabel(String? mode, Map<String, dynamic>? routing) => switch (mode) {
  'tun' => switch (routing?['mode']) {
    'include' => 'Выбранные приложения',
    'exclude' => 'Приложения с исключениями',
    _ => 'Все приложения',
  },
  'system' => 'Системный прокси',
  'local' => 'Ручной прокси',
  _ => 'Не задан',
};

class ConnectionView {
  ConnectionView(this.c);
  final SvoiController c;
  Map<String, dynamic> get state => c.connection.value;
  bool get running => state['state'] == 'running';
  String get phase => c.connectionPhase.value.isNotEmpty
      ? c.connectionPhase.value
      : switch (state['state']) {
          'starting' => 'starting',
          'stopping' => 'stopping',
          _ => c.checking.value ? 'checking' : '',
        };
  bool get switching => phase.isNotEmpty && phase != 'checking';
  String get error => c.connectionIssue.value.isNotEmpty
      ? c.connectionIssue.value
      : state['error']?.toString() ?? '';
  bool get verified =>
      running && state['checked'] == true && error.isEmpty && phase.isEmpty;
  DateTime? get checkedAt =>
      DateTime.tryParse(state['checkedAt']?.toString() ?? '');
  UserFailure get failure => connectionFailure(
    error,
    running: running,
    available: state['available'] == true,
  );
  String get title => switch (phase) {
    'starting' => 'Подключаемся…',
    'switching' => 'Меняем сервер…',
    'scenario' => 'Применяем сценарий…',
    'checking' => 'VPN включён',
    'stopping' => 'Отключаемся…',
    _ =>
      verified
          ? 'Подключено'
          : running
          ? 'VPN включён'
          : error.isNotEmpty
          ? failure.title
          : state['available'] != true
          ? 'Ядро недоступно'
          : 'VPN выключен',
  };
  String get detail => switch (phase) {
    'starting' => 'Запускаем соединение с выбранными настройками.',
    'switching' => 'Готовим новый профиль и переключаем соединение.',
    'scenario' => c.scenarioApplying.value,
    'checking' => 'Соединение запущено. Проверяем интернет; VPN можно отключить или переключить.',
    'stopping' => 'Завершаем соединение и восстанавливаем настройки.',
    _ =>
      verified
          ? 'HTTPS-проверка пройдена · ${clockLabel(checkedAt)}'
          : running
          ? error.isEmpty
                ? 'Ядро работает. Доступ в интернет ещё не проверен.'
                : failure.text
          : error.isNotEmpty
          ? failure.action
          : 'Нажмите на кнопку включения, чтобы подключиться.',
  };
}

class ConnectionPath extends StatelessWidget {
  const ConnectionPath({super.key, required this.view});
  final ConnectionView view;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
    decoration: BoxDecoration(
      color: appColors(context).canvas.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      children: [
        Row(
          children: [
            _step(
              LucideIcons.monitor,
              'Ваш ПК',
              'Клиент открыт',
              appColors(context).muted,
            ),
            _line(context, view.running),
            _step(
              LucideIcons.shield,
              'VPN',
              view.phase == 'stopping'
                  ? 'Завершается…'
                  : view.running
                  ? '${coreLabel(view.state['core'] as String?)} запущен'
                  : 'Не запущен',
              view.running
                  ? appColors(context).accent
                  : appColors(context).muted,
            ),
            _line(context, view.verified),
            _step(
              LucideIcons.globe,
              'Интернет',
              view.verified
                  ? 'HTTPS: ответ'
                  : view.phase == 'checking'
                  ? 'Проверяем…'
                  : view.running && view.error.isNotEmpty
                  ? 'Нет ответа'
                  : 'Не проверен',
              view.verified
                  ? appColors(context).success
                  : view.error.isNotEmpty
                  ? appColors(context).error
                  : appColors(context).muted,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          view.state['mode'] == 'tun' &&
                  (view.state['routing']?['mode'] == 'include' ||
                      view.state['routing']?['mode'] == 'exclude')
              ? 'Проверка из SVOI · маршрут зависит от правил приложений'
              : 'Сквозная проверка · доступность VPN-сервера отдельно не измеряется',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, color: appColors(context).muted),
        ),
      ],
    ),
  );
  Widget _line(BuildContext context, bool active) => Container(
    width: 20,
    height: 1,
    color: active
        ? appColors(context).accent.withValues(alpha: .6)
        : appColors(context).edge,
  );
  Widget _step(IconData icon, String title, String detail, Color color) =>
      Expanded(
        child: Column(
          children: [
            SvoiIcon(icon, size: 20, color: color),
            const SizedBox(height: 7),
            Text(
              title,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: color),
            ),
          ],
        ),
      );
}

Future<void> showDiagnostics(
  BuildContext context,
  SvoiController c,
) => showDialog<void>(
  context: context,
  builder: (dialog) => AlertDialog(
    title: const Text('Диагностика соединения'),
    content: SizedBox(
      width: 540,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          c.connection,
          c.connectionPhase,
          c.connectionIssue,
          c.checking,
          c.scenarioApplying,
        ]),
        builder: (context, _) {
          final view = ConnectionView(c), state = c.connection.value;
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  view.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  view.detail,
                  style: TextStyle(color: appColors(context).muted),
                ),
                PublicIPLine(c: c),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(dialog);
                    showDesktopSheet(
                      context,
                      'Проверить сайт',
                      SiteCheckPanel(c: c),
                    );
                  },
                  icon: const SvoiIcon(LucideIcons.search, size: 16),
                  label: const Text('Проверить сайт'),
                ),
                const SizedBox(height: 18),
                if (view.error.isNotEmpty) ...[
                  SelectableText(
                    view.error,
                    style: TextStyle(
                      color: appColors(context).error,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
                SelectableText(
                  '${coreLabel(state['core'] as String?)}: ${state['version'] ?? 'не найден'}\nАктивный сервер: ${view.running ? state['serverName'] ?? '—' : '—'}\nРежим: ${modeLabel(state['mode'], state['routing'] == null ? null : Map<String, dynamic>.from(state['routing']))}\nПоследняя проверка: ${clockLabel(view.checkedAt)}',
                  style: const TextStyle(fontSize: 12, height: 1.8),
                ),
                if (view.running)
                  SelectableText(
                    'SOCKS5: 127.0.0.1:${state['socksPort']}\nHTTP: 127.0.0.1:${state['httpPort']}',
                    style: const TextStyle(fontSize: 12, height: 1.8),
                  ),
                const SizedBox(height: 12),
                Text(
                  'Проверяется один контрольный адрес. Ошибка сама по себе не определяет причину: это может быть адрес проверки, сервер, DNS или маршрут. В TUN с выбором приложений контрольный запрос следует правилам Windows для процесса SVOI.',
                  style: TextStyle(
                    fontSize: 12,
                    color: appColors(context).muted,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => showLogs(context, c),
        child: const Text('Журнал ядра'),
      ),
      ListenableBuilder(
        listenable: Listenable.merge([c.busy, c.connection, c.checking]),
        builder: (context, _) => TextButton(
          onPressed:
              c.busy.value ||
                  c.checking.value ||
                  c.connection.value['state'] != 'running'
              ? null
              : c.check,
          child: const Text('Повторить проверку'),
        ),
      ),
      TextButton(
        onPressed: () => Navigator.pop(dialog),
        child: const Text('Закрыть'),
      ),
    ],
  ),
);
