import hashlib
import json
from pathlib import Path
import plistlib
import stat
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
config = json.loads((root / 'config/ios-release.json').read_text())
app = Path(sys.argv[1]).resolve()
extension = app / 'PlugIns/PacketTunnel.appex'
for directory, expected in [(app, 'dev.svoi.app.ios'), (extension, 'dev.svoi.app.ios.PacketTunnel')]:
    info = plistlib.loads((directory / 'Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == expected
    assert info['CFBundleShortVersionString'] == config['version'].split('-')[0]
    assert str(info['CFBundleVersion']) == str(config['build'])
    assert (directory / info['CFBundleExecutable']).stat().st_mode & stat.S_IXUSR
    executable = (directory / info['CFBundleExecutable']).read_bytes()
    assert b'UI preview: native VPN is not linked' not in executable, 'Do not package the interface test host'
    assert b'interface-preview' not in executable, 'Interface fixtures must be compiled out of the device build'
    assert all((directory / 'core' / name).is_file() for name in ['geoip.dat', 'geosite.dat'])
    assert not (directory / 'embedded.mobileprovision').exists(), 'This lane must not embed signing credentials'
output = root / 'releases' / ('ios-v' + config['version'])
output.mkdir(parents=True, exist_ok=True)
ipa = output / f'SVOI-{config["version"]}-ios-arm64-unsigned.ipa'
if ipa.exists():
    raise SystemExit('IPA already exists. Move the earlier file aside before packaging again.')
with zipfile.ZipFile(ipa, 'w', compression=zipfile.ZIP_DEFLATED) as data:
    for file in sorted(app.rglob('*')):
        if file.is_file():
            data.write(file, 'Payload/' + app.name + '/' + file.relative_to(app).as_posix())
with zipfile.ZipFile(ipa) as data:
    assert data.testzip() is None
with ipa.open('rb') as data:
    digest = hashlib.file_digest(data, 'sha256').hexdigest()
ipa.with_suffix('.ipa.sha256').write_text(f'{digest}  {ipa.name}\n')
print(ipa)
print('No Apple provisioning is embedded. Re-sign both SVOI.app and PacketTunnel.appex with suitable profiles before installing.')
