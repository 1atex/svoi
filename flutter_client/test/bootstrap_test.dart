import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/backend.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';

class StartupBackend extends DemoBackend {
  StartupBackend({this.failZapret = false, this.failInitialization = false});
  final bool failZapret, failInitialization;
  bool closed = false;

  @override
  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Object? body,
    RequestCancellation? cancellation,
  }) async {
    if (closed) throw ApiException('Backend closed');
    if (failInitialization && path == 'groups') {
      throw ApiException('Initialization failed');
    }
    if (failZapret && path == 'zapret') {
      throw ApiException('Zapret status unavailable');
    }
    if (['zapret', 'startup', 'updates'].contains(path)) return {};
    return super.request(
      path,
      method: method,
      body: body,
      cancellation: cancellation,
    );
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  for (final failZapret in [false, true]) {
    testWidgets(
      'startup keeps backend alive after ${failZapret ? 'zapret' : 'tray'} failure',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final calls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          windowChannel,
          (call) async {
            calls.add(call.method);
            if (!failZapret && call.method == 'tray') {
              throw PlatformException(
                code: 'tray',
                message: 'Tray unavailable',
              );
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            windowChannel,
            null,
          ),
        );
        final api = StartupBackend(failZapret: failZapret);
        await tester.pumpWidget(
          Bootstrap(demo: true, startup: true, backend: api),
        );
        await tester.pumpAndSettle();
        final shell = tester.widget<SvoiShell>(find.byType(SvoiShell));
        expect(api.closed, isFalse);
        expect(calls, contains('show'));
        if (!failZapret) expect(calls, contains('tray'));
        expect(shell.controller.message.value, contains('Не удалось'));
        await shell.controller.api.request('startup');
        await shell.controller.api.request('updates');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await shell.controller.close();
      },
    );
  }

  testWidgets('initialization failure closes backend and shows startup error', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowChannel,
      (_) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        null,
      ),
    );
    final api = StartupBackend(failInitialization: true);
    await tester.pumpWidget(Bootstrap(demo: true, startup: true, backend: api));
    await tester.pumpAndSettle();
    expect(api.closed, isTrue);
    expect(find.byType(SvoiShell), findsNothing);
    expect(find.text('Initialization failed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
