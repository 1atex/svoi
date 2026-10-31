import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/controller.dart';

import 'connection_ui_test.dart' show ConnectionBackend;

class SwitchingBackend extends ConnectionBackend {
  int starts = 0, stops = 0;
  Completer<void>? gate;
  bool failStart = false;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (path == 'connection/start') {
      starts++;
      if (gate != null) await gate!.future;
      if (failStart) throw ApiException('Не удалось подключиться');
    }
    if (path == 'connection/stop') stops++;
    return super.request(
      path,
      method: method,
      body: body,
      cancellation: cancellation,
    );
  }
}

void main() {
  test(
    'selection switches only an active VPN and serializes repeated clicks',
    () async {
      final api = SwitchingBackend();
      final c = SvoiController(api);
      await c.initialize();
      c.mode.value = 'local';
      await c.selectServer('1');
      expect(c.selected.value, '1');
      expect(api.starts, 0);
      await c.toggleConnection();
      expect(api.starts, 1);
      await c.selectServer('1');
      expect(api.starts, 1);
      expect(api.stops, 0);
      api.gate = Completer<void>();
      final switching = c.selectServer('2');
      expect(c.busy.value, true);
      await c.selectServer('3');
      api.gate!.complete();
      await switching;
      expect(api.starts, 2);
      expect(api.state['serverId'], '2');
      expect(c.selected.value, '2');
      expect(c.busy.value, false);
      api.gate = null;
      api.failStart = true;
      await c.selectServer('3');
      expect(c.connectionIssue.value, isNotEmpty);
      expect(c.busy.value, false);
      expect(c.connection.value['serverId'], '2');
      await c.selectServer('2');
      expect(c.selected.value, '2');
      expect(c.connectionIssue.value, isEmpty);
      expect(api.starts, 3);
      await c.stop();
      expect(api.stops, 1);
      await c.selectServer('4');
      expect(api.starts, 3);
      await c.close();
    },
  );
}
