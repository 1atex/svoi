import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'countries.dart';

class ServerEntry {
  ServerEntry(this.json)
    : id = json['id'] as String,
      name = json['name'] as String {
    country = ServerCountry.parse(
      name,
      countryCode: json['countryCode'] as String?,
    );
    search =
        '$name ${country.code ?? ''} ${country.label} ${json['address'] ?? ''} ${json['protocol'] ?? ''}'
            .toLowerCase();
  }
  final Map<String, dynamic> json;
  final String id, name;
  late final String search;
  late final ServerCountry country;
  bool get isHysteria =>
      json['protocol'] == 'hysteria' || json['protocol'] == 'hysteria2';
  bool get usesQuic => isHysteria || json['network'] == 'hysteria';
  String get details => json['fullProfile'] == true
      ? '${json['nodeCount']} узлов · маршрутизация из подписки'
      : '${json['address']}:${json['port']} · ${usesQuic ? 'QUIC / UDP' : json['network'] ?? 'tcp'} · ${json['security'] ?? ''}';
  String get protocol => json['fullProfile'] == true
      ? 'Профиль'
      : isHysteria
      ? 'HYSTERIA2'
      : (json['protocol'] as String).toUpperCase();
}

class ProbeState {
  const ProbeState({
    this.busy = false,
    this.latency,
    this.error,
    this.checkedAt,
  });
  final bool busy;
  final int? latency;
  final String? error;
  final DateTime? checkedAt;

  ProbeState withBusy(bool value) => ProbeState(
    busy: value,
    latency: latency,
    error: error,
    checkedAt: checkedAt,
  );
  Map<String, dynamic> toJson() => {
    'latency': latency,
    'error': error,
    'checkedAt': checkedAt?.toIso8601String(),
  };
  static ProbeState fromJson(Map value) => ProbeState(
    latency: value['latency'] as int?,
    error: value['error'] as String?,
    checkedAt: DateTime.tryParse(value['checkedAt']?.toString() ?? ''),
  );
}

class SvoiController {
  SvoiController(this.api, {this.sessionFile});
  final Backend api;
  Future<String> Function()? approveZapretPause;
  final group = ValueNotifier<Map<String, dynamic>>({});
  final sessions = ValueNotifier<List<Map<String, dynamic>>>([]);
  bool get visible => _visible;
  final foreground = ValueNotifier<bool>(true);
  final File? sessionFile;
  final servers = ValueNotifier<List<ServerEntry>>([]);
  final subscriptions = ValueNotifier<List<Map<String, dynamic>>>([]);
  final connection = ValueNotifier<Map<String, dynamic>>({});
  final preferences = ValueNotifier<Map<String, dynamic>>({});
  final selected = ValueNotifier<String>('');
  final mode = ValueNotifier<String>('tun');
  final busy = ValueNotifier<bool>(false);
  final connectionPhase = ValueNotifier<String>('');
  final connectionIssue = ValueNotifier<String>('');
  final favorites = ValueNotifier<Set<String>>({});
  final lastUsed = ValueNotifier<String>('');
  final probeRevision = ValueNotifier<int>(0);
  Map<String, dynamic> _libraries = {};
  final message = ValueNotifier<String>('');
  final probeProgress = ValueNotifier<String>('');
  final probing = ValueNotifier<bool>(false);
  final probes = <String, ValueNotifier<ProbeState>>{};
  final _requests = <RequestCancellation>{};
  Timer? _timer;
  bool _polling = false, _visible = true, _closed = false;
  int _probeGeneration = 0, _connectionRevision = 0;
  Future<void> _saveQueue = Future.value();

