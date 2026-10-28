import argparse
import io
import json
from pathlib import Path
import xml.etree.ElementTree as ET

import cairosvg
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[2]
brand = root / 'assets/brand'
parser = argparse.ArgumentParser()
parser.add_argument('--platform', action='append', choices=['windows', 'linux', 'macos', 'android', 'ios'])
platforms = set(parser.parse_args().platform or ['windows', 'linux'])
symbol = ET.fromstring((brand / 'svoi-symbol.svg').read_text())
path = symbol.find('{http://www.w3.org/2000/svg}path').attrib['d']
definitions = '''<defs><linearGradient id="gold" x1="0" y1="0" x2=".85" y2="1"><stop stop-color="#FFE7AB"/><stop offset=".48" stop-color="#E7B96A"/><stop offset="1" stop-color="#BF843A"/></linearGradient><linearGradient id="tile" x2="0" y2="1"><stop stop-color="#202025"/><stop offset="1" stop-color="#101014"/></linearGradient></defs>'''

def svg(*, tile=False, apple=False, mono=False, scale=1.08):
    background = ''
    if apple:
        background = '<rect width="1024" height="1024" fill="#101014"/>'
    elif tile:
        margin, radius = (80, 192) if tile == 'macos' else (16, 224)
        background = f'<rect x="{margin}" y="{margin}" width="{1024-2*margin}" height="{1024-2*margin}" rx="{radius}" fill="url(#tile)"/>'
    fill = '#E7B96A' if mono else 'url(#gold)'
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">{definitions}{background}<path transform="translate(512 512) scale({scale}) translate(-502 -483)" fill="{fill}" d="{path}"/></svg>'

def render(source, size=1024):
    data = cairosvg.svg2png(bytestring=source.encode(), output_width=size, output_height=size)
    return Image.open(io.BytesIO(data)).convert('RGBA')

def save(image, target, *, opaque=False):
    target = root / target
    target.parent.mkdir(parents=True, exist_ok=True)
    if opaque:
        background = Image.new('RGB', image.size, '#101014')
        background.paste(image, mask=image.getchannel('A'))
        image = background
    image.save(target, optimize=True)

app = render(svg(tile=True))
apple = render(svg(apple=True))
save(apple, 'assets/brand/app-icon-ios.png', opaque=True)
save(render(svg()), 'assets/brand/app-icon-dark.png')
tinted = Image.new('RGB', (1024, 1024), '#181818')
gray = render(svg(mono=True))
tinted.paste((225, 225, 225), mask=gray.getchannel('A'))
save(tinted, 'assets/brand/app-icon-tinted.png')
save(render(svg(tile='macos', scale=1)), 'assets/brand/app-icon-macos.png')
save(app, 'assets/svoi-icon.png')
save(render(svg(tile=True), 256), 'flutter_client/assets/svoi-mark.png')
save(render(svg(mono=True, scale=1.28), 256), 'assets/brand/tray-mark.png')
save(render(svg(mono=True, scale=1.28), 256), 'flutter_client/assets/svoi-tray.png')
save(render(svg(tile=True), 128), 'backend/web/svoi-mark.png')
sizes = [(size, size) for size in [16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 96, 128, 256]]
for name in ['assets/svoi.ico', 'backend/web/favicon.ico']:
    app.save(root / name, format='ICO', sizes=sizes)

if 'windows' in platforms:
    target = root / 'flutter_client/windows/runner/resources'
    target.mkdir(parents=True, exist_ok=True)
    app.save(target / 'app_icon.ico', format='ICO', sizes=sizes)
    render(svg(mono=True, scale=1.28)).save(target / 'tray_icon.ico', format='ICO', sizes=sizes)

if 'macos' in platforms:
    target = root / 'flutter_client/macos/Runner/Assets.xcassets/AppIcon.appiconset'
    target.mkdir(parents=True, exist_ok=True)
    for size in [16, 32, 64, 128, 256, 512, 1024]:
        save(render(svg(tile='macos', scale=1), size), target / f'app_icon_{size}.png')

    tray = target.parent / 'TrayMark.imageset'
    tray.mkdir(parents=True, exist_ok=True)
    images = []
    for scale in [1,2]:
        name = f'tray-{scale}.png'
        save(render(svg(mono=True, scale=1.28),18*scale), tray / name)
        images.append({'idiom':'mac','scale':f'{scale}x','filename':name})
    (tray / 'Contents.json').write_text(json.dumps({'images':images,'info':{'version':1,'author':'xcode'},'properties':{'template-rendering-intent':'template'}},indent=2)+'\n')

if 'linux' in platforms:
    for size in [16, 24, 32, 48, 64, 128, 256, 512]:
        save(render(svg(tile=True), size), f'assets/brand/linux/{size}.png')
    (brand / 'linux/scalable.svg').write_text(svg(tile=True) + '\n')
    (brand / 'linux/symbolic.svg').write_text(svg(mono=True, scale=1.28).replace('#E7B96A', '#deddda') + '\n')

if 'android' in platforms:
    target = root / 'flutter_client/android/app/src/main/res'
    for density, size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
        save(render(svg(apple=True), size), target / f'mipmap-{density}/ic_launcher.png', opaque=True)
    for name, color, scale in [('ic_launcher_foreground','#E7B96A',.88),('ic_launcher_monochrome','#FFFFFF',.88),('ic_vpn','#FFFFFF',1.28)]:
        dimension = 24 if name == 'ic_vpn' else 108
        value = f'<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="{dimension}dp" android:height="{dimension}dp" android:viewportWidth="1024" android:viewportHeight="1024"><group android:translateX="512" android:translateY="512" android:scaleX="{scale}" android:scaleY="{scale}"><group android:translateX="-502" android:translateY="-483"><path android:fillColor="{color}" android:pathData="{path}"/></group></group></vector>\n'
        file = target / f'drawable/{name}.xml'
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(value)
    for version in [26,33]:
        folder = target / f'mipmap-anydpi-v{version}'
        folder.mkdir(parents=True, exist_ok=True)
        mono = '<monochrome android:drawable="@drawable/ic_launcher_monochrome"/>' if version == 33 else ''
        value = f'<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android"><background android:drawable="@color/svoi_icon_background"/><foreground android:drawable="@drawable/ic_launcher_foreground"/>{mono}</adaptive-icon>\n'
        for name in ['ic_launcher','ic_launcher_round']:
            (folder / f'{name}.xml').write_text(value)
    (target / 'values/icon_colors.xml').write_text('<resources><color name="svoi_icon_background">#101014</color></resources>\n')

print('Exported the SVOI icon family:', ', '.join(sorted(platforms)))
