import 'backend.dart';

class DemoBackend extends Backend {
  DemoBackend({this.interactive = false}) {
    if (interactive) group['subscriptions'][0]['remote'] = true;
  }
  final bool interactive;
  Map<String, dynamic> demoConnection = {
    'available': true,
    'state': 'stopped',
    'version': 'Демо · симуляция VPN',
  };
  final demoSettings = <String, dynamic>{
    'autoRefresh': false,
    'routing': {'mode': 'all', 'processes': <String>[]},
    'directDomains': <String>[],
  };
  final group = <String, dynamic>{
    'id': 'demo',
    'servers': List.generate(
      1000,
      (i) => {
        'id': '$i',
        'subscriptionId': 'demo',
        'name':
            '${['NL Нидерланды', 'DE Германия', 'FI Финляндия', 'FR Франция'][i % 4]} · ${i + 1}',
        'protocol': 'vless',
        'address': 'example.com',
        'port': 443,
        'network': 'tcp',
        'security': 'reality',
      },
    ),
    'subscriptions': [
      {
        'id': 'demo',
        'name': 'Демонстрационная подписка',
        'count': 1000,
        'host': 'example.com',
        'remote': false,
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (interactive && path.startsWith('subscription/refresh')) {
      await Future<void>.delayed(const Duration(milliseconds: 450));
      return {};
    }
    if (path == 'groups') return {'token': 'demo', 'group': group};
    if (path == 'me') return group;
    if (path == 'tg-proxy') {
      return {
        'installed': false,
        'running': false,
        'port': 1443,
        'version': '1.11.2',
        'logs': <String>[],
      };
    }
    if (path == 'settings') {
      if (method == 'PUT' && body is Map) {
        demoSettings.addAll(Map<String, dynamic>.from(body));
      }
      return Map<String, dynamic>.from(demoSettings);
    }
    if (interactive && path.startsWith('connection')) {
      if (path == 'connection/start') {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        demoConnection = {
          'available': true,
          'state': 'running',
          'version': 'Демо · симуляция VPN',
          'startedAt': DateTime.now().toUtc().toIso8601String(),
          ...Map<String, dynamic>.from(body as Map),
        };
      } else if (path == 'connection/stop') {
        demoConnection = {
          'available': true,
          'state': 'stopped',
          'version': 'Демо · симуляция VPN',
        };
      } else if (path == 'connection/check') {
        demoConnection = {
          ...demoConnection,
          'checked': true,
          'checkedAt': DateTime.now().toUtc().toIso8601String(),
        };
      }
      return Map<String, dynamic>.from(demoConnection);
    }
    if (path.startsWith('connection')) {
      return {
        'available': false,
        'state': 'stopped',
        'version': 'Демонстрация · без подключения',
        'logs': <String>[],
      };
    }
    if (path.contains('/config')) {
      return {
        'rules': 0,
        'balancers': 0,
        'effective': {'demo': true},
        'original': {'demo': true},
      };
    }
    throw ApiException('В демонстрации действие недоступно.');
  }

  @override
  Future<void> close() async {}
}