  Future<void> initialize() async {
    if (sessionFile != null && await sessionFile!.exists()) {
      final saved =
          jsonDecode(await sessionFile!.readAsString()) as Map<String, dynamic>;
      api.token = saved['token']?.toString() ?? '';
      sessions.value = (saved['sessions'] as List? ?? [])
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
      selected.value = saved['selected']?.toString() ?? '';
      _libraries = Map<String, dynamic>.from(saved['libraries'] ?? {});
      final savedMode = saved['mode'];
      if (['local', 'system', 'tun'].contains(savedMode)) {
        mode.value = savedMode;
      }
    }
    if (api.token.isNotEmpty) {
      try {
        await reload();
      } on ApiException catch (e) {
        if (e.status != 401) rethrow;
        api.token = '';
      }
    }
    if (api.token.isEmpty) {
      final result = await api.request(
        'groups',
        method: 'POST',
        body: {
          'name': 'Моя сеть',
          'deviceName': 'Windows',
          'platform': 'Windows',
        },
      );
      api.token = result['token'];
      _acceptGroup(result['group']);
      await saveSession();
    }
    preferences.value = await api.request('settings');
    await poll();
    if (preferences.value['autoRefresh'] == true) {
      unawaited(refreshSubscriptions());
    }
  }

  void _acceptGroup(Map<String, dynamic> group) {
    if (this.group.value['id'] != group['id']) {
      cancelProbes();
      probes.clear();
      final saved = _libraries[group['id']?.toString()] as Map? ?? {};
      favorites.value = Set<String>.from(saved['favorites'] ?? []);
      lastUsed.value = saved['lastUsed']?.toString() ?? '';
      final history = saved['probes'] as Map? ?? {};
      for (final entry in history.entries) {
        if (entry.value is Map) {
          final result = ProbeState.fromJson(entry.value);
          if (result.checkedAt != null &&
              DateTime.now().difference(result.checkedAt!).inHours < 24) {
            probes[entry.key.toString()] = ValueNotifier(result);
          }
        }
      }
    }
    this.group.value = group;
    if (api.token.isNotEmpty) {
      sessions.value = [
        ...sessions.value.where((s) => s['token'] != api.token),
        {'token': api.token, 'name': group['name'] ?? 'Профиль'},
      ];
    }
    servers.value = (group['servers'] as List? ?? [])
        .map((s) => ServerEntry(Map<String, dynamic>.from(s)))
        .toList(growable: false);
    subscriptions.value = (group['subscriptions'] as List? ?? [])
        .map((s) => Map<String, dynamic>.from(s))
        .toList(growable: false);
    final ids = servers.value.map((s) => s.id).toSet();
    if (!ids.contains(selected.value)) {
      selected.value = servers.value.firstOrNull?.id ?? '';
    }

    if (probes.keys.any((id) => !ids.contains(id))) cancelProbes();
    probes.removeWhere((id, _) => !ids.contains(id));
    for (final id in ids) {
      probes.putIfAbsent(id, () => ValueNotifier(const ProbeState()));
    }
  }

  Future<void> reload() async {
    _acceptGroup(await api.request('me'));
  }

