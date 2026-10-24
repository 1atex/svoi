import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/android_backend.dart';
import 'package:svoi_flutter/backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Android low-RAM capability limits probes to one', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      AndroidBackend.channel,
      (_) async => '{"directory":"test","probeConcurrency":1}',
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(AndroidBackend.channel, null),
    );
    final backend = await AndroidBackend.launch();
    expect(backend.probeConcurrency, 1);
    await backend.close();
  });
  test(
    'Android authorization errors retain their status for session recovery',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AndroidBackend.channel, (call) async {
        if (call.method == 'init') return '{"directory":"preview"}';
        throw PlatformException(code: '401', message: 'Сессия истекла');
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(AndroidBackend.channel, null),
      );
      final api = await AndroidBackend.launch();
      await expectLater(
        api.request('me'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
      );
    },
  );

  test(
    'probe cancellation reaches Android once and ignores late results',
    () async {
      final calls = <MethodCall>[];
      final response = Completer<String>();
      final started = Completer<void>();
      final cancelled = Completer<void>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AndroidBackend.channel, (call) async {
        calls.add(call);
        if (call.method == 'init') return '{"directory":"test"}';
        if (call.method == 'request') {
          started.complete();
          return response.future;
        }
        if (call.method == 'cancelProbe') cancelled.complete();
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(AndroidBackend.channel, null),
      );
      final backend = await AndroidBackend.launch();
      final cancellation = RequestCancellation();
      final result = backend.request(
        'servers/example/probe',
        method: 'POST',
        cancellation: cancellation,
      );
      final assertion = expectLater(result, throwsA(isA<ApiException>()));
      await started.future;
      cancellation.cancel();
      cancellation.cancel();
      await cancelled.future;
      expect(calls.where((c) => c.method == 'cancelProbe').length, 1);
      expect(calls.last.arguments['id'], calls[1].arguments['probeID']);
      response.complete('{"latency":42}');
      await assertion;
      expect(cancellation.onCancel, isNull);
      await backend.close();
    },
  );
}
