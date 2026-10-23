import 'backend.dart';

class DemoBackend extends Backend {
  final group = <String, dynamic>{
    'id': 'demo',
    'servers': List.generate(
      1000,
      (i) => {
        'id': '$i',
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
    if (path == 'groups') return {'token': 'demo', 'group': group};
    if (path == 'me') return group;
    if (path == 'settings') return {'autoRefresh': false};
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
