import hashlib
import json
import re
from pathlib import Path
import shutil
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
icon_names = json.loads((root / 'config/ui-icons.json').read_text(encoding='utf-8'))['ios']
for source in (root / 'apple/ios-client/App').glob('*.swift'):
    text = source.read_text(encoding='utf-8')
    symbols = re.findall(r'SvoiGlyph\s*\(\s*"([^"]+)"', text)
    symbols += re.findall(r'(?:systemImage|symbol):\s*"([^"]+)"', text)
    missing = set(symbols) - icon_names.keys()
    if missing:
        raise SystemExit(f'{source.name}: missing interface icons: {sorted(missing)}')
config = json.loads((root / 'config/ios-release.json').read_text())
build = root / '.tools/ios-assets'
build.mkdir(parents=True, exist_ok=True)
archive = build / 'xray.zip'
if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != config['assetSha256']:
    subprocess.run(['curl', '--fail', '--location', '--retry', '3', config['assetUrl'], '-o', str(archive)], check=True)
if hashlib.sha256(archive.read_bytes()).hexdigest() != config['assetSha256']:
    raise SystemExit('Xray asset SHA-256 mismatch')
assets = root / 'apple/ios-client/Resources/core'
assets.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(archive) as data:
    for name in ['geoip.dat', 'geosite.dat']:
        (assets / name).write_bytes(data.read(name))
    licenses = root / 'apple/ios-client/Resources/licenses'
    licenses.mkdir(parents=True, exist_ok=True)
    (licenses / 'Xray-LICENSE.txt').write_bytes(data.read('LICENSE'))
    (licenses / 'Xray-SOURCE.txt').write_text('Xray-core 1b1647c\nhttps://github.com/XTLS/Xray-core/tree/1b1647cd9ddf\nSVOI applies mobile/patches/xray-tun-close.json; source and build scripts: https://github.com/1atex/svoi/tree/ios-preview\n')
    shutil.copy2(root / 'LICENSE', licenses / 'SVOI-MIT.txt')
    shutil.copytree(root / 'licenses', licenses, dirs_exist_ok=True)
icons = root / 'apple/ios-client/App/Assets.xcassets/AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
images = []
for appearance, source in [('any', 'app-icon-ios.png'), ('dark', 'app-icon-dark.png'), ('tinted', 'app-icon-tinted.png')]:
    name = f'icon-{appearance}.png'
    shutil.copy2(root / 'assets/brand' / source, icons / name)
    image = {'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024', 'filename': name}
    if appearance != 'any':
        image['appearances'] = [{'appearance': 'luminosity', 'value': appearance}]
    images.append(image)
(icons / 'Contents.json').write_text(json.dumps({'images': images, 'info': {'version': 1, 'author': 'xcode'}}, indent=2) + '\n')
shutil.copy2(root / 'backend/web/dns-providers.json', root / 'apple/ios-client/Resources/dns-providers.json')
mark = icons.parent / 'SvoiMark.imageset'
mark.mkdir(parents=True, exist_ok=True)
images = []
for scale in [1, 2, 3]:
    filename = f'mark-{scale}.png'
    subprocess.run(['sips', '-z', str(64 * scale), str(64 * scale), str(root / 'assets/brand/app-icon-ios.png'), '--out', str(mark / filename)], check=True, stdout=subprocess.DEVNULL)
    images.append({'idiom': 'universal', 'scale': f'{scale}x', 'filename': filename})
(mark / 'Contents.json').write_text(json.dumps({'images': images, 'info': {'version': 1, 'author': 'xcode'}}, indent=2) + '\n')

for style in ['outline', 'duotone']:
    for source in (root / 'flutter_client/assets/ui-icons' / style).glob('*.svg'):
        folder = icons.parent / f'UiIcon-{style}-{source.stem}.imageset'
        folder.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, folder / 'icon.svg')
        (folder / 'Contents.json').write_text(json.dumps({'images':[{'idiom':'universal','filename':'icon.svg'}],'info':{'version':1,'author':'xcode'},'properties':{'preserves-vector-representation':True,'template-rendering-intent':'template'}},indent=2)+'\n')
