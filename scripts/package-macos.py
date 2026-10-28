import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

app = Path(sys.argv[1]).resolve()
version = sys.argv[2]
root = Path(__file__).resolve().parent.parent
output = root / 'releases' / f'macos-v{version}'
output.mkdir(parents=True, exist_ok=True)
dmg = output / f'SVOI-{version}-macos-arm64.dmg'
if dmg.exists():
    raise SystemExit('DMG already exists; keep published packages immutable or choose a new version.')
with tempfile.TemporaryDirectory(prefix='svoi-dmg-') as folder:
    staging = Path(folder)
    subprocess.run(['ditto', str(app), str(staging / 'SVOI.app')], check=True)
    (staging / 'Applications').symlink_to('/Applications')
    shutil.copy2(root / 'docs' / 'MACOS.md', staging / 'MACOS.md')
    subprocess.run(['hdiutil', 'create', '-volname', 'SVOI', '-srcfolder', str(staging), '-format', 'UDZO', str(dmg)], check=True)
digest = hashlib.file_digest(dmg.open('rb'), 'sha256').hexdigest()
dmg.with_suffix('.dmg.sha256').write_text(f'{digest}  {dmg.name}\n')
print(dmg)
