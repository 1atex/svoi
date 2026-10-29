"""Sign a Windows release locally. The key is never included in build artifacts."""
import argparse, base64, hashlib, json, re
from pathlib import Path
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('installer', type=Path)
p.add_argument('--key', required=True, type=Path)
a = p.parse_args()
match = re.fullmatch(r'SVOI-(\d+\.\d+\.\d+(?:-[a-z]+\.\d+)?)-windows-x64-setup\.exe', a.installer.name)
if not match:
    raise SystemExit('Expected canonical versioned Windows x64 setup filename')
version = match[1]
key = serialization.load_pem_private_key(a.key.read_bytes(), password=None)
if not isinstance(key, Ed25519PrivateKey):
    raise SystemExit('An Ed25519 PEM private key is required')
public = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
root = Path(__file__).resolve().parents[1]
trusted = re.search(r'const updateManifestPublicKey = "([^"]+)"', (root / 'backend/update_public_key.go').read_text())[1]
if public != trusted:
    raise SystemExit('Signing key does not match the application trust root')
content = a.installer.read_bytes()
payload = json.dumps({'version': version, 'channel': 'prerelease' if '-' in version else 'stable',
    'platform': 'windows-x64', 'asset': a.installer.name, 'size': len(content),
    'sha256': hashlib.sha256(content).hexdigest()}, separators=(',', ':'), ensure_ascii=True).encode()
signature = key.sign(payload)
key.public_key().verify(signature, payload)
manifest = {'payload': base64.b64encode(payload).decode(), 'signature': base64.b64encode(signature).decode()}
output = a.installer.with_name(f'SVOI-{version}-windows-x64-update.json')
output.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
print('Signed update manifest: ' + str(output))
