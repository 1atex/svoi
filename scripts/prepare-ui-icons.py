import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import ssl
import urllib.request
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
config = json.loads((root / 'config/ui-icons.json').read_text(encoding='utf-8'))
icons = sorted(set(config['lucide'].values()) | set(config['material'].values()) | set(config['ios'].values()))
target = root / 'flutter_client/assets/ui-icons'
parser = argparse.ArgumentParser()
parser.add_argument('--fetch', action='store_true')
args = parser.parse_args()

if args.fetch:
    try:
        import certifi
        context = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        context = ssl.create_default_context()
    previous = {}
    if (target / 'manifest.json').exists():
        previous = json.loads((target / 'manifest.json').read_text())
    base = f'https://raw.githubusercontent.com/phosphor-icons/core/{config["revision"]}'
    def fetch(item):
        style, name = item
        path = target / style / (name + '.svg')
        if path.exists() and previous.get('revision') == config['revision'] and previous.get('files', {}).get(f'{style}/{name}.svg') == hashlib.sha256(path.read_bytes()).hexdigest():
            return
        weight = 'regular' if style == 'outline' else 'duotone'
        filename = name if style == 'outline' else name + '-duotone'
        if name.endswith('-filled'):
            weight = 'fill'
            filename = name.removesuffix('-filled') + '-fill'
        with urllib.request.urlopen(f'{base}/assets/{weight}/{filename}.svg', context=context, timeout=30) as response:
            raw = response.read().decode('utf-8')
        raw = raw.replace('fill="currentColor"', 'fill="#000000"').replace('<svg ', '<svg width="24" height="24" ', 1)
        path = target / style / (name + '.svg')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(raw + '\n', encoding='utf-8')
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(fetch, [(style, name) for style in ['outline', 'duotone'] for name in icons]))
    with urllib.request.urlopen(base + '/LICENSE', context=context, timeout=30) as response:
        (root / 'licenses/Phosphor-Icons-MIT.txt').write_bytes(response.read())

hashes = {}
for style in ['outline', 'duotone']:
    for name in icons:
        path = target / style / (name + '.svg')
        document = ET.fromstring(path.read_bytes())
        assert document.attrib['viewBox'] == '0 0 256 256', path
        assert all(item.tag.rsplit('}', 1)[-1] in ['svg', 'path', 'g', 'rect', 'circle', 'line', 'polyline', 'polygon', 'ellipse'] for item in document.iter()), path
        hashes[f'{style}/{name}.svg'] = hashlib.sha256(path.read_bytes()).hexdigest()
(target / 'manifest.json').write_text(json.dumps({'revision':config['revision'], 'files':hashes}, indent=2) + '\n')

dart = ["part of 'ui_icons.dart';", '', 'final _uiIconNames = <IconData, String>{']
for family, prefix in [('lucide','LucideIcons'), ('material','Icons')]:
    dart += [f"  {prefix}.{key}: '{value}'," for key, value in config[family].items()]
dart += ['};', '']
(root / 'flutter_client/lib/ui_icon_names.dart').write_text('\n'.join(dart), encoding='utf-8')
print(f'Prepared {len(icons)} interface icons in two styles; verified {len(hashes)} SVGs')

apple = root / 'apple/ios-client/App'
if apple.exists():
    swift = ['extension SvoiIconAssets {', '  static let names: [String: String] = [']
    swift += [f'    "{key}": "{value}",' for key, value in config['ios'].items()]
    swift += ['  ]', '}', '']
    (apple / 'InterfaceIconNames.swift').write_text('\n'.join(swift), encoding='utf-8')
