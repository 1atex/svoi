import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
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
icons = root / 'apple/ios-client/App/Assets.xcassets/AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
images = []
for idiom, sizes in [('iphone', [20, 29, 40, 60]), ('ipad', [20, 29, 40, 76, 83.5])]:
    for size in sizes:
        scales = [2, 3] if idiom == 'iphone' else [2] if size == 83.5 else [1, 2]
        for scale in scales:
            pixels = int(size * scale)
            filename = f'{idiom}-{size}-{scale}.png'
            subprocess.run(['sips', '-z', str(pixels), str(pixels), str(root / 'assets/brand/svoi-avatar-amber.png'), '--out', str(icons / filename)], check=True, stdout=subprocess.DEVNULL)
            images.append({'idiom': idiom, 'size': f'{size}x{size}', 'scale': f'{scale}x', 'filename': filename})
subprocess.run(['sips', '-z', '1024', '1024', str(root / 'assets/brand/svoi-avatar-amber.png'), '--out', str(icons / 'marketing.png')], check=True, stdout=subprocess.DEVNULL)
images.append({'idiom': 'ios-marketing', 'size': '1024x1024', 'scale': '1x', 'filename': 'marketing.png'})
(icons / 'Contents.json').write_text(json.dumps({'images': images, 'info': {'version': 1, 'author': 'xcode'}}, indent=2) + '\n')
