import hashlib
import io
import json
from pathlib import Path
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
config = json.loads((root / 'config/ios-release.json').read_text())
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
source = subprocess.check_output(['git', 'archive', '--format=zip', 'HEAD'], cwd=root)
output = root / 'releases' / ('ios-v' + config['version'])
output.mkdir(parents=True, exist_ok=True)
archive = output / f'SVOI-{config["version"]}-ios-source.zip'
instructions = f'''SVOI iOS — исходники клиента, {config['version']}
Коммит: {commit}

На Mac Apple Silicon с полным Xcode:
1. Распакуйте папку SVOI-iOS на внутренний диск, например в ~/Developer.
2. Откройте Xcode и завершите первоначальную настройку.
3. Откройте Терминал в папке SVOI-iOS.
4. Выполните:
   bash START-IOS.command

Скрипт установит инструменты и соберёт IPA в releases/ios-v{config['version']}.
Flutter и Android Studio для этой iOS-версии не нужны.
Homebrew может запросить пароль администратора Mac в Терминале.

На macOS Sequoia 15.6 выбирайте совместимый Xcode по таблице Apple.
Например, Xcode 26.3 поддерживает 15.6. Установка самой новой версии
из App Store может потребовать обновить macOS; для компиляции этого
проекта обновление до самой новой macOS не требуется.
https://developer.apple.com/xcode/system-requirements

Это приложение SVOI с интерфейсом SwiftUI, подписками и встроенным Xray,
а не прежний Tunnel Check. Пока это development preview.
Подпись для установки на iPhone выполняется отдельно ПОСЛЕ сборки.
В IPA нет provisioning-профилей Apple. Сохраните PacketTunnel.appex.
Идентификаторы для профилей подписи:
  dev.svoi.app.ios
  dev.svoi.app.ios.PacketTunnel
Оба профиля должны разрешать Network Extensions / Packet Tunnel.

Инструкция и ограничения: docs/IOS.md.
Журнал сборки Xcode: .tools/ios-client-build.log.
Для повторной сборки перенесите ранее созданную IPA в другое место.
После подписи потребуется проверка на физическом iPhone: сборка и
проверка пакетов на macOS не заменяют запуск iOS Network Extension.
'''
with zipfile.ZipFile(io.BytesIO(source)) as original, zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as result:
    for entry in original.infolist():
        if entry.is_dir():
            continue
        if Path(entry.filename).suffix.lower() in {'.p12', '.pfx', '.mobileprovision', '.key'}:
            raise RuntimeError('Unexpected signing material: ' + entry.filename)
        item = zipfile.ZipInfo('SVOI-iOS/' + entry.filename)
        item.create_system = entry.create_system
        item.external_attr = entry.external_attr
        item.compress_type = zipfile.ZIP_DEFLATED
        result.writestr(item, original.read(entry))
    result.writestr('SVOI-iOS/BUILD-IOS.txt', instructions.encode('utf-8'))
with zipfile.ZipFile(archive) as check:
    assert check.testzip() is None
    for name in ['START-IOS.command', 'scripts/setup-ios.sh', 'apple/ios-client/project.yml', 'mobile/apple.go', 'docs/IOS.md']:
        assert 'SVOI-iOS/' + name in check.namelist()
with archive.open('rb') as data:
    digest = hashlib.file_digest(data, 'sha256').hexdigest()
archive.with_suffix('.zip.sha256').write_text(f'{digest}  {archive.name}\n')
print(archive)
print(f'{archive.stat().st_size / 1024 / 1024:.1f} MiB; ZIP verified')
