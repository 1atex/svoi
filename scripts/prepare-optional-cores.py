"""Fetch pinned optional proxy cores; never install packages or alter OS routing."""
import argparse, gzip, hashlib, io, json, os, ssl, tarfile, urllib.request, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--target', required=True, choices=['windows-x64', 'linux-x64', 'macos-arm64'])
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
cache = ROOT / '.tools/optional-core-cache'
cache.mkdir(parents=True, exist_ok=True)
try:
    import certifi
    context = ssl.create_default_context(cafile=certifi.where())
except ImportError:
    context = ssl.create_default_context()
for name, entry in json.loads((ROOT / 'config/optional-cores.json').read_text()).items():
    asset = entry['assets'][a.target]
    archive = cache / asset['url'].rsplit('/', 1)[1]
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != asset['sha256']:
        request = urllib.request.Request(asset['url'], headers={'User-Agent': 'SVOI-build'})
        with urllib.request.urlopen(request, context=context, timeout=90) as response:
            payload = response.read()
        if hashlib.sha256(payload).hexdigest() != asset['sha256']:
            raise RuntimeError(name + ' archive checksum mismatch')
        archive.write_bytes(payload)
    payload = archive.read_bytes()
    assert hashlib.sha256(payload).hexdigest() == asset['sha256']
    suffix = '.exe' if a.target.startswith('windows') else ''
    binary = name + suffix
    members = {}
    if archive.name.endswith('.zip'):
        with zipfile.ZipFile(io.BytesIO(payload)) as z:
            members = {Path(x.filename).name: z.read(x) for x in z.infolist() if not x.is_dir()}
    elif archive.name.endswith('.tar.gz'):
        with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as t:
            members = {Path(x.name).name: t.extractfile(x).read() for x in t if x.isfile()}
    else:
        members[binary] = gzip.decompress(payload)
    candidates = [v for k, v in members.items() if k == binary or name == 'mihomo' and k.startswith('mihomo') and k.endswith(suffix)]
    if len(candidates) != 1:
        raise RuntimeError('Ambiguous core archive: ' + name)
    target = a.output / binary
    target.write_bytes(candidates[0]); target.chmod(0o755)
    for filename, content in members.items():
        if filename.endswith(('.dll', '.dylib', '.so')):
            (a.output / filename).write_bytes(content)
    license_text = members.get('LICENSE')
    if license_text is None:
        with urllib.request.urlopen(entry['license'], context=context, timeout=30) as response:
            license_text = response.read()
    (a.output / (name + '-LICENSE.txt')).write_bytes(license_text)
    (a.output / (name + '-SOURCE.txt')).write_text(
        name + ' ' + entry['version'] + '\nSource: ' + entry['source'] + '\nBinary: ' + asset['url'] + '\nArchive SHA256: ' + asset['sha256'] + '\nUnmodified upstream binary.\n', encoding='utf-8')
    print(name + ' ' + entry['version'] + ': verified ' + str(target))
