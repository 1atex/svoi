import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/data_directory.dart';

void main() {
  test('migration preserves profiles and both original directories, remaps managed paths once', () async {
    final root = await Directory.systemTemp.createTemp('svoi-migration-');
    addTearDown(() => root.delete(recursive: true));
    final legacy = await Directory('${root.path}/SVOI-Flutter').create();
    final old = await Directory('${root.path}/SVOI').create();
    await File('${old.path}/groups.json').writeAsString('old webview profile');
    await File('${legacy.path}/session.json')
        .writeAsString('{"token":"saved-token"}');
    await File('${legacy.path}/groups.json').writeAsString('current profiles');
    await File('${legacy.path}/groups.json.settings.json').writeAsString(
      jsonEncode({'zapretFolder': '${legacy.path}/zapret/custom'}),
    );
    await Directory('${legacy.path}/zapret/custom').create(recursive: true);
    await File('${legacy.path}/zapret/custom/general.bat')
        .writeAsString('strategy');
    await Directory('${legacy.path}/runtime').create();
    await File('${legacy.path}/runtime/private.json')
        .writeAsString('obsolete runtime');
    await File('${legacy.path}/runtime/proxy-recovery-test.json')
        .writeAsString('recover proxy');
    final migrated = await prepareDataDirectory(
      environment: {'APPDATA': root.path},
    );
    expect(
      await File('${migrated.path}/groups.json').readAsString(),
      'current profiles',
    );
    expect(
      await File('${migrated.path}/session.json').readAsString(),
      '{"token":"saved-token"}',
    );
    expect(
      await File('${migrated.path}/zapret/custom/general.bat').readAsString(),
      'strategy',
    );
    expect(await File('${migrated.path}/runtime/private.json').exists(), false);
    expect(
      await File('${migrated.path}/runtime/proxy-recovery-test.json')
          .readAsString(),
      'recover proxy',
    );
    final settings = jsonDecode(
      await File('${migrated.path}/groups.json.settings.json').readAsString(),
    );
    expect(
      settings['zapretFolder'].replaceAll('\\', '/'),
      '${migrated.absolute.path}/zapret/custom'.replaceAll('\\', '/'),
    );
    expect(
      await File('${legacy.path}/groups.json').readAsString(),
      'current profiles',
    );
    final backup = (await root.list().toList()).singleWhere(
      (e) => e.path.contains('SVOI-backup-'),
    );
    expect(
      await File('${backup.path}/groups.json').readAsString(),
      'old webview profile',
    );
    await File('${migrated.path}/groups.json')
        .writeAsString('updated profiles');
    await prepareDataDirectory(environment: {'APPDATA': root.path});
    expect(
      await File('${migrated.path}/groups.json').readAsString(),
      'updated profiles',
    );
  });

  test('failed migration leaves current and legacy data intact', () async {
    final root = await Directory.systemTemp.createTemp(
      'svoi-migration-failure-',
    );
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/SVOI-Flutter').create();
    await File('${root.path}/SVOI-Flutter/groups.json.settings.json')
        .writeAsString('invalid JSON');
    await Directory('${root.path}/SVOI').create();
    await File('${root.path}/SVOI/groups.json').writeAsString('original');
    await expectLater(
      prepareDataDirectory(environment: {'APPDATA': root.path}),
      throwsFormatException,
    );
    expect(
      await File('${root.path}/SVOI/groups.json').readAsString(),
      'original',
    );
    expect(
      await File('${root.path}/SVOI-Flutter/groups.json.settings.json')
          .readAsString(),
      'invalid JSON',
    );
  });

  test(
    'explicit data directory avoids migration and accepts legacy override',
    () async {
      final root = await Directory.systemTemp.createTemp('svoi-data-');
      addTearDown(() => root.delete(recursive: true));
      final chosen = await prepareDataDirectory(
        environment: {
          'APPDATA': root.path,
          'SVOI_DATA': '${root.path}/custom',
          'SVOI_FLUTTER_DATA': '${root.path}/old',
        },
      );
      expect(chosen.path, '${root.path}/custom');
      expect(await Directory('${root.path}/SVOI').exists(), false);
    },
  );
}
