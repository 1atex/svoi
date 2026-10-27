import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/main.dart';

void main() {
  for (final missing in [false, true]) {
    testWidgets(
      'Telegram ${missing ? 'missing handler explains recovery' : 'opens without a browser'}',
      (tester) async {
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          windowChannel,
          (call) async {
            calls.add(call);
            if (missing) throw PlatformException(code: 'telegram_missing');
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            windowChannel,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: svoiTheme(),
            home: const Scaffold(body: CommunityButton()),
          ),
        );
        await tester.tap(find.byTooltip('Новости SVOI в Telegram'));
        await tester.pumpAndSettle();
        expect(calls.map((call) => call.method), ['openCommunity']);
        if (missing) {
          expect(
            find.textContaining('Установите Telegram Desktop'),
            findsOneWidget,
          );
          expect(find.text(communityChannel), findsOneWidget);
          expect(find.text('Скопировать ссылку').hitTestable(), findsOneWidget);
          await tester.tap(find.text('Закрыть'));
          await tester.pumpAndSettle();
        } else {
          expect(find.byType(AlertDialog), findsNothing);
        }
        expect(
          find.byTooltip('Новости SVOI в Telegram').hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
