part of 'controller.dart';

extension ScenarioActions on SvoiController {
  List<Map<String, dynamic>> get currentScenarios =>
      scenarios.value.where((s) => s['groupId'] == group.value['id']).toList();

  Future<void> saveScenario(String name, String kind) => action(() async {
    name = name.trim();
    if (name.isEmpty || name.length > 40) {
      throw ApiException('Название сценария: от 1 до 40 символов.');
    }
    if (currentScenarios.length >= 8) {
      throw ApiException(
        'В одном профиле можно сохранить до восьми сценариев.',
      );
    }
    final scene = <String, dynamic>{
      'id': DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      'name': name,
      'kind': kind,
      'groupId': group.value['id'],
    };
    if (kind == 'vpn') {
      if (selected.value.isEmpty) {
        throw ApiException(
          'Сначала выберите сервер и настройте правила трафика.',
        );
      }
      scene.addAll({
        'serverId': selected.value,
        'serverName':
            servers.value
                .where((s) => s.id == selected.value)
                .firstOrNull
                ?.country
                .title ??
            '',
        'mode': mode.value,
        'routing': jsonDecode(
          jsonEncode(
            preferences.value['routing'] ?? {'mode': 'all', 'processes': []},
          ),
        ),
        'directDomains': List<String>.from(
          preferences.value['directDomains'] ?? [],
        ),
      });
    } else if (kind == 'zapret') {
      final status = await api.request('zapret');
      final strategy = (status['strategy']?.toString().isNotEmpty ?? false)
          ? status['strategy']
          : preferences.value['zapretStrategy'];
      if (strategy == null || strategy.toString().isEmpty) {
        throw ApiException('Сначала выберите стратегию во вкладке zapret.');
      }
      scene.addAll({
        'strategy': strategy,
        'zapretFolder': preferences.value['zapretFolder'] ?? '',
      });
    } else {
      throw ApiException('Неизвестный тип сценария.');
    }
    scenarios.value = [...scenarios.value, scene];
    await saveSession();
  });

  Future<void> deleteScenario(String id) => action(() async {
    scenarios.value = scenarios.value
        .where((s) => s['id'] != id || s['groupId'] != group.value['id'])
        .toList();
    await saveSession();
  });

  Future<void> applyScenario(String id) async {
    final scene = currentScenarios.where((s) => s['id'] == id).firstOrNull;
    if (scene == null || busy.value) return;
    var started = false, applied = false;
    await _connectionAction('scenario', () async {
      scenarioApplying.value = scene['name'].toString();
      cancelProbes();
      try {
        if (scene['kind'] == 'vpn') {
          if (!servers.value.any((s) => s.id == scene['serverId'])) {
            throw ApiException(
              'Сервер сценария удалён из подписки. Выберите новый сервер и сохраните сценарий заново.',
            );
          }
          preferences.value = await api.request(
            'settings',
            method: 'PUT',
            body: {
              ...preferences.value,
              'routing': scene['routing'],
              'directDomains': scene['directDomains'] ?? [],
            },
          );
          selected.value = scene['serverId'];
          mode.value = scene['mode'];
          await saveSession();
          if (connection.value['state'] != 'running' ||
              pendingConnectionChoice) {
            started = await _startSelected();
            applied = started;
          } else {
            applied = true;
          }
        } else if (scene['kind'] == 'zapret') {
          final status = await api.request('zapret');
          if (scene['zapretFolder'] !=
              (preferences.value['zapretFolder'] ?? '')) {
            throw ApiException(
              'Папка zapret изменилась. Сохраните сценарий для текущей установки.',
            );
          }
          if (!(status['strategies'] as List? ?? []).contains(
            scene['strategy'],
          )) {
            throw ApiException(
              'Стратегия zapret больше не найдена. Выберите её заново и пересохраните сценарий.',
            );
          }
          connection.value = await api.request(
            'connection/stop',
            method: 'POST',
          );
          await api.request(
            'zapret/start',
            method: 'POST',
            body: {'strategy': scene['strategy']},
          );
          applied = true;
        }
      } finally {
        scenarioApplying.value = '';
      }
    });
    if (applied && !_closed) lastScenario.value = id;
    if (started && !_closed) unawaited(check());
  }
}
