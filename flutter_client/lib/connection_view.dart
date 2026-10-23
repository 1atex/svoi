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
  String get phase => c.connectionPhase.value;
  String get error => c.connectionIssue.value.isNotEmpty
      ? c.connectionIssue.value
      : state['error']?.toString() ?? '';
  bool get verified =>
      running && state['checked'] == true && error.isEmpty && phase.isEmpty;
  DateTime? get checkedAt =>
      DateTime.tryParse(state['checkedAt']?.toString() ?? '');
  String get title => switch (phase) {
    'starting' => 'Подключаемся…',
    'checking' => 'Проверяем интернет…',
    'stopping' => 'Отключаемся…',
    _ =>
      verified
          ? 'Подключено'
          : running
          ? 'VPN включён'
          : error.isNotEmpty
          ? 'Не удалось подключиться'
          : state['available'] != true
          ? 'Ядро недоступно'
          : 'VPN выключен',
  };
  String get detail => switch (phase) {
    'starting' => 'Запускаем соединение с выбранными настройками.',
    'checking' => 'Ожидаем ответ контрольного HTTPS-адреса.',
    'stopping' => 'Завершаем соединение и восстанавливаем настройки.',
    _ =>
      verified
          ? 'HTTPS-проверка пройдена · ${clockLabel(checkedAt)}'
          : running
          ? error.isEmpty
                ? 'Ядро работает. Доступ в интернет ещё не проверен.'
                : 'Интернет не подтверждён: контрольный адрес не ответил. VPN остаётся включён — кнопка питания отключит его.'
          : error.isNotEmpty
          ? 'Откройте диагностику, чтобы посмотреть причину.'
          : 'Нажмите на кнопку питания, чтобы подключиться.',
  };
}

class ConnectionPath extends StatelessWidget {
  const ConnectionPath({super.key, required this.view});
  final ConnectionView view;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
    decoration: BoxDecoration(
      color: canvas.withValues(alpha: .6),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      children: [
        Row(
          children: [
            _step(LucideIcons.monitor, 'Ваш ПК', 'Клиент открыт', muted),
            _line(view.running),
            _step(
              LucideIcons.shield,
              'VPN',
              view.running ? 'Xray запущен' : 'Не запущен',
              view.running ? accent : muted,
            ),
            _line(view.verified),
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
                  ? success
                  : view.error.isNotEmpty
                  ? const Color(0xffffaaa6)
                  : muted,
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
          style: const TextStyle(fontSize: 10, color: muted),
        ),
      ],
    ),
  );
  Widget _line(bool active) => Container(
    width: 20,
    height: 1,
    color: active ? accent.withValues(alpha: .6) : edge,
  );
  Widget _step(IconData icon, String title, String detail, Color color) =>
      Expanded(
        child: Column(
          children: [
            Icon(icon, size: 20, color: color),
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
                Text(view.detail, style: const TextStyle(color: muted)),
                const SizedBox(height: 18),
                if (view.error.isNotEmpty) ...[
                  SelectableText(
                    view.error,
                    style: const TextStyle(
                      color: Color(0xffffaaa6),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
                SelectableText(
                  'Xray: ${state['version'] ?? 'не найден'}\nАктивный сервер: ${view.running ? state['serverName'] ?? '—' : '—'}\nРежим: ${modeLabel(state['mode'], state['routing'] == null ? null : Map<String, dynamic>.from(state['routing']))}\nПоследняя проверка: ${clockLabel(view.checkedAt)}',
                  style: const TextStyle(fontSize: 12, height: 1.8),
                ),
                if (view.running)
                  SelectableText(
                    'SOCKS5: 127.0.0.1:${state['socksPort']}\nHTTP: 127.0.0.1:${state['httpPort']}',
                    style: const TextStyle(fontSize: 12, height: 1.8),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'Проверяется один контрольный адрес. Ошибка сама по себе не определяет причину: это может быть адрес проверки, сервер, DNS или маршрут. В TUN с выбором приложений контрольный запрос следует правилам Windows для процесса SVOI.',
                  style: TextStyle(fontSize: 12, color: muted, height: 1.5),
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
        child: const Text('Журнал Xray'),
      ),
      ListenableBuilder(
        listenable: Listenable.merge([c.busy, c.connection]),
        builder: (context, _) => TextButton(
          onPressed: c.busy.value || c.connection.value['state'] != 'running'
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
