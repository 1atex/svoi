import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/main.dart';

void main() {
  testWidgets(
    'refresh animation confirms success but never cancellation or failure',
    (tester) async {
      var cancelled = 0;
      Future<void> show(
        bool busy, {
        bool failed = false,
        bool reduced = false,
      }) => tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Scaffold(
              body: SubscriptionRefreshButton(
                name: 'Test',
                busy: busy,
                failed: failed,
                onRefresh: () {},
                onCancel: () => cancelled++,
              ),
            ),
          ),
        ),
      );
      await show(false);
      await show(true);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('refresh-working')), findsOneWidget);
      await tester.tap(find.byTooltip('Остановить обновление Test'));
      await show(false);
      await tester.pumpAndSettle();
      expect(cancelled, 1);
      expect(find.byKey(const ValueKey('refresh-done')), findsNothing);
      await show(true);
      await show(false, failed: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('refresh-done')), findsNothing);
      await show(true, reduced: true);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, false);
      await show(false, reduced: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('refresh-done')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('refresh-idle')), findsOneWidget);
    },
  );

  testWidgets('arrival waits for completed session and ignores failed switch', (
    tester,
  ) async {
    final first = DateTime(2026, 10, 31),
        second = first.add(const Duration(minutes: 1));
    Future<void> show(bool busy, DateTime session, {bool reduced = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: ConnectionArrival(
                running: true,
                busy: busy,
                foreground: true,
                session: session,
                child: const SizedBox(width: 188, height: 188),
              ),
            ),
          ),
        );
    await show(false, first);
    await show(true, first);
    await show(false, first);
    expect(find.byKey(const ValueKey('connection-arrival')), findsNothing);
    await show(true, second);
    expect(find.byKey(const ValueKey('connection-arrival')), findsNothing);
    await show(false, second);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('connection-arrival')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('connection-arrival')), findsNothing);
    await show(false, first, reduced: true);
    expect(find.byKey(const ValueKey('connection-arrival')), findsNothing);
  });

  testWidgets(
    'import supports clipboard, code and file with explicit confirmation',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('svoi-import-test-'),
      ))!;
      final file = File('${dir.path}/profile.yaml');
      await tester.runAsync(() => file.writeAsString('proxies: []'));
      addTearDown(() => dir.delete(recursive: true));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        (call) async => file.path,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          windowChannel,
          null,
        ),
      );
      String clipboard = 'https://example.com/sub';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': clipboard} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      Map<String, String>? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: svoiTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<Map<String, String>>(
                    context: context,
                    builder: (_) => const SubscriptionImportDialog(),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
      }

      await open();
      await tester.tap(find.text('Вставить из буфера'));
      await tester.pumpAndSettle();
      expect(find.text(clipboard), findsOneWidget);
      await tester.tap(find.text('Добавить'));
      await tester.pumpAndSettle();
      expect(result?['content'], clipboard);
      await open();
      clipboard = 'SVOI1.example';
      await tester.tap(find.text('Вставить из буфера'));
      await tester.pumpAndSettle();
      expect(find.text('Посмотреть профиль'), findsOneWidget);
      await tester.tap(find.text('Посмотреть профиль'));
      await tester.pumpAndSettle();
      expect(result?['content'], clipboard);
      await open();
      await tester.tap(find.text('Из файла'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Выбрать файл'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('profile.yaml'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Добавить'));
      await tester.pumpAndSettle();
      expect(result?['content'], 'proxies: []');
    },
  );

  testWidgets('import fits compact window and large text in every mode', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: svoiTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const Scaffold(body: SubscriptionImportDialog()),
      ),
    );
    for (final tab in ['Код SVOI', 'Из файла', 'Ссылка / текст']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Отмена').hitTestable(), findsOneWidget);
    }
  });
}
