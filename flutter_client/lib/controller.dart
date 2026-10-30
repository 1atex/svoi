import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'backend.dart';
import 'countries.dart';
import 'user_failure.dart';
part 'scenario_controller.dart';

const defaultProbeUrl = 'https://www.gstatic.com/generate_204';

class ServerEntry {
  ServerEntry(this.json)
    : id = json['id'] as String,
      name = json['name'] as String {
    country = ServerCountry.parse(
      name,
      countryCode: json['countryCode'] as String?,
    );
    search =
        '$name ${country.code ?? ''} ${country.label} ${json['address'] ?? ''} ${json['protocol'] ?? ''} $protocol'
            .toLowerCase();
  }
  final Map<String, dynamic> json;
  final String id, name;
  late final String search;
  late final ServerCountry country;
  bool get availableForCore => json['coreUnavailable'] != true;
  bool get isHysteria =>
      json['protocol'] == 'hysteria' || json['protocol'] == 'hysteria2';
  bool get usesQuic => isHysteria || json['network'] == 'hysteria';
  String get details =>
      json['fullProfile'] == true && json['profileNode'] != true
      ? '${json['nodeCount']} узлов · маршрутизация из подписки${json['sourceProfileCore'] != null ? ' · ${json['sourceProfileCore']}' : ''}'
      : '${json['address']}:${json['port']} · ${usesQuic ? 'QUIC / UDP' : json['network'] ?? 'tcp'} · ${json['security'] ?? ''}';
  static String protocolName(String value) =>
      switch (value.trim().toLowerCase()) {
        'hysteria2' || 'hy2' => 'Hysteria2',
        'hysteria' => 'Hysteria',
        'shadowsocks' || 'ss' => 'Shadowsocks',
        'trojan' => 'Trojan',
        'wireguard' => 'WireGuard',
        '' => 'Протокол не указан',
        final name => name.toUpperCase(),
      };

  String get protocol {
    if (json['fullProfile'] != true || json['profileNode'] == true) {
      return protocolName(json['protocol']?.toString() ?? '');
    }
    final values = json['protocols'];
    final sourceCore = json['sourceProfileCore']?.toString();
    final profileLabel = sourceCore == 'mihomo'
        ? 'профиль Mihomo'
        : sourceCore == 'sing-box'
        ? 'профиль sing-box'
        : 'профиль';
    if (values is! List || values.isEmpty) {
      return sourceCore == null ? 'Профиль Xray' : profileLabel;
    }
    final names = values
        .whereType<String>()
        .map(protocolName)
        .toSet()
        .join(' / ');
    return names.isEmpty ? profileLabel : '$names · $profileLabel';
  }
}

class ProbeState {
  const ProbeState({
    this.busy = false,
    this.latency,
    this.error,
    this.checkedAt,
    this.url,
    this.setupError = false,
    this.failureKind,
  });
  final bool busy;
  final bool setupError;
  final String? failureKind;
  String get failureLabel => switch (failureKind) {
    'unsupported' => 'Несовместимо',
    'timeout' => 'Нет ответа',
    'busy' => 'Проверка занята',
    _ => setupError ? 'Ошибка ядра' : 'Ошибка проверки',
  };
  final int? latency;
  final String? error;
  final String? url;
  final DateTime? checkedAt;

  ProbeState withBusy(bool value) => ProbeState(
    busy: value,
    latency: latency,
    error: error,
    checkedAt: checkedAt,
    url: url,
    setupError: setupError,
    failureKind: failureKind,
  );
  Map<String, dynamic> toJson() => {
    'latency': latency,
    'error': error,
    'checkedAt': checkedAt?.toIso8601String(),
    'url': url,
    'setupError': setupError,
    'failureKind': failureKind,
  };
  static ProbeState fromJson(Map value) => ProbeState(
    latency: value['latency'] as int?,
    error: value['error'] as String?,
    checkedAt: DateTime.tryParse(value['checkedAt']?.toString() ?? ''),
    url: value['url'] as String?,
    setupError: value['setupError'] == true,
    failureKind: value['failureKind'] as String?,
  );
}

