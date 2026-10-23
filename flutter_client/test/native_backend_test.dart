import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';

void main() {
  test(
    'real Go backend imports, renders config, persists session and exits',
    () async {
      final data = await Directory.systemTemp.createTemp('svoi-flutter-test-');
      await File('${data.path}/groups.json.settings.json').writeAsString(
        jsonEncode({
          'autoRefresh': false,
          'autoUpdate': false,
          'autoDownload': false,
          'zapretAutoUpdate': false,
          'routing': {'mode': 'all', 'processes': []},
        }),
      );
      try {
        final api = await NativeBackend.launch(data);
        final c = SvoiController(
          api,
          sessionFile: File('${data.path}/session.json'),
        );
        try {
          await c.initialize();
          while (c.busy.value) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(c.connection.value['available'], true);
          await c.importText(
            'vless://00000000-0000-4000-8000-000000000001@127.0.0.1:9?type=tcp&security=none#Local-test',
          );
          expect(c.message.value, isEmpty);
          expect(c.servers.value, hasLength(1));
          final config = await c.config(c.servers.value.single);
          expect(config['effective'], isNotNull);
          expect(config['original'], isNotNull);
          await c.setMode('local');
          await c.select(c.servers.value.single.id);

          await c.importText(
            jsonEncode({
              'remarks': 'Routing-test',
              'outbounds': [
                {
                  'tag': 'unused-node',
                  'protocol': 'vless',
                  'settings': {
                    'vnext': [
                      {
                        'address': '127.0.0.1',
                        'port': 9,
                        'users': [
                          {
                            'id': '00000000-0000-4000-8000-000000000001',
                            'encryption': 'none',
                          },
                        ],
                      },
                    ],
                  },
                },
                {'tag': 'test-direct', 'protocol': 'freedom'},
              ],
              'routing': {
                'rules': [
                  {
                    'type': 'field',
                    'ip': ['127.0.0.1/32'],
                    'outboundTag': 'test-direct',
                  },
                ],
              },
            }),
          );
          expect(c.message.value, isEmpty);
          expect(c.servers.value, hasLength(2));
          final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          target.listen((request) {
            request.response.write('routed-locally');
            request.response.close();
          });
          final client = HttpClient();
          try {
            final running = await api.request(
              'connection/start',
              method: 'POST',
              body: {'serverId': c.servers.value.last.id, 'mode': 'local'},
            );
            expect(running['state'], 'running');
            client.findProxy = (_) => 'PROXY 127.0.0.1:${running['httpPort']}';
            final request = await client.getUrl(
              Uri.parse('http://127.0.0.1:${target.port}/'),
            );
            final response = await request.close().timeout(
              const Duration(seconds: 5),
            );
            expect(
              await response.transform(utf8.decoder).join(),
              'routed-locally',
            );
          } finally {
            client.close(force: true);
            await target.close(force: true);
          }
          expect((await api.request('updates'))['state'], 'idle');
          final source = c.subscriptions.value.first;
          await c.mutateGroup(
            'subscriptions/${source['id']}',
            body: {'name': 'Renamed', 'url': ''},
          );
          expect(c.subscriptions.value.first['name'], 'Renamed');
          final exported = await api.request('transfer/export', method: 'POST');
          final preview = await api.request(
            'transfer/preview',
            method: 'POST',
            body: {'code': exported['code']},
          );
          expect(preview['servers'], 2);
        } finally {
          await c.close();
        }
        expect(
          await api.process.exitCode.timeout(const Duration(seconds: 5)),
          0,
        );
        final reopened = await NativeBackend.launch(data);
        final c2 = SvoiController(
          reopened,
          sessionFile: File('${data.path}/session.json'),
        );
        try {
          await c2.initialize();
          expect(c2.servers.value, hasLength(2));
          expect(c2.servers.value.first.name, 'Local-test');
          expect(c2.selected.value, c2.servers.value.first.id);
          expect(c2.connection.value['state'], 'stopped');
        } finally {
          await c2.close();
        }
      } finally {
        await data.delete(recursive: true);
      }
    },
    skip: Platform.environment['SVOI_BACKEND'] == null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
