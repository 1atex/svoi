import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/android_backend.dart';
import 'package:svoi_flutter/backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
}