class SvoiController {
  SvoiController(this.api, {this.sessionFile}) {
    connection.addListener(_syncPublicIP);
    connection.addListener(_syncCoreLibrary);
    connectionPhase.addListener(_syncPublicIP);
  }
  final Backend api;
  final publicIP = ValueNotifier<Map<String, dynamic>>({});
  String _ipKey = '', _previousIP = '';
  DateTime? _previousIPAt;
  int _ipGeneration = 0;
  RequestCancellation? _ipRequest;
  bool _ipEnabled = false;

  void enablePublicIP() {
    _ipEnabled = true;
    _syncPublicIP();
  }

  void _syncPublicIP() {
    if (_closed || !_ipEnabled || connection.value['state'] == null) return;
    if (connectionPhase.value.isNotEmpty ||
        ['starting', 'stopping'].contains(connection.value['state'])) {
      _ipGeneration++;
      _ipRequest?.cancel();
      _ipKey = '';
      if (publicIP.value.isNotEmpty) publicIP.value = {};
      return;
    }
    final state = connection.value;
    final key = state['state'] == 'running'
        ? '${state['serverId']}/${state['mode']}/${state['startedAt']}'
        : 'network';
    if (key == _ipKey) return;
    _ipKey = key;
    _ipGeneration++;
    _ipRequest?.cancel();
    publicIP.value = {};
    unawaited(refreshPublicIP());
  }

  Future<void> refreshPublicIP() async {
    if (_closed ||
        connectionPhase.value.isNotEmpty ||
        publicIP.value['busy'] == true) {
      return;
    }
    final generation = ++_ipGeneration;
    _ipRequest?.cancel();
    final request = RequestCancellation();
    _ipRequest = request;
    publicIP.value = {'busy': true};
    try {
      final result = await api
          .request('connection/ip', method: 'POST', cancellation: request)
          .timeout(
            const Duration(seconds: 7),
            onTimeout: () {
              request.cancel();
              throw ApiException('Не удалось определить IP');
            },
          );
      if (_closed || generation != _ipGeneration) return;
      final ip = result['ip']?.toString() ?? '';
      if (InternetAddress.tryParse(ip) == null) {
        throw ApiException('Некорректный ответ сервиса IP');
      }
      final previous =
          _previousIPAt != null &&
              DateTime.now().difference(_previousIPAt!).inMinutes < 5
          ? _previousIP
          : '';
      if (result['via'] == 'network') {
        _previousIP = ip;
        _previousIPAt = DateTime.now();
      }
      publicIP.value = {
        ...result,
        if (result['via'] != 'network' && previous.isNotEmpty)
          'previousIP': previous,
      };
    } catch (_) {
      if (!_closed && generation == _ipGeneration) {
        publicIP.value = {'error': 'IP не определён'};
      }
    }
  }

  Future<String> Function()? approveZapretPause;
  final group = ValueNotifier<Map<String, dynamic>>({});
  final sessions = ValueNotifier<List<Map<String, dynamic>>>([]);
  bool get visible => _visible;
  final foreground = ValueNotifier<bool>(true);
  final speedView = ValueNotifier<Map<String, dynamic>>({});
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
  final checking = ValueNotifier<bool>(false);
  final scenarios = ValueNotifier<List<Map<String, dynamic>>>([]);
  final scenarioApplying = ValueNotifier<String>('');
  final lastScenario = ValueNotifier<String>('');
  final refreshingSources = ValueNotifier<Set<String>>({});
  final refreshErrors = ValueNotifier<Map<String, String>>({});
  final refreshProgress = ValueNotifier<String>('');
  final _refreshRequests = <String, RequestCancellation>{};
  final _refreshedErrorVariants = <String>{};
  int _refreshGeneration = 0, _checkGeneration = 0, _reloadRevision = 0;
  RequestCancellation? _checkRequest;
  bool _refreshingAll = false;
  final favorites = ValueNotifier<Set<String>>({});
  final lastUsed = ValueNotifier<String>('');
  final probeRevision = ValueNotifier<int>(0);
  Map<String, dynamic> _libraries = {};
  final _coreSelections = <String, String>{};
  List<String> _subscriptionOrder = [];
  String _libraryCore = 'xray';
  String get activeCore => connection.value['core']?.toString() ?? 'xray';

  void _syncCoreLibrary() {
    if (_closed || activeCore == _libraryCore) return;
    if (selected.value.isNotEmpty) {
      _coreSelections['${group.value['id']}/$_libraryCore'] = selected.value;
    }
    _libraryCore = activeCore;
    cancelProbes();
    for (final probe in probes.values) {
      probe.value = const ProbeState();
    }
    _projectLibrary(restoreSelection: true);
  }

