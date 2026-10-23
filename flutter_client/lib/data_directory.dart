import 'dart:convert';
import 'dart:io';

Future<Directory> prepareDataDirectory({
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final override = env['SVOI_DATA'] ?? env['SVOI_FLUTTER_DATA'];
  if (override != null) return Directory(override)..createSync(recursive: true);
  final root = env['APPDATA'] ?? Directory.current.path;
  final target = Directory('$root/SVOI');
  final marker = File('${target.path}/.desktop-data');
  final legacy = Directory('$root/SVOI-Flutter');
  if (await marker.exists() || !await legacy.exists()) {
    await target.create(recursive: true);
    await marker.writeAsString('1', flush: true);
    return target;
  }
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final staging = Directory('$root/SVOI-migration-$stamp');
  await staging.create();
  Future<void> copy(Directory from, Directory to, {bool top = false}) async {
    await for (final entry in from.list(followLinks: false)) {
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (top && name == 'updates') continue;
      if (top && name == 'runtime' && entry is Directory) {
        await for (final recovery in entry.list(followLinks: false)) {
          final recoveryName = recovery.uri.pathSegments.last;
          if (recovery is File &&
              recoveryName.startsWith('proxy-recovery-') &&
              recoveryName.endsWith('.json')) {
            await Directory('${to.path}/runtime').create(recursive: true);
            await recovery.copy('${to.path}/runtime/$recoveryName');
          }
        }
        continue;
      }
      if (entry is Link) {
        throw FileSystemException(
          'Не удалось перенести ссылку в данных SVOI',
          entry.path,
        );
      }
      if (entry is Directory) {
        final child = await Directory('${to.path}/$name').create();
        await copy(entry, child);
      } else if (entry is File) {
        await entry.copy('${to.path}/$name');
      }
    }
  }

  await copy(legacy, staging, top: true);
  final settings = File('${staging.path}/groups.json.settings.json');
  if (await settings.exists()) {
    final data =
        jsonDecode(await settings.readAsString()) as Map<String, dynamic>;
    final folder = data['zapretFolder'] as String? ?? '';
    final oldPath = legacy.absolute.path.replaceAll('\\', '/');
    final normalized = folder.replaceAll('\\', '/');
    if (normalized.toLowerCase().startsWith('${oldPath.toLowerCase()}/')) {
      data['zapretFolder'] =
          '${target.absolute.path}${normalized.substring(oldPath.length)}';
      await settings.writeAsString(jsonEncode(data), flush: true);
    }
  }
  await File('${staging.path}/.desktop-data').writeAsString('1', flush: true);
  Directory? backup;
  if (await target.exists()) {
    backup = await target.rename('$root/SVOI-backup-$stamp');
  }
  try {
    await staging.rename(target.path);
  } catch (_) {
    if (backup != null) await backup.rename(target.path);
    rethrow;
  }
  return target;
}
