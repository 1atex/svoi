import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/ui_icons.dart';

void main() {
  for (final style in UiIconStyle.values) {
    testWidgets('search glyph stays 18px inside a 48px slot: ${style.name}', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              decoration: InputDecoration(
                prefixIconConstraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                prefixIcon: SvoiIcon(Icons.search, size: 18, style: style),
                hintText: 'Найти сервер',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final glyph = find.descendant(
        of: find.byType(SvoiIcon),
        matching: find.byType(SvgPicture),
      );
      expect(tester.getSize(glyph), const Size(18, 18));
      expect(tester.getSize(find.byType(SvoiIcon)), const Size(48, 48));
      expect(tester.getCenter(glyph), tester.getCenter(find.byType(SvoiIcon)));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unconstrained icons keep their size and explicit scaling', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SvoiIcon(Icons.search, size: 18),
                SvoiIcon(Icons.search, size: 18, applyTextScaling: true),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final icons = find.byType(SvgPicture);
    expect(tester.getSize(icons.at(0)), const Size(18, 18));
    expect(tester.getSize(icons.at(1)), const Size(36, 36));
    expect(tester.takeException(), isNull);
  });
}