  void _projectLibrary({bool restoreSelection = false}) {
    final sources = (group.value['subscriptions'] as List? ?? [])
        .map((s) => Map<String, dynamic>.from(s))
        .toList();
    final sourceIDs = sources.map((s) => s['id'].toString()).toSet();
    _subscriptionOrder = [
      ..._subscriptionOrder.where(sourceIDs.contains),
      ...sourceIDs.where((id) => !_subscriptionOrder.contains(id)),
    ];
    final sourcePositions = {
      for (var i = 0; i < _subscriptionOrder.length; i++)
        _subscriptionOrder[i]: i,
    };
    sources.sort(
      (a, b) => sourcePositions[a['id']]!.compareTo(sourcePositions[b['id']]!),
    );
    final remoteIDs = sources
        .where((s) => s['remote'] == true)
        .map((s) => s['id'])
        .toSet();
    final all = (group.value['servers'] as List? ?? [])
        .map((s) => ServerEntry(Map<String, dynamic>.from(s)))
        .toList();
    final visible = all.where((s) {
      final scope = s.json['subscriptionCore']?.toString() ?? '';
      if (scope.isNotEmpty) {
        return scope == activeCore;
      }
      final native = s.json['sourceProfileCore']?.toString() ?? '';
      if (native.isNotEmpty) return native == activeCore;
      return activeCore == 'xray' ||
          !remoteIDs.contains(s.json['subscriptionId']);
    }).toList();
    final unavailableSources = <String>{};
    for (final source in sources) {
      final id = source['id'].toString();
      if (visible.any((s) => s.json['subscriptionId'] == id)) continue;
      unavailableSources.add(id);
      final candidates = all
          .where((s) => s.json['subscriptionId'] == id)
          .toList();
      // Keep one complete, stable source representation, never merge nodes
      // across native graphs or pass these display-only rows to the backend.
      final canonicalScope =
          candidates.any((s) => s.json['subscriptionCore'] == 'xray')
          ? 'xray'
          : candidates.any((s) => (s.json['subscriptionCore'] ?? '') == '')
          ? ''
          : candidates.firstOrNull?.json['subscriptionCore'];
      final scoped = candidates
          .where((s) => (s.json['subscriptionCore'] ?? '') == canonicalScope)
          .toList();
      final canonicalNative =
          scoped.any((s) => (s.json['sourceProfileCore'] ?? '') == '')
          ? ''
          : scoped.firstOrNull?.json['sourceProfileCore'];
      for (final row in scoped.where(
        (s) => (s.json['sourceProfileCore'] ?? '') == canonicalNative,
      )) {
        visible.add(
          ServerEntry({
            ...row.json,
            'coreUnavailable': true,
            'coreAvailabilityNote':
                'Для $activeCore нет подходящего варианта подписки.',
          }),
        );
      }
    }
    subscriptions.value = sources
        .map((s) {
          final projected = <String, dynamic>{
            ...s,
            'count': visible
                .where((v) => v.json['subscriptionId'] == s['id'])
                .length,
            'coreUnavailable': unavailableSources.contains(s['id']),
          };
          final note = sourceAvailabilityNote(projected);
          if (note != null) projected['coreAvailabilityNote'] = note;
          return projected;
        })
        .toList(growable: false);
    final available = visible.where((s) => s.availableForCore).toList();
    final ids = available.map((s) => s.id).toSet();
    final remembered = _coreSelections['${group.value['id']}/$activeCore'];
    if (restoreSelection && remembered != null && ids.contains(remembered)) {
      selected.value = remembered;
    } else if (!ids.contains(selected.value)) {
      selected.value = available.firstOrNull?.id ?? '';
    }
    servers.value = visible;
  }

  String? sourceIssue(Map<String, dynamic>? source) {
    if (source == null) return null;
    final requestError = refreshErrors.value[source['id']];
    if (requestError != null &&
        !_refreshedErrorVariants.contains(source['id'])) {
      return requestError;
    }
    final variant = (source['variants'] as Map?)?[activeCore] as Map?;
    if (variant == null || variant['state'] != 'error') return requestError;
    final reason =
        variant['error']?.toString() ?? 'Вариант для $activeCore недоступен.';
    return variant['stale'] == true
        ? '$reason Используется сохранённая копия.'
        : reason;
  }

