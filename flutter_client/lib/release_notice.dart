import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

Uri changelogUri(String version, {String platform = 'windows'}) {
  const websiteEnabled = bool.fromEnvironment('SVOI_PUBLIC_CHANGELOG');
  if (websiteEnabled) {
    return Uri.https('svoi.space', '/changelog/', {
      'platform': platform,
      'version': version,
    });
  }
  final prefix = switch (platform) {
    'android' => 'android-v',
    'linux' => 'linux-v',
    _ => 'v',
  };
  return Uri.https('github.com', '/1atex/svoi/releases/tag/$prefix$version');
}

bool isNewerRelease(String current, String previous) {
  List<String>? parts(String value) {
    final match = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)(?:-([\da-zA-Z.-]+))?(?:\+[\da-zA-Z.-]+)?$',
    ).firstMatch(value);
    return match == null ? null : [for (var i = 1; i <= 4; i++) match[i] ?? ''];
  }

  final a = parts(current), b = parts(previous);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    final diff = int.parse(a[i]).compareTo(int.parse(b[i]));
    if (diff != 0) return diff > 0;
  }
  if (a[3] == b[3]) return false;
  if (a[3].isEmpty) return true;
  if (b[3].isEmpty) return false;
  final x = a[3].split('.'), y = b[3].split('.');
  for (var i = 0; i < x.length && i < y.length; i++) {
    final n = int.tryParse(x[i]), m = int.tryParse(y[i]);
    final diff = n != null && m != null
        ? n.compareTo(m)
        : n != null
        ? -1
        : m != null
        ? 1
        : x[i].compareTo(y[i]);
    if (diff != 0) return diff > 0;
  }
  return x.length > y.length;
}

Future<String?> installerPreviousVersion(
  File launchFile,
  String current,
) async {
  try {
    final lines = await launchFile.readAsLines();
    var section = '';
    final values = <String, String>{};
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.toLowerCase();
      }
      if (section != '[updates]') continue;
      final index = line.indexOf('=');
      if (index > 0) {
        values[line.substring(0, index).toLowerCase()] = line
            .substring(index + 1)
            .trim();
      }
    }
    return values['installedversion'] == current
        ? values['previousversion']
        : null;
  } on FileSystemException {
    return null;
  }
}

class ReleaseNoticeStore extends ChangeNotifier {
  ReleaseNoticeStore(this.file);
  final File file;
  String? pendingVersion;
  bool onboardingPending = false;
  bool onboardingFirstInstall = false;
  bool loaded = false;
  String _onboardedVersion = '';
  bool _disposed = false;
  String get installedVersion => _installed;
  String _installed = '';
  bool _acknowledged = true;
  Future<void> _writes = Future.value();

  Future<void> load(
    String current, {
    String? previousInstall,
    bool updatedInstall = false,
  }) async {
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) data = decoded;
    } on FileSystemException catch (_) {
    } on FormatException catch (_) {}
    final previous = data?['installedVersion'] is String
        ? data!['installedVersion'] as String
        : previousInstall;
    _installed = current;
    final upgrade = previous != null && isNewerRelease(current, previous);
    final downgrade = previous != null && isNewerRelease(previous, current);
    _onboardedVersion = data?['onboardingVersion'] is String
        ? data!['onboardingVersion'] as String
        : '';
    onboardingFirstInstall = previous == current
        ? (data?['onboardingFirstInstall'] == true)
        : previous == null && !updatedInstall;
    onboardingPending = !downgrade && (upgrade || _onboardedVersion != current);
    if (downgrade) _onboardedVersion = current;
    _acknowledged =
        !((data == null && updatedInstall) ||
            (previous != null && isNewerRelease(current, previous)) ||
            (previous == current && data?['acknowledged'] == false));
    pendingVersion = _acknowledged ? null : current;
    await _save();
    loaded = true;
    if (!_disposed) notifyListeners();
  }

  Future<void> completeOnboarding({bool reviewedRelease = false}) async {
    final previous = _onboardedVersion;
    final acknowledged = _acknowledged;
    _onboardedVersion = _installed;
    if (reviewedRelease) _acknowledged = true;
    try {
      await _save();
    } catch (_) {
      _onboardedVersion = previous;
      _acknowledged = acknowledged;
      rethrow;
    }
    onboardingPending = false;
    if (reviewedRelease) pendingVersion = null;
    if (!_disposed) notifyListeners();
  }

  Future<void> acknowledge() async {
    _acknowledged = true;
    await _save();
    pendingVersion = null;
    if (!_disposed) notifyListeners();
  }

  Future<void> _save() {
    final text = jsonEncode({
      'installedVersion': _installed,
      'acknowledged': _acknowledged,
      'onboardingVersion': _onboardedVersion,
      'onboardingFirstInstall': onboardingFirstInstall,
    });
    return _writes = _writes.catchError((Object _) {}).then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