  Future<void> saveSession() {
    if (sessionFile == null) return Future.value();
    final text = jsonEncode({
      'token': api.token,
      'selected': selected.value,
      'mode': mode.value,
      'sessions': sessions.value,
      'libraries': _libraries,
    });
    _saveQueue = _saveQueue.catchError((_) {}).then((_) async {
      final tmp = File('${sessionFile!.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(sessionFile!.path);
    });
    return _saveQueue;
  }

  Future<void> select(String id) async {
    selected.value = id;
    await saveSession();
  }

  Future<void> toggleFavorite(String id) async {
    final next = {...favorites.value};
    if (!next.add(id)) next.remove(id);
    favorites.value = next;
    await _saveLibrary();
  }

  Future<void> _saveLibrary() async {
    _libraries[group.value['id']?.toString() ?? 'default'] = {
      'favorites': favorites.value.toList(),
      'lastUsed': lastUsed.value,
      'probes': {
        for (final entry in probes.entries)
          if (entry.value.value.checkedAt != null)
            entry.key: entry.value.value.toJson(),
      },
    };
    try {
      await saveSession();
    } catch (e) {
      message.value = 'Не удалось сохранить список серверов: $e';
    }
  }

  bool get pendingConnectionChoice {
    final state = connection.value;
    if (state['state'] != 'running') return false;
    if (state['serverId'] != selected.value || state['mode'] != mode.value) {
      return true;
    }
    if (mode.value != 'tun') return false;
    String normalized(dynamic raw) {
      final route = raw as Map? ?? {};
      final apps = List<String>.from(
        route['processes'] ?? [],
      ).map((s) => s.toLowerCase()).toList()..sort();
      return jsonEncode([route['mode'] ?? 'all', apps]);
    }

    return normalized(state['routing']) !=
        normalized(preferences.value['routing']);
  }

  List<ServerEntry> orderedServers(
    Iterable<ServerEntry> source, {
    bool latency = false,
  }) {
    final list = source.toList();
    final positions = {for (var i = 0; i < list.length; i++) list[i].id: i};
    list.sort((a, b) {
      int rank(ServerEntry s) => favorites.value.contains(s.id)
          ? 0
          : s.id == lastUsed.value
          ? 1
          : 2;
      final priority = rank(a).compareTo(rank(b));
      if (priority != 0) return priority;
      if (latency) {
        int ms(ServerEntry s) {
          final result = probes[s.id]?.value;
          return result?.error == null ? result?.latency ?? 1 << 30 : 1 << 30;
        }

        final diff = ms(a).compareTo(ms(b));
        if (diff != 0) return diff;
      }
      return positions[a.id]!.compareTo(positions[b.id]!);
    });
    return list;
  }

  Future<void> setMode(String value) async {
    mode.value = value;
    await saveSession();
  }

  void visibility(bool visible) {
    _visible = visible;
    foreground.value = visible;
    _timer?.cancel();
    if (visible) unawaited(poll());
    if (!visible) _schedule();
  }

  Future<void> poll({bool force = false}) async {
    if (_closed ||
        (!force && !_visible && connection.value['state'] != 'running') ||
        _polling ||
        busy.value) {
      return;
    }
    _polling = true;
    final revision = _connectionRevision;
    try {
      final next = await api.request('connection');
      if (!_closed &&
          !busy.value &&
          revision == _connectionRevision &&
          jsonEncode(next) != jsonEncode(connection.value)) {
        connection.value = next;
      }
    } catch (e) {
      if (!_closed) message.value = e.toString();
    } finally {
      _polling = false;
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!_closed && (_visible || connection.value['state'] == 'running')) {
      _timer = Timer(
        Duration(
          seconds: !_visible
              ? 15
              : connection.value['state'] == 'running'
              ? 3
              : 10,
        ),
        poll,
      );
    }
  }

  Future<void> action(Future<void> Function() task) async {
    if (busy.value || _closed) return;
    busy.value = true;
    _connectionRevision++;
    message.value = '';
    try {
      await task();
    } catch (e) {
      message.value = e.toString();
    } finally {
      busy.value = false;
      await poll();
    }
  }

  Future<void> _connectionAction(String phase, Future<void> Function() task) =>
      action(() async {
        connectionIssue.value = '';
        connectionPhase.value = phase;
        try {
          await task();
        } catch (e) {
          connectionIssue.value = e.toString();
        } finally {
          connectionPhase.value = '';
        }
      });

  Future<void> toggleConnection() => _connectionAction('starting', () async {
    if (connection.value['state'] == 'running' && !pendingConnectionChoice) {
      connectionPhase.value = 'stopping';
      connection.value = await api.request('connection/stop', method: 'POST');
      return;
    }
    if (selected.value.isEmpty) throw ApiException('Выберите сервер.');
    cancelProbes();
    var pauseZapret = false;
    if (mode.value == 'tun') {
      final preflight = await api.request('connection/preflight');
      final conflict = preflight['conflict'];
      if (conflict == 'external') {
        throw ApiException(
          'Обнаружен сторонний zapret. Остановите его через лаунчер или службу, затем повторите подключение.',
        );
      }
      if (conflict == 'busy') {
        throw ApiException(
          'Дождитесь завершения задачи во вкладке zapret или остановите её.',
        );
      }
      if (conflict == 'managed' &&
          preferences.value['autoPauseZapret'] != true) {
        final decision = await approveZapretPause?.call() ?? 'cancel';
        if (decision == 'cancel') return;
        pauseZapret = true;
        if (decision == 'always') {
          preferences.value = await api.request(
            'settings',
            method: 'PUT',
            body: {...preferences.value, 'autoPauseZapret': true},
          );
        }
      }
    }
    connection.value = await api.request(
      'connection/start',
      method: 'POST',
      body: {
        'serverId': selected.value,
        'mode': mode.value,
        'pauseZapret': pauseZapret,
      },
    );
    if (connection.value['state'] != 'running') return;
    lastUsed.value = connection.value['serverId']?.toString() ?? selected.value;
    await _saveLibrary();
    connectionPhase.value = 'checking';

    connection.value = {...connection.value, 'checked': false};
    connection.value = await api.request('connection/check', method: 'POST');
  });
  Future<void> stop() => _connectionAction('stopping', () async {
    connection.value = await api.request('connection/stop', method: 'POST');
  });
  Future<void> check() => _connectionAction('checking', () async {
    connection.value = {...connection.value, 'checked': false};
    connection.value = await api.request('connection/check', method: 'POST');
  });

  Future<void> importText(String raw) => action(() async {
    final text = raw.trim();
    if (text.startsWith('SVOI1.')) {
      final result = await api.request(
        'transfer/import',
        method: 'POST',
        body: {
          'code': text,
          'deviceName': 'Windows',
          'platform': 'Windows',
          'replace': true,
        },
      );
      _acceptGroup(result['group']);
      await _refreshAll();
    } else if (text.startsWith('https://')) {
      final result = await api.request(
        'subscriptions',
        method: 'POST',
        body: {'url': text, 'name': ''},
      );
      _acceptGroup(result['group']);
      await api.request(
        'subscription/refresh?id=${Uri.encodeComponent(result['id'])}',
        method: 'POST',
      );
    } else {
      _acceptGroup(
        await api.request(
          'subscription/import',
          method: 'POST',
          body: {'content': text},
        ),
      );
    }
    await reload();
    await saveSession();
  });

  Future<void> createProfile(String name) => action(() async {
    cancelProbes();
    connection.value = await api.request('connection/stop', method: 'POST');
    final result = await api.request(
      'groups',
      method: 'POST',
      body: {'name': name, 'deviceName': 'Мой ПК', 'platform': 'Windows'},
    );
    api.token = result['token'];
    _acceptGroup(result['group']);
    await saveSession();
  });

  Future<void> switchProfile(String token) => action(() async {
    cancelProbes();
    connection.value = await api.request('connection/stop', method: 'POST');
    final previous = api.token;
    api.token = token;
    try {
      await reload();
    } catch (_) {
      api.token = previous;
      rethrow;
    }
    await saveSession();
    if (preferences.value['autoRefresh'] == true) await _refreshAll();
  });

  Future<void> receiveProfile(String code, {bool replace = false}) =>
      action(() async {
        cancelProbes();
        connection.value = await api.request('connection/stop', method: 'POST');
        final result = await api.request(
          'transfer/import',
          method: 'POST',
          body: {
            'code': code,
            'deviceName': 'Мой ПК',
            'platform': 'Windows',
            'replace': replace,
          },
        );
        if (result['token'] != null) api.token = result['token'];
        _acceptGroup(result['group']);
        await saveSession();
        await _refreshAll();
      });

  Future<void> mutateGroup(
    String path, {
    String method = 'PUT',
    Object? body,
  }) => action(() async {
    _acceptGroup(await api.request(path, method: method, body: body));
    await saveSession();
  });
  Future<void> _refreshAll() async {
    final sources = subscriptions.value
        .where((s) => s['remote'] == true)
        .toList();
    var next = 0;
    final errors = <String>[];
    Future<void> worker() async {
      while (next < sources.length && !_closed) {
        final source = sources[next++];
        try {
          await api.request(
            'subscription/refresh?id=${Uri.encodeComponent(source['id'])}',
            method: 'POST',
          );
        } catch (_) {
          errors.add(source['name'].toString());
        }
      }
    }

    await Future.wait([worker(), worker()]);
    await reload();
    if (errors.isNotEmpty) {
      throw ApiException('Не обновлены: ${errors.join(', ')}');
    }
  }

  Future<void> refreshSubscriptions() => action(_refreshAll);
  Future<void> refreshSource(String id) => action(() async {
    await api.request(
      'subscription/refresh?id=${Uri.encodeComponent(id)}',
      method: 'POST',
    );
    await reload();
  });
  Future<void> settings(Map<String, dynamic> patch) => action(() async {
    preferences.value = await api.request(
      'settings',
      method: 'PUT',
      body: {...preferences.value, ...patch},
    );
  });
  Future<Map<String, dynamic>> config(ServerEntry server) => api.request(
    'servers/${Uri.encodeComponent(server.id)}/config?mode=${mode.value}',
  );
  Future<Map<String, dynamic>> logs() => api.request('connection?logs=1');

  void cancelProbes() {
    final wasProbing = probing.value;
    _probeGeneration++;
    for (final request in _requests) {
      request.cancel();
    }
    _requests.clear();
    for (final value in probes.values) {
      if (value.value.busy) value.value = value.value.withBusy(false);
    }
    probing.value = false;
    if (wasProbing) probeProgress.value = 'Проверка остановлена';
  }

  Future<void> probe(List<ServerEntry> list) async {
    if (probing.value ||
        list.isEmpty ||
        connection.value['available'] != true) {
      return;
    }
    final generation = ++_probeGeneration;
    probing.value = true;
    probeProgress.value = '0 из ${list.length} · до 4 одновременно · лимит 4 с';
    var next = 0, done = 0;
    Future<void> worker() async {
      while (next < list.length && generation == _probeGeneration && !_closed) {
        final server = list[next++], cancellation = RequestCancellation();
        final result = probes.putIfAbsent(
          server.id,
          () => ValueNotifier(const ProbeState()),
        );
        _requests.add(cancellation);
        result.value = result.value.withBusy(true);
        try {
          final response = await api
              .request(
                'servers/${Uri.encodeComponent(server.id)}/probe',
                method: 'POST',
                cancellation: cancellation,
              )
              .timeout(
                const Duration(seconds: 6),
                onTimeout: () {
                  cancellation.cancel();
                  throw ApiException(
                    'Локальный сервис не завершил проверку. Повторите попытку.',
                  );
                },
              );
          if (generation == _probeGeneration) {
            result.value = ProbeState(
              latency: response['latency'],
              checkedAt: DateTime.now(),
            );
          }
        } catch (e) {
          if (generation == _probeGeneration) {
            result.value = ProbeState(
              error: e.toString(),
              checkedAt: DateTime.now(),
            );
          }
        } finally {
          _requests.remove(cancellation);
        }
        if (generation == _probeGeneration) {
          done++;
          probeProgress.value =
              '$done из ${list.length} · HTTPS · до 4 одновременно · лимит 4 с';
        }
      }
    }

    try {
      await Future.wait(
        List.generate(list.length < 4 ? list.length : 4, (_) => worker()),
      );
    } finally {
      if (generation == _probeGeneration) probing.value = false;
      probeRevision.value++;
      await _saveLibrary();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    cancelProbes();
    await _saveQueue.catchError((_) {});
    await api.close();
  }
}
