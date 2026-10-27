import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/release_notice.dart';
import 'package:svoi_flutter/release_notice_banner.dart';

void main() {
  late Directory directory;
  late File file;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('svoi-release-notice-');
    file = File('${directory.path}/notice.json');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'fresh install is silent, upgrade survives restart until acknowledged',
    () async {
      final first = ReleaseNoticeStore(file);
      await first.load('0.6.0-beta.3');
      expect(first.pendingVersion, isNull);
      await first.load('0.6.0-beta.4');
      expect(first.pendingVersion, '0.6.0-beta.4');
      final restarted = ReleaseNoticeStore(file);
      await restarted.load('0.6.0-beta.4');
      expect(restarted.pendingVersion, '0.6.0-beta.4');
      await restarted.acknowledge();
      await restarted.load('0.6.0-beta.4');
      expect(restarted.pendingVersion, isNull);
      await restarted.load('0.6.0-beta.5');
      expect(restarted.pendingVersion, '0.6.0-beta.5');
    },
  );

  test(
    'installer detects first upgrade from versions without notice tracking',
    () async {
      final launch = File('${directory.path}/launch.ini');
      await launch.writeAsString(
        '[Launch]\r\nRunAsAdmin=1\r\n[Updates]\r\nPreviousVersion=0.6.0-beta.3\r\nInstalledVersion=0.6.0-beta.4\r\n',
      );
      final previous = await installerPreviousVersion(launch, '0.6.0-beta.4');
      expect(previous, '0.6.0-beta.3');
      final store = ReleaseNoticeStore(file);
      await store.load('0.6.0-beta.4', previousInstall: previous);
      expect(store.pendingVersion, '0.6.0-beta.4');
      await store.acknowledge();
      await store.load('0.6.0-beta.4', previousInstall: previous);
      expect(store.pendingVersion, isNull);
      expect(await installerPreviousVersion(launch, '0.6.0-beta.5'), isNull);
    },
  );

  test(
    'downgrade, reinstall and malformed state do not create fake upgrade',
    () async {
      final store = ReleaseNoticeStore(file);
      await store.load('0.6.0-beta.4', previousInstall: '0.6.0-beta.5');
      expect(store.pendingVersion, isNull);
      await store.load('0.6.0-beta.4', previousInstall: '0.6.0-beta.4');
      expect(store.pendingVersion, isNull);
      await file.writeAsString('{bad');
      await store.load('0.6.0-beta.4');
      expect(store.pendingVersion, isNull);
    },
  );

  test('numeric pre-release ordering and exact installed-version URL', () {
    expect(isNewerRelease('0.6.0-beta.15', '0.6.0-beta.8'), isTrue);
    expect(isNewerRelease('0.6.0', '0.6.0-beta.15'), isTrue);
    expect(isNewerRelease('0.6.0-beta.3', '0.6.0'), isFalse);
    expect(isNewerRelease('unknown', '0.6.0'), isFalse);
    expect(
      changelogUri('0.6.0-beta.4').path,
      '/1atex/svoi/releases/tag/v0.6.0-beta.4',
    );
    expect(
      changelogUri('0.1.0-preview.9', platform: 'android').path,
      '/1atex/svoi/releases/tag/android-v0.1.0-preview.9',
    );
  });

  test(
    'Android package update is announced on first tracked run only',
    () async {
      final store = ReleaseNoticeStore(file);
      await store.load('0.1.0-preview.9', updatedInstall: true);
      expect(store.pendingVersion, '0.1.0-preview.9');
      await store.acknowledge();
      await store.load('0.1.0-preview.9', updatedInstall: true);
      expect(store.pendingVersion, isNull);
    },
  );

  testWidgets(
    'notice opens only on click, and failed browser retains the notice',
    (tester) async {
      late ReleaseNoticeStore store;
      await tester.runAsync(() async {
        store = ReleaseNoticeStore(file);
        await store.load('0.6.0-beta.4', previousInstall: '0.6.0-beta.3');
      });
      var opened = 0;
      var fail = true;
      Future<void> open(Uri uri) async {
        opened++;
        expect(uri.path, endsWith('v0.6.0-beta.4'));
        if (fail) throw Exception('No browser');
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReleaseNoticeBanner(store: store, open: open),
          ),
        ),
      );
      expect(opened, 0);
      await tester.runAsync(() async {
        await tester.tap(find.text('Что нового'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(store.pendingVersion, '0.6.0-beta.4');
      expect(find.textContaining('Не удалось открыть'), findsOneWidget);
      fail = false;
      await tester.runAsync(() async {
        await tester.tap(find.text('Что нового'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(opened, 2);
      expect(store.pendingVersion, isNull);
    },
  );

  testWidgets(
    'banner fits small screen with enlarged text and dismisses without browser',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late ReleaseNoticeStore store;
      await tester.runAsync(() async {
        store = ReleaseNoticeStore(file);
        await store.load('0.6.0-beta.4', previousInstall: '0.6.0-beta.3');
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: ReleaseNoticeBanner(
              store: store,
              open: (_) async => fail('Unrequested browser'),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Скрыть до следующего обновления'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(store.pendingVersion, isNull);
    },
  );
}
