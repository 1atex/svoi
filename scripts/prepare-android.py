from pathlib import Path
import hashlib
import urllib.request
import zipfile

root = Path(__file__).resolve().parents[1]
cache = root / ".tools/android-core"
cache.mkdir(parents=True, exist_ok=True)
archive = cache / "xray.zip"
sha = "0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978"
if not archive.exists():
    urllib.request.urlretrieve("https://github.com/XTLS/Xray-core/releases/download/v26.10.21/Xray-linux-64.zip", archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != sha:
    raise RuntimeError("Xray archive checksum mismatch")
target = root / "flutter_client/android/app/src/main/assets/core"
target.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(archive) as bundle:
    for name in ("geoip.dat", "geosite.dat", "LICENSE"):
        (target / name).write_bytes(bundle.read(name))
    executable = cache / "xray"
    executable.write_bytes(bundle.read("xray"))
    executable.chmod(0o755)