  String? sourceAvailabilityNote(Map<String, dynamic>? source) {
    if (source == null) return null;
    final variant = (source['variants'] as Map?)?[activeCore] as Map?;
    if (source['coreUnavailable'] == true) {
      if (variant == null && source['remote'] == true) {
        return 'Обновите подписку, чтобы получить вариант для $activeCore.';
      }
      return 'Для $activeCore нет подходящего варианта подписки.';
    }
    if (variant?['state'] == 'unavailable') {
      return 'Провайдер не выдал формат $activeCore.';
    }
    return null;
  }

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
      _coreSelections.addAll(
        Map<String, String>.from(saved['coreSelections'] ?? {}),
      );
      scenarios.value = (saved['scenarios'] as List? ?? [])
          .whereType<Map>()
          .map((s) => Map<String, dynamic>.from(s))
          .toList();
      final savedMode = saved['mode'];
      if (['local', 'system', 'tun'].contains(savedMode)) {
        mode.value = Platform.isLinux && savedMode == 'system'
            ? 'tun'
            : savedMode;
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
          'deviceName': Platform.isLinux ? 'Linux' : 'Windows',
          'platform': Platform.isLinux ? 'Linux' : 'Windows',
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
    final groupChanged = this.group.value['id'] != group['id'];
    if (groupChanged) {
      if (this.group.value['id'] != null && selected.value.isNotEmpty) {
        _coreSelections['${this.group.value['id']}/$activeCore'] =
            selected.value;
      }
      lastScenario.value = '';
      _cancelRefreshes();
      cancelProbes();
      probes.clear();
      final saved = _libraries[group['id']?.toString()] as Map? ?? {};
      _subscriptionOrder = List<String>.from(saved['subscriptionOrder'] ?? []);
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
    _projectLibrary(restoreSelection: groupChanged);
    final ids = (group['servers'] as List? ?? [])
        .map((s) => s['id'].toString())
        .toSet();

    if (probes.keys.any((id) => !ids.contains(id))) cancelProbes();
    probes.removeWhere((id, _) => !ids.contains(id));
    for (final id in ids) {
      probes.putIfAbsent(id, () => ValueNotifier(const ProbeState()));
    }
  }

  Future<void> reload() async {
    final token = api.token;
    final revision = ++_reloadRevision;
    final next = await api.request('me');
    if (!_closed && api.token == token && revision == _reloadRevision) {
      _acceptGroup(next);
    }
  }

  Future<void> saveSession() {
    if (sessionFile == null) return Future.value();
    final text = jsonEncode({
      'token': api.token,
      'selected': selected.value,
      'mode': mode.value,
      'sessions': sessions.value,
      'libraries': _libraries,
      'coreSelections': _coreSelections,
      'scenarios': scenarios.value,
    });
    _saveQueue = _saveQueue.catchError((_) {}).then((_) async {
      final tmp = File('${sessionFile!.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(sessionFile!.path);
    });
    return _saveQueue;
  }

  Future<void> select(String id) async {
    if (!servers.value.any((s) => s.id == id && s.availableForCore)) return;
    selected.value = id;
    _coreSelections['${group.value['id']}/$activeCore'] = id;
    await saveSession();
  }

  Future<void> moveSubscription(
    String sourceId,
    String targetId, {
    bool after = false,
  }) async {
    if (sourceId == targetId ||
        !_subscriptionOrder.contains(sourceId) ||
        !_subscriptionOrder.contains(targetId)) {
      return;
    }
    final order = [..._subscriptionOrder]..remove(sourceId);
    order.insert(order.indexOf(targetId) + (after ? 1 : 0), sourceId);
    _subscriptionOrder = order;
    _projectLibrary();
    await _saveLibrary();
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
      'subscriptionOrder': _subscriptionOrder,
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

  Future<void> clearProbeHistory() async {
    cancelProbes();
    for (final probe in probes.values) {
      probe.value = const ProbeState();
    }
    probeRevision.value++;
    await _saveLibrary();
  }

  bool get pendingConnectionChoice {
    final state = connection.value;
    if (state['state'] != 'running') return false;
    if (state['serverId'] != selected.value || state['mode'] != mode.value) {
      return true;
    }
    final currentDomains = List<String>.from(state['directDomains'] ?? [])
      ..sort();
    final wantedDomains = List<String>.from(
      preferences.value['directDomains'] ?? [],
    )..sort();
    if (jsonEncode(currentDomains) != jsonEncode(wantedDomains)) return true;
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
    if (!visible) cancelProbes();
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
        _cancelCheck();
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

  Future<void> toggleConnection() async {
    var started = false;
    await _connectionAction(
      pendingConnectionChoice ? 'switching' : 'starting',
      () async {
        if (connection.value['state'] == 'running' &&
            !pendingConnectionChoice) {
          connectionPhase.value = 'stopping';
          connection.value = await api.request(
            'connection/stop',
            method: 'POST',
          );
          return;
        }
        started = await _startSelected();
      },
    );
    if (started && !_closed) unawaited(check());
  }

  Future<bool> _startSelected() async {
    if (!servers.value.any(
      (s) => s.id == selected.value && s.availableForCore,
    )) {
      return false;
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
        if (decision == 'cancel') return false;
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
    if (connection.value['state'] != 'running') return false;
    lastUsed.value = connection.value['serverId']?.toString() ?? selected.value;
    await _saveLibrary();
    return true;
  }

  Future<void> stop() => _connectionAction('stopping', () async {
    connection.value = await api.request('connection/stop', method: 'POST');
  });
  void _cancelCheck() {
    _checkGeneration++;
    _checkRequest?.cancel();
    _checkRequest = null;
    checking.value = false;
  }

  Future<void> check() async {
    if (_closed ||
        busy.value ||
        checking.value ||
        connection.value['state'] != 'running') {
      return;
    }
    final generation = ++_checkGeneration;
    final request = RequestCancellation();
    _checkRequest = request;
    checking.value = true;
    connectionIssue.value = '';
    try {
      final next = await api
          .request('connection/check', method: 'POST', cancellation: request)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              request.cancel();
              throw ApiException(
                'Контрольный адрес не ответил. VPN остаётся включён.',
              );
            },
          );
      if (!_closed && generation == _checkGeneration) connection.value = next;
    } catch (e) {
      if (!_closed && generation == _checkGeneration) {
        connectionIssue.value = e.toString();
        await poll(force: true);
      }
    } finally {
      if (generation == _checkGeneration) {
        checking.value = false;
        _checkRequest = null;
      }
    }
  }

  Future<void> importText(String raw, {String responseFormat = 'auto'}) =>
      action(() async {
        final text = raw.trim();
        if (text.startsWith('SVOI1.')) {
          final result = await api.request(
            'transfer/import',
            method: 'POST',
            body: {
              'code': text,
              'deviceName': Platform.isLinux ? 'Linux' : 'Windows',
              'platform': Platform.isLinux ? 'Linux' : 'Windows',
              'replace': true,
            },
          );
          _acceptGroup(result['group']);
          await _refreshAll();
        } else if (text.startsWith('https://')) {
          final result = await api.request(
            'subscriptions',
            method: 'POST',
            body: {'url': text, 'name': '', 'responseFormat': responseFormat},
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

  Future<void> extractProfileNodes(ServerEntry server) => action(() async {
    final previous = servers.value.map((s) => s.id).toSet();
    _acceptGroup(
      await api.request(
        'servers/${Uri.encodeComponent(server.id)}/extract-nodes',
        method: 'POST',
        body: {'acknowledgeProfileRulesOmitted': true},
      ),
    );
    await reload();
    final added = servers.value.where((s) => !previous.contains(s.id)).toList();
    if (added.isNotEmpty) await select(added.first.id);
    message.value =
        'Создано узлов: ${added.length}. Исходный профиль сохранён. Копии не обновляются вместе с подпиской.';
    await saveSession();
  });

  Future<void> createProfile(String name) => action(() async {
    _cancelRefreshes();
    _cancelCheck();
    cancelProbes();
    connection.value = await api.request('connection/stop', method: 'POST');
    final result = await api.request(
      'groups',
      method: 'POST',
      body: {
        'name': name,
        'deviceName': 'Мой ПК',
        'platform': Platform.isLinux ? 'Linux' : 'Windows',
      },
    );
    api.token = result['token'];
    _acceptGroup(result['group']);
    await saveSession();
  });

  Future<void> switchProfile(String token) => action(() async {
    _cancelRefreshes();
    _cancelCheck();
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
        _cancelRefreshes();
        _cancelCheck();
        cancelProbes();
        connection.value = await api.request('connection/stop', method: 'POST');
        final result = await api.request(
          'transfer/import',
          method: 'POST',
          body: {
            'code': code,
            'deviceName': 'Мой ПК',
            'platform': Platform.isLinux ? 'Linux' : 'Windows',
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
  void cancelRefresh(String id) => _refreshRequests[id]?.cancel();

  void _cancelRefreshes() {
    _refreshGeneration++;
    for (final request in _refreshRequests.values) {
      request.cancel();
    }
    _refreshRequests.clear();
    _refreshedErrorVariants.clear();
    refreshingSources.value = {};
    refreshErrors.value = {};
    refreshProgress.value = '';
    _refreshingAll = false;
  }

  Future<void> _refreshAll() => refreshSubscriptions();

  Future<void> refreshSubscriptions() async {
    if (_closed || _refreshingAll || _refreshRequests.isNotEmpty) return;
    final generation = _refreshGeneration;
    final sources = subscriptions.value
        .where((s) => s['remote'] == true)
        .toList();
    if (sources.isEmpty) return;
    _refreshingAll = true;
    var next = 0;
    var done = 0;
    refreshProgress.value = 'Обновляем подписки · 0 из ${sources.length}';
    Future<void> worker() async {
      while (next < sources.length &&
          !_closed &&
          generation == _refreshGeneration) {
        final source = sources[next++];
        await refreshSource(source['id'].toString());
        if (!_closed && generation == _refreshGeneration) {
          done++;
          refreshProgress.value =
              'Обновляем подписки · $done из ${sources.length}';
        }
      }
    }

    try {
      await Future.wait([worker(), worker()]);
    } finally {
      if (!_closed && generation == _refreshGeneration) {
        _refreshingAll = false;
        final failed = sources
            .where((s) => refreshErrors.value.containsKey(s['id']))
            .length;
        refreshProgress.value = failed == 0
            ? 'Подписки обновлены · $done из ${sources.length}'
            : 'Не обновлено: $failed · причину смотрите рядом с подпиской';
      }
    }
  }

  Future<void> refreshSource(String id) async {
    if (_closed || _refreshRequests.containsKey(id)) return;
    if (!_refreshingAll) refreshProgress.value = '';
    final generation = _refreshGeneration;
    final request = RequestCancellation();
    var timedOut = false;
    final beforeVariants = jsonEncode(
      subscriptions.value.where((s) => s['id'] == id).firstOrNull?['variants'],
    );
    _refreshedErrorVariants.remove(id);
    _refreshRequests[id] = request;
    refreshingSources.value = {...refreshingSources.value, id};
    refreshErrors.value = {...refreshErrors.value}..remove(id);
    try {
      await api
          .request(
            'subscription/refresh?id=${Uri.encodeComponent(id)}',
            method: 'POST',
            cancellation: request,
          )
          .timeout(
            const Duration(seconds: 25),
            onTimeout: () {
              timedOut = true;
              request.cancel();
              throw ApiException('Сервер подписки не ответил вовремя.');
            },
          );
      if (!_closed && generation == _refreshGeneration && !request.cancelled) {
        await reload();
      }
    } catch (e) {
      if (!_closed &&
          generation == _refreshGeneration &&
          !request.cancelled &&
          e is ApiException &&
          e.status >= 400) {
        try {
          await reload();
          final afterVariants = jsonEncode(
            subscriptions.value
                .where((s) => s['id'] == id)
                .firstOrNull?['variants'],
          );
          if (afterVariants != beforeVariants) _refreshedErrorVariants.add(id);
        } catch (_) {}
      }
      if (!_closed &&
          generation == _refreshGeneration &&
          (!request.cancelled || timedOut)) {
        refreshErrors.value = {
          ...refreshErrors.value,
          id: subscriptionFailure(e).text,
        };
      } else if (!_closed && generation == _refreshGeneration) {
        refreshErrors.value = {
          ...refreshErrors.value,
          id: 'Обновление остановлено. Сохранённые серверы доступны; можно повторить попытку.',
        };
      }
    } finally {
      if (generation == _refreshGeneration) {
        _refreshRequests.remove(id);
        refreshingSources.value = {...refreshingSources.value}..remove(id);
      }
    }
  }

  Future<void> settings(Map<String, dynamic> patch) => action(() async {
    preferences.value = await api.request(
      'settings',
      method: 'PUT',
      body: {...preferences.value, ...patch},
    );
    if (patch.containsKey('probe')) cancelProbes();
  });
  bool _serverAvailable(ServerEntry server) =>
      server.availableForCore &&
      servers.value.any((s) => s.id == server.id && s.availableForCore);

  Future<Map<String, dynamic>> config(ServerEntry server) =>
      _serverAvailable(server)
      ? api.request(
          'servers/${Uri.encodeComponent(server.id)}/config?mode=${mode.value}',
        )
      : Future.value(<String, dynamic>{});
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

  String probeUrlFor(ServerEntry server) {
    final settings = preferences.value['probe'] as Map? ?? {};
    final fallback = settings['url'] as String? ?? defaultProbeUrl;
    if (settings['urlSource'] == 'custom' ||
        (settings['urlSource'] != 'subscription' &&
            fallback != defaultProbeUrl)) {
      return fallback;
    }
    for (final source in subscriptions.value) {
      if (source['id'] != server.json['subscriptionId']) continue;
      final variant =
          (source['variants'] as Map?)?[server.json['subscriptionCore']]
              as Map?;
      final metadata =
          (variant != null ? variant['metadata'] : source['metadata'])
              as Map? ??
          {};
      final hints = metadata['hints'] as Map? ?? {};
      final value = hints['check-url-via-proxy']?.toString().trim() ?? '';
      final uri = Uri.tryParse(value);
      if (value.length <= 2048 &&
          !RegExp(r'[\s\\]').hasMatch(value) &&
          uri != null &&
          ['http', 'https'].contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          !uri.hasFragment) {
        return value;
      }
    }
    return fallback;
  }

  Future<void> probe(List<ServerEntry> list) async {
    list = list.where(_serverAvailable).toList(growable: false);
    if (probing.value ||
        list.isEmpty ||
        connection.value['available'] != true) {
      return;
    }
    final generation = ++_probeGeneration;
    final settings = preferences.value['probe'] as Map? ?? {};
    final parallel = ((settings['parallel'] as num?)?.toInt() ?? 4).clamp(
      1,
      10,
    );
    final timeout = ((settings['timeoutSeconds'] as num?)?.toInt() ?? 4).clamp(
      1,
      15,
    );
    probing.value = true;
    probeProgress.value =
        '0 из ${list.length} · до $parallel одновременно · лимит $timeout с';
    var next = 0, done = 0;
    Future<void> worker() async {
      while (next < list.length && generation == _probeGeneration && !_closed) {
        final server = list[next++], cancellation = RequestCancellation();
        final url = probeUrlFor(server);
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
                Duration(seconds: timeout + 7),
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
              url: response['url'] as String? ?? url,
            );
          }
        } catch (e) {
          if (generation == _probeGeneration) {
            result.value = ProbeState(
              error: e.toString(),
              setupError: e is ApiException && e.status == 503,
              failureKind: e is ApiException
                  ? switch (e.status) {
                      422 => 'unsupported',
                      504 => 'timeout',
                      429 => 'busy',
                      _ => 'network',
                    }
                  : 'network',
              checkedAt: DateTime.now(),
              url: url,
            );
          }
        } finally {
          _requests.remove(cancellation);
        }
        if (generation == _probeGeneration) {
          done++;
          probeProgress.value =
              '$done из ${list.length} · GET через профиль · до $parallel одновременно · лимит $timeout с';
        }
      }
    }

    try {
      await Future.wait(
        List.generate(
          list.length < parallel ? list.length : parallel,
          (_) => worker(),
        ),
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
    _cancelCheck();
    _cancelRefreshes();
    connection.removeListener(_syncPublicIP);
    connection.removeListener(_syncCoreLibrary);
    connectionPhase.removeListener(_syncPublicIP);
    _ipGeneration++;
    _ipRequest?.cancel();
    _timer?.cancel();
    cancelProbes();
    await _saveQueue.catchError((_) {});
    await api.close();
  }
}
