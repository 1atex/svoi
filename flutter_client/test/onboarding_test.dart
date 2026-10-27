import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';
import 'package:svoi_flutter/main.dart';
import 'package:svoi_flutter/release_notice.dart';

class MemoryNotices extends ReleaseNoticeStore {
  MemoryNotices() : super(File('unused')) {
    loaded = true;
    onboardingPending = true;
  }
  @override
  String get installedVersion => '0.6.0-beta.4';
  @override
  Future<void> completeOnboarding({bool reviewedRelease = false}) async {
    onboardingPending = false;
    notifyListeners();
  }
}

void main() {
  late Directory directory;
  late File file;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('svoi-onboarding-');
    file = File('${directory.path}/release.json');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('first install resumes welcome, skipped onboarding stays closed until upgrade', () async {
    final store = ReleaseNoticeStore(file);
    await store.load('0.6.0-beta.3');
    expect(store.onboardingPending, isTrue);
    expect(store.onboardingFirstInstall, isTrue);
    final resumed = ReleaseNoticeStore(file);
    await resumed.load('0.6.0-beta.3');
    expect(resumed.onboardingFirstInstall, isTrue);
    await resumed.completeOnboarding();
    await resumed.load('0.6.0-beta.3');
    expect(resumed.onboardingPending, isFalse);
    await resumed.load('0.6.0-beta.4');
    expect(resumed.onboardingPending, isTrue);
    expect(resumed.onboardingFirstInstall, isFalse);
    await resumed.completeOnboarding(reviewedRelease: true);
    expect(resumed.pendingVersion, isNull);
    await resumed.load('0.6.0-beta.3');
    expect(resumed.onboardingPending, isFalse);
  });

  test('existing notice state migrates once and skipping retains changelog reminder', () async {
    await file.writeAsString(
      jsonEncode({'installedVersion': '0.6.0-beta.3', 'acknowledged': true}),
    );
    final store = ReleaseNoticeStore(file);
    await store.load('0.6.0-beta.4');
    expect(store.onboardingFirstInstall, isFalse);
    expect(store.onboardingPending, isTrue);
    await store.completeOnboarding();
    expect(store.pendingVersion, '0.6.0-beta.4');
    await store.load('0.6.0-beta.4');
    expect(store.onboardingPending, isFalse);
    expect(store.pendingVersion, '0.6.0-beta.4');
  });

  Future<void> viewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget dialogApp(
    AppearanceStore appearance,
    Future<void> Function(Uri) open, {
    double scale = 1,
  }) => MaterialApp(
    theme: svoiTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => OnboardingDialog(
                appearance: appearance,
                version: '0.6.0-beta.4',
                firstInstall: false,
                open: open,
              ),
            ),
            child: const Text('Открыть'),
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'theme applies and persists immediately; next, back and release link work',
    (tester) async {
      await viewport(tester, const Size(1000, 900));
      late AppearanceStore appearance;
      await tester.runAsync(() async {
        appearance = AppearanceStore(
          file: File('${directory.path}/appearance.json'),
          initial: AppAppearance.ocean,
        );
      });
      final opened = <Uri>[];
      await tester.pumpWidget(
        dialogApp(appearance, (uri) async => opened.add(uri)),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(appearance.value, AppAppearance.ocean);
      expect(opened, isEmpty);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('theme-rose')));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(appearance.value, AppAppearance.rose);
      final stored = jsonDecode(
        File('${directory.path}/appearance.json').readAsStringSync(),
      );
      expect(stored['theme'], 'rose');
      await tester.tap(find.text('Продолжить'));
      await tester.pumpAndSettle();
      expect(find.text('Всё на своих местах.'), findsOneWidget);
      await tester.tap(find.text('Посмотреть изменения'));
      await tester.pumpAndSettle();
      expect(opened.single.path, endsWith('v0.6.0-beta.4'));
      await tester.tap(find.text('Назад'));
      await tester.pumpAndSettle();
      expect(appearance.value, AppAppearance.rose);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingDialog), findsNothing);
    },
  );

  for (final size in [const Size(800, 600), const Size(320, 640)]) {
    testWidgets(
      'onboarding fits $size at 150% text and release errors allow completion',
      (tester) async {
        await viewport(tester, size);
        final appearance = AppearanceStore();
        await tester.pumpWidget(
          dialogApp(
            appearance,
            (_) async => throw Exception('Browser failed'),
            scale: 1.5,
          ),
        );
        await tester.tap(find.text('Открыть'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Продолжить'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Посмотреть изменения'));
        await tester.tap(find.text('Посмотреть изменения'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Не удалось открыть браузер'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Готово'));
        await tester.pumpAndSettle();
        expect(find.byType(OnboardingDialog), findsNothing);
      },
    );
  }

  testWidgets(
    'tray start and connection in progress defer onboarding until foreground is ready',
    (tester) async {
      await viewport(tester, const Size(1000, 900));
      final store = MemoryNotices();
      final c = SvoiController(DemoBackend());
      final visible = ValueNotifier(false);
      final appearance = AppearanceStore();
      c.busy.value = true;
      await tester.pumpWidget(
        AppearanceScope(
          store: appearance,
          child: MaterialApp(
            theme: svoiTheme(),
            home: OnboardingHost(
              store: store,
              controller: c,
              visible: visible,
              child: const Scaffold(body: Text('Main')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingDialog), findsNothing);
      visible.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingDialog), findsNothing);
      c.busy.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingDialog), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Пропустить'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(store.onboardingPending, isFalse);
      visible.value = false;
      visible.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await c.close();
    },
  );

  testWidgets('another dialog is allowed to finish before onboarding opens', (
    tester,
  ) async {
    await viewport(tester, const Size(1000, 900));
    final store = MemoryNotices();
    final c = SvoiController(DemoBackend());
    final visible = ValueNotifier(false);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      AppearanceScope(
        store: AppearanceStore(),
        child: MaterialApp(
          navigatorKey: navigator,
          theme: svoiTheme(),
          home: OnboardingHost(
            store: store,
            controller: c,
            visible: visible,
            child: const Scaffold(body: Text('Main')),
          ),
        ),
      ),
    );
    showDialog<void>(
      context: navigator.currentContext!,
      builder: (_) => const AlertDialog(title: Text('Другой диалог')),
    );
    await tester.pumpAndSettle();
    visible.value = true;
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingDialog), findsNothing);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingDialog), findsOneWidget);
    await tester.tap(find.text('Пропустить'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await c.close();
  });
}
