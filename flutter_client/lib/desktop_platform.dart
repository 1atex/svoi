import 'dart:io';

String get desktopPlatformName => platformName(Platform.operatingSystem);
String get desktopPlatformId =>
    Platform.isMacOS ? 'macos' : Platform.operatingSystem;

String platformName(String os) => switch (os) {
  'macos' => 'macOS',
  'linux' => 'Linux',
  _ => 'Windows',
};

List<String> supportedConnectionModes(String os) => switch (os) {
  'macos' => const ['system', 'local'],
  'linux' => const ['tun', 'local'],
  _ => const ['tun', 'system', 'local'],
};

String restoredConnectionMode(String os, Object? saved) {
  final modes = supportedConnectionModes(os);
  return modes.contains(saved) ? saved as String : modes.first;
}
