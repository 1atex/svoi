import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'config/android-release.json').read_text(encoding='utf-8'))
TAG = 'android-v' + CONFIG['versionName']
DIRECTORY = ROOT / '.tools/android-release'


def prepare():
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    artifacts = []
    sdk = Path(os.environ['ANDROID_HOME'])
    for abi, gradle_abi, label in [('arm64-v8a', 'arm64-v8a', 'arm64'), ('x86_64', 'x86_64', 'x64')]:
        source = ROOT / f'flutter_client/build/app/outputs/flutter-apk/app-{gradle_abi}-release.apk'
        output = subprocess.check_output([str(sdk / 'build-tools/36.0.0/apksigner'), 'verify', '--print-certs', str(source)], text=True)
        digest = re.search(r'Signer #1 certificate SHA-256 digest: ([0-9a-f]+)', output).group(1)
        if digest != CONFIG['signingCertificateSha256']:
            raise RuntimeError('Release APK is not signed with the permanent key')
        package = subprocess.check_output([str(sdk / 'build-tools/36.0.0/aapt'), 'dump', 'badging', str(source)], text=True)
        if f"name='{CONFIG['packageName']}'" not in package or f"versionCode='{CONFIG['versionCode']}'" not in package:
            raise RuntimeError('Release package/version mismatch')
        name = f"SVOI-Android-{CONFIG['versionName']}-{label}.apk"
        target = DIRECTORY / name
        shutil.copyfile(source, target)
        sha = hashlib.sha256(target.read_bytes()).hexdigest()
        (DIRECTORY / (name + '.sha256')).write_text(f'{sha}  {name}\n', encoding='utf-8')
        artifacts.append({'abi': abi, 'size': target.stat().st_size, 'sha256': sha, 'url': f'https://github.com/1atex/svoi/releases/download/{TAG}/{name}'})
    manifest = {k: CONFIG[k] for k in ('versionName', 'versionCode', 'packageName', 'minSdk')}
    manifest.update(schema=1, artifacts=artifacts)
    (DIRECTORY / 'svoi-android-update.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')


def publish():
    base = 'https://api.github.com/repos/1atex/svoi'

    def api(method, url, value=None, raw=None):
        headers = {'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN'], 'Accept': 'application/vnd.github+json', 'User-Agent': 'SVOI-Android-Release'}
        data = raw
        if value is not None:
            headers['Content-Type'] = 'application/json'
            data = json.dumps(value).encode()
        elif raw is not None:
            headers['Content-Type'] = 'application/octet-stream'
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers, data=data, method=method), timeout=180) as response:
            return json.load(response)

    releases = api('GET', base + '/releases?per_page=100')
    release = next((r for r in releases if r['tag_name'] == TAG), None)
    if release is None:
        body = f'''Android {CONFIG['versionName']} · Android 8+.

**Телефон Xiaomi/Redmi/POCO и другие ARM64:** скачайте файл с окончанием `-arm64.apk`.
**Эмулятор Android Studio x86_64:** скачайте `-x64.apk`.

В Preview 9:
- Интернетометр: сравнение напрямую и через до трёх выбранных профилей Xray, загрузка, отдача и HTTPS-отклик до svoi.space.
- Графики фактической скорости по времени с общей шкалой для маршрутов. Загрузка — сплошная линия, отдача — пунктир; в узком окне график находится под цифрами.
- Показаны длительность и объём каждой фазы. Короткие выборки отмечаются; процент не рассчитывается, если загрузка на любом из двух маршрутов измерена слишком коротко.
- Проверка запускается вручную; при уходе с экрана, сворачивании, смене профиля или включении VPN останавливается. Готовые результаты остаются до закрытия приложения.
- До 48 МиБ полезных данных на маршрут, максимум 192 МиБ на сравнение плюс сетевые накладные расходы. Тестовый узел фиксирован; результат не означает максимальную скорость любого сайта.
- Интернетометр находится в «Настройки → Интернетометр». Перед сравнением нужно отключить VPN. Профиль проверяется встроенным временным ядром, без прямого fallback вместо VPN.
- «Что нового» открывает svoi.space с установленной версией; GitHub доступен отдельной кнопкой.

Короткое знакомство после установки/обновления: выбор темы и изменения на svoi.space. Встроенный Xray используется без создания отдельных системных процессов.
Постоянная подпись сохранена; проверяется обновление поверх Preview 8.

**Переход с Preview 5 и более ранних:** сначала сохраните код переноса профиля. Старые APK подписывались временными ключами CI: может потребоваться удалить старую версию и установить эту заново. Последующие версии с постоянной подписью устанавливаются поверх приложения.

Загрузка продолжается при сворачивании благодаря Android DownloadManager. Установка выполняется после подтверждения пользователя. Сервисы Windows и APK имеют отдельные каналы обновлений.

[Исходный код](https://github.com/1atex/svoi/tree/{os.environ['GITHUB_SHA']}) · [Проверки](https://github.com/1atex/svoi/actions/runs/{os.environ['GITHUB_RUN_ID']})
'''
        release = api('POST', base + '/releases', {'tag_name': TAG, 'target_commitish': os.environ['GITHUB_SHA'], 'name': 'SVOI Android ' + CONFIG['versionName'], 'draft': True, 'prerelease': True, 'make_latest': 'false', 'body': body})
    assets = api('GET', base + f"/releases/{release['id']}/assets")
    for file in sorted(DIRECTORY.iterdir()):
        if file.suffix not in ('.apk', '.sha256', '.json'):
            continue
        data = file.read_bytes()
        digest = 'sha256:' + hashlib.sha256(data).hexdigest()
        asset = next((a for a in assets if a['name'] == file.name), None)
        if asset is None:
            if not release['draft']:
                raise RuntimeError('Published releases are immutable; increment versionCode and versionName')
            asset = api('POST', release['upload_url'].split('{')[0] + '?name=' + urllib.parse.quote(file.name), raw=data)
        if asset['size'] != len(data) or asset.get('digest') != digest:
            raise RuntimeError('Existing/uploaded asset does not match: ' + file.name)
    release = api('PATCH', base + f"/releases/{release['id']}", {'draft': False, 'prerelease': True, 'make_latest': 'false'})
    print(release['html_url'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'publish'])
    args = parser.parse_args()
    prepare() if args.action == 'prepare' else publish()
