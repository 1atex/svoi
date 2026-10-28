import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:svoi_flutter/data_directory.dart';
import 'package:svoi_flutter/desktop_platform.dart';

void main() {
  test('macOS selects system proxy and does not inherit unsupported TUN', () {
    expect(platformName('macos'), 'macOS');
    expect(supportedConnectionModes('macos'), ['system', 'local']);
    expect(restoredConnectionMode('macos', null), 'system');
    expect(restoredConnectionMode('macos', 'tun'), 'system');
    expect(restoredConnectionMode('macos', 'local'), 'local');
    expect(restoredConnectionMode('windows', null), 'tun');
    expect(restoredConnectionMode('windows', 'system'), 'system');
    expect(restoredConnectionMode('linux', 'system'), 'tun');
  });

  test(
    'macOS stores profiles in Application Support and respects overrides',
    () async {
      final root = await Directory.systemTemp.createTemp('svoi-macos-data-');
      addTearDown(() => root.delete(recursive: true));
      final home = root.absolute.path.replaceAll('\\', '/');
      final data = await prepareDataDirectory(
        environment: {'HOME': home.startsWith('/') ? home : '/$home'},
        platform: 'macos',
      );
      expect(
        data.path.replaceAll('\\', '/'),
        endsWith('/Library/Application Support/SVOI'),
      );
      expect(await data.exists(), isTrue);
      final custom = await prepareDataDirectory(
        environment: {'SVOI_DATA': '${root.path}/custom'},
        platform: 'macos',
      );
      expect(custom.path, '${root.path}/custom');
    },
    skip: Platform.isWindows,
  );
}
