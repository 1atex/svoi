import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/main.dart';

const metadataSource = <String, dynamic>{
  'name': 'provider.example',
  'host': 'provider.example',
  'metadata': {
    'title': 'Моя подписка',
    'upload': 0,
    'download': 19657052396,
    'total': 0,
    'expire': 0,
    'updateHours': 1,
    'announcement': 'До конца подписки 26521 дней',
    'supportUrl': 'https://t.me/Support_bot',
    'infoUrl': 'https://t.me/Provider',
    'infoButtonText': 'Telegram',
    'routingStatus': 'happ-not-applied',
    'routing': {'Name': 'Provider'},
    'hints': {'ping-type': 'proxy', 'subscription-always-hwid-enable': '1'},
  },
};

void main() {
  test('zero and absent limits are distinct; expiry is not inferred from announcement', () {
    final m = subscriptionMetadata(metadataSource);
    expect(subscriptionTraffic(m), 'Использовано 18.3 ГиБ · без лимита');
    expect(subscriptionExpiry(m), 'Без даты окончания');
    expect(subscriptionTraffic({}), '');
    expect(subscriptionExpiry({}), '');
    expect(
      subscriptionTraffic({'download': 1024}),
      'Использовано 1.0 КиБ · лимит не указан',
    );
    expect(
      subscriptionExpiry({'expire': 1}, now: DateTime(2026)),
      startsWith('Истекла'),
    );
    expect(subscriptionDisplayName(metadataSource), 'Моя подписка');
    expect(
      subscriptionDisplayName({...metadataSource, 'name': 'Family'}),
      'Family',
    );
  });
  test('provider links allow HTTPS only', () {
    for (final url in [
      'file:///C:/Windows',
      'javascript:alert(1)',
      'https://user:pass@example.org',
      'https://example.org\n',
      r'https://example.org\x',
    ]) {
      expect(subscriptionLink(url), isNull);
    }
    expect(subscriptionLink('https://t.me/Support_bot')?.host, 't.me');
  });
  testWidgets(
    'metadata stays readable at narrow width and large text; links open on click only',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          windowChannel,
          null,
        ),
      );
      tester.view.physicalSize = const Size(480, 700);
      tester.view.devicePixelRatio = 1;
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
          home: const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(24),
              child: SubscriptionDetails(source: metadataSource),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Без даты окончания'), findsOneWidget);
      expect(find.text('Маршрутизация Happ не применена'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.ensureVisible(find.text('Поддержка'));
      await tester.tap(find.text('Поддержка'));
      await tester.pumpAndSettle();
      expect(calls.single.method, 'openExternal');
      expect(calls.single.arguments, 'https://t.me/Support_bot');
    },
  );
  testWidgets('quota progress is clamped and depleted traffic is explicit', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubscriptionDetails(
            source: const {
              'metadata': {'upload': 60, 'download': 60, 'total': 100},
            },
          ),
        ),
      ),
    );
    expect(find.text('Лимит трафика исчерпан'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      1,
    );
  });
}
