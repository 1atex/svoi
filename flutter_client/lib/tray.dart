part of 'main.dart';

Map<String, dynamic> trayState(SvoiController c) {
  final view = ConnectionView(c);
  final locked = c.busy.value || view.switching;
  final available = c.connection.value['available'] == true;
  final selected = c.servers.value
      .where((s) => s.id == c.selected.value)
      .firstOrNull;
  final active = c.servers.value
      .where((s) => s.id == c.connection.value['serverId'])
      .firstOrNull;
  String clean(String name) =>
      name.replaceAll(RegExp(r'[\r\n\t]'), ' ').replaceAll('&', '&&');
  Map<String, dynamic> item(
    String id,
    String label, {
    bool enabled = true,
    bool checked = false,
  }) => {
    'id': id,
    'label': clean(label),
    'enabled': enabled,
    'checked': checked,
  };
  const separator = {'separator': true};
  final quick = [
    ?selected,
    ...c.orderedServers(c.servers.value).where((s) => s.id != selected?.id),
  ].take(8);
  return {
    'tooltip':
        'SVOI · ${view.title}${(view.running ? active : selected) == null ? '' : ' · ${(view.running ? active : selected)!.country.title}'}',
    'items': [
      item('open', 'Открыть SVOI'),
      item(
        '',
        '${view.title}${view.running && active != null ? ' · ${active.country.title}' : ''}',
        enabled: false,
      ),
      separator,
      {
        'label': 'Сценарии',
        'enabled': !locked,
        'children': [
          for (final scene in c.currentScenarios)
            item('scenario:${scene['id']}', scene['name'].toString()),
          if (c.currentScenarios.isNotEmpty) separator,
          item('scenarios', 'Управлять сценариями…'),
        ],
      },
      item(
        view.running ? 'disconnect' : 'connect',
        view.running ? 'Отключить VPN' : 'Подключить VPN',
        enabled: !locked && (view.running || available && selected != null),
      ),
      if (c.pendingConnectionChoice)
        item(
          'apply',
          'Применить выбранный сервер и режим',
          enabled: !locked && available && selected != null,
        ),
      {
        'label': view.running
            ? 'Сервер для следующего подключения'
            : 'Выбрать сервер',
        'enabled': !locked && quick.isNotEmpty,
        'children': [
          for (final server in quick)
            item(
              'server:${server.id}',
              '${c.favorites.value.contains(server.id) ? '★ ' : ''}${server.country.title}',
              checked: server.id == c.selected.value,
            ),
          separator,
          item('servers', 'Все серверы…'),
        ],
      },
      {
        'label': 'Режим подключения',
        'enabled': !locked,
        'children': [
          for (final entry in [
            ('tun', 'TUN'),
            ('system', 'Системный прокси'),
            ('local', 'Ручной прокси'),
          ])
            item(
              'mode:${entry.$1}',
              entry.$2,
              checked: c.mode.value == entry.$1,
            ),
        ],
      },
      item(
        'check',
        c.checking.value ? 'Проверяем интернет…' : 'Проверить связь',
        enabled: !locked && view.running && !c.checking.value,
      ),
      separator,
      item(
        'import',
        'Добавить подписку / импортировать профиль…',
        enabled: !locked,
      ),
      item(
        'refresh',
        c.refreshingSources.value.isEmpty
            ? 'Обновить подписки'
            : 'Подписки обновляются…',
        enabled:
            !locked &&
            c.refreshingSources.value.isEmpty &&
            c.subscriptions.value.any((s) => s['remote'] == true),
      ),
      item('logs', 'Журнал Xray…'),
      item('settings', 'Настройки…'),
      separator,
      item('quit', 'Отключить и выйти'),
    ],
  };
}

class TrayBridge {
  TrayBridge(this.c, {required this.open});
  final SvoiController c;
  final Future<void> Function(String action) open;
  late final Listenable changes = Listenable.merge([
    c.connection,
    c.connectionPhase,
    c.connectionIssue,
    c.checking,
    c.refreshingSources,
    c.scenarios,
    c.group,
    c.scenarioApplying,
    c.lastScenario,
    c.selected,
    c.mode,
    c.busy,
    c.servers,
    c.subscriptions,
    c.favorites,
    c.lastUsed,
    c.preferences,
  ]);
  bool _disposed = false, _scheduled = false;
  String _lastState = '';

  void attach() {
    changes.addListener(update);
    update();
  }

  void dispose() {
    _disposed = true;
    changes.removeListener(update);
  }

  void update() {
    if (_disposed || _scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() async {
      _scheduled = false;
      if (_disposed) return;
      final state = trayState(c);
      final encoded = jsonEncode(state);
      if (encoded == _lastState) return;
      try {
        await windowChannel.invokeMethod('updateTray', state);
        _lastState = encoded;
      } on MissingPluginException {
        return;
      } on PlatformException {
        return;
      }
    });
  }

  Future<void> handle(String command) async {
    if (_disposed) return;
    if (['servers', 'settings', 'logs', 'scenarios'].contains(command)) {
      await open(command);
      return;
    }
    if (c.busy.value) return;
    if (command == 'import') {
      await open(command);
      return;
    }
    await c.poll(force: true);
    if (_disposed || c.busy.value) return;
    final running = c.connection.value['state'] == 'running';
    final ready =
        c.connection.value['available'] == true &&
        c.servers.value.any((s) => s.id == c.selected.value);
    if (command.startsWith('scenario:')) {
      await c.applyScenario(command.substring(9));
    } else if (command == 'connect' && !running && ready ||
        command == 'apply' && running && ready && c.pendingConnectionChoice) {
      await c.toggleConnection();
    } else if (command == 'disconnect' && running) {
      await c.stop();
    } else if (command == 'check' && running) {
      await c.check();
    } else if (command == 'refresh' &&
        c.subscriptions.value.any((s) => s['remote'] == true)) {
      await c.refreshSubscriptions();
    } else if (command.startsWith('server:')) {
      final id = command.substring(7);
      if (c.servers.value.any((s) => s.id == id)) {
        await c.action(() => c.select(id));
      }
    } else if (command.startsWith('mode:')) {
      final mode = command.substring(5);
      if (['tun', 'system', 'local'].contains(mode)) {
        await c.action(() => c.setMode(mode));
      }
    }
    if (!_disposed &&
        (c.message.value.isNotEmpty || c.connectionIssue.value.isNotEmpty)) {
      await open('connection');
    }
  }
}
