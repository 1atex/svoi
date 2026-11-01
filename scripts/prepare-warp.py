"""Fetch the unmodified, pinned Cloudflare installers. Does not install WARP."""
import argparse
import hashlib
import json
import ssl
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--target', choices=['windows-x64', 'linux-x64', 'macos-arm64'], required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
asset = json.loads((ROOT / 'backend/warp_components.json').read_text(encoding='utf-8-sig'))['assets'][a.target]
a.output.mkdir(parents=True, exist_ok=True)
target = a.output / asset['name']
if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != asset['sha256']:
    try:
        import certifi
        context = ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        context = ssl.create_default_context()
    with urllib.request.urlopen(asset['url'], timeout=120, context=context) as r:
        payload = r.read(256 * 1024 * 1024 + 1)
    if len(payload) > 256 * 1024 * 1024 or hashlib.sha256(payload).hexdigest() != asset['sha256']:
        raise ValueError('Cloudflare installer checksum mismatch')
    target.write_bytes(payload)
print('Verified Cloudflare WARP:', target.name, asset['sha256'])
