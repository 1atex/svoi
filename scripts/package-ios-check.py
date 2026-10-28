import hashlib
from pathlib import Path
import plistlib
import stat
import sys
import zipfile

app = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
extension = app / 'PlugIns/PacketTunnel.appex'
main = plistlib.loads((app / 'Info.plist').read_bytes())
provider = plistlib.loads((extension / 'Info.plist').read_bytes())
assert main['CFBundleIdentifier'] == 'dev.svoi.tunnelcheck'
assert provider['CFBundleIdentifier'] == main['CFBundleIdentifier'] + '.PacketTunnel'
assert provider['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.networkextension.packet-tunnel'
assert (app / main['CFBundleExecutable']).is_file()
assert (extension / provider['CFBundleExecutable']).is_file()
ipa = output / 'SVOI-TunnelCheck-0.1.0.ipa'
with zipfile.ZipFile(ipa, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(app.rglob('*')):
        if file.is_file():
            archive.write(file, 'Payload/' + app.name + '/' + file.relative_to(app).as_posix())
with zipfile.ZipFile(ipa) as archive:
    assert archive.testzip() is None
    assert archive.getinfo('Payload/SvoiTunnelCheck.app/' + main['CFBundleExecutable']).external_attr >> 16 & stat.S_IXUSR
digest = hashlib.file_digest(ipa.open('rb'), 'sha256').hexdigest()
ipa.with_suffix('.ipa.sha256').write_text(f'{digest}  {ipa.name}\n')
print(f'Built {ipa.name}, {ipa.stat().st_size} bytes, SHA256 {digest}')
