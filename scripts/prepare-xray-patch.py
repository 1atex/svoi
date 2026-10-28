import hashlib
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
go = shutil.which('go') or 'C:/Program Files/Go/bin/go.exe'
module = json.loads(subprocess.check_output([go, 'mod', 'download', '-json', 'github.com/xtls/xray-core@v1.260327.1-0.20261021115930-1b1647cd9ddf'], cwd=root, text=True))
if module['Version'] != 'v1.260327.1-0.20261021115930-1b1647cd9ddf':
    raise RuntimeError('Review the TUN cleanup patch for this Xray version')
source = Path(module['Dir'])
output = root / '.tools/xray-patched'
if not output.exists():
    shutil.copytree(source, output)
patches = json.loads((root / 'mobile/patches/xray-tun-close.json').read_text())
replace = {}
for name, patch in patches.items():
    original = source / name
    raw = original.read_bytes()
    if hashlib.sha256(raw).hexdigest() != patch['sha256']:
        raise RuntimeError('Upstream source changed: ' + name)
    text = raw.decode()
    for before, after in patch['replacements']:
        if text.count(before) != 1:
            raise RuntimeError('Patch context changed: ' + name)
        text = text.replace(before, after, 1)
    destination = output / name
    destination.chmod(0o644)
    destination.write_text(text, encoding='utf-8', newline='\n')
    replace[str(original.resolve())] = str(destination.resolve())
print(output)
