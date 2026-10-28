import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/main.dart';
import 'package:svoi_flutter/controller.dart';
import 'package:svoi_flutter/demo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'icon preference preserves legacy themes and survives rapid saves',
    () async {
      final folder = await Directory.systemTemp.createTemp('svoi-ui-icons-');
      addTearDown(() => folder.delete(recursive: true));
      final file = File('${folder.path}/appearance.json');
      await file.writeAsString('{"theme":"mono"}');
      final store = AppearanceStore();
      await store.load(file);
      expect(store.icons.value, UiIconStyle.outline);
      await Future.wait([
        store.selectIcons(UiIconStyle.duotone),
        store.select(AppAppearance.ocean),
      ]);
      final restored = AppearanceStore();
      await restored.load(file);
      expect(restored.icons.value, UiIconStyle.duotone);
      expect(restored.value, AppAppearance.ocean);
      await file.writeAsString('{"theme":"mono","icons":"unknown"}');
      await restored.load(file);
      expect(restored.icons.value, UiIconStyle.outline);
      expect(restored.value, AppAppearance.mono);
      store.dispose();
      restored.dispose();
    },
  );

  testWidgets('icon styles update without replacing the active workspace', (
    tester,
  ) async {
    final c = SvoiController(DemoBackend());
    await c.initialize();
    final store = AppearanceStore();
    await tester.pumpWidget(
      AppearanceScope(
        store: store,
        child: MaterialApp(
          theme: svoiTheme(),
          home: SvoiShell(controller: c, demo: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(SvoiShell));
    final selected = c.selected.value;
    final connection = Map<String, dynamic>.from(c.connection.value);
    bool usesStyle(String style) => tester
        .widgetList<SvgPicture>(find.byType(SvgPicture))
        .any(
          (icon) =>
              icon.bytesLoader is SvgAssetLoader &&
              (icon.bytesLoader as SvgAssetLoader).assetName.contains(
                '/$style/',
              ),
        );
    expect(usesStyle('outline'), isTrue);
    await store.selectIcons(UiIconStyle.duotone);
    await tester.pumpAndSettle();
    expect(usesStyle('duotone'), isTrue);
    expect(tester.state(find.byType(SvoiShell)), same(state));
    expect(c.selected.value, selected);
    expect(c.connection.value, connection);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await c.close();
    store.dispose();
  });

  testWidgets('style selection fits a narrow screen with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = AppearanceStore();
    await tester.pumpWidget(
      AppearanceScope(
        store: store,
        child: MaterialApp(
          theme: svoiTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [IconStylePicker(store: store)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final choice = find.byKey(const ValueKey('icons-duotone'));
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(store.icons.value, UiIconStyle.duotone);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  test('the complete icon family and license are bundled locally', () async {
    final manifest = jsonDecode(
      await File('assets/ui-icons/manifest.json').readAsString(),
    ) as Map;
    for (final file in (manifest['files'] as Map).keys) {
      final data = await rootBundle.loadString('assets/ui-icons/$file');
      expect(data.contains('<svg'), isTrue, reason: file as String);
    }
    expect(
      await rootBundle.loadString('assets/ui-icons/LICENSE.txt'),
      contains('Phosphor Icons'),
    );
  });
}
