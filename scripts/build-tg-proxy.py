import hashlib
import json
import shutil
import ssl
import subprocess
import sys
import urllib.request
import venv
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIN = json.loads((ROOT / 'config/tg-proxy.json').read_text())
WORK = ROOT / '.tools/tg-proxy-build'


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    if sys.platform != 'win32':
        raise SystemExit('This helper is packaged for Windows only')
    WORK.mkdir(parents=True, exist_ok=True)
    archive = WORK / 'source.zip'
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != PIN['sha256']:
        context = ssl.create_default_context()
        try:
            import certifi
            context = ssl.create_default_context(cafile=certifi.where())
        except ImportError:
            pass
        url = f"https://codeload.github.com/Flowseal/tg-ws-proxy/zip/{PIN['commit']}"
        with urllib.request.urlopen(url, context=context, timeout=60) as response:
            archive.write_bytes(response.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != PIN['sha256']:
        raise SystemExit('tg-ws-proxy source checksum mismatch')
    with zipfile.ZipFile(archive) as source:
        source.extractall(WORK)
    source = WORK / f"tg-ws-proxy-{PIN['commit']}"
    python = WORK / 'venv/Scripts/python.exe'
    if not python.exists():
        venv.create(WORK / 'venv', with_pip=True)
    run(python, '-m', 'pip', 'install', '--disable-pip-version-check',
        'pyinstaller==6.16.0', 'cryptography==46.0.5', 'httpx[http2]==0.28.1', 'certifi==2026.2.25')
    run(python, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--console',
        '--name', 'tg-ws-proxy', '--paths', source, '--distpath', WORK / 'dist',
        '--workpath', WORK / 'build', '--specpath', WORK,
        ROOT / 'scripts/tg-proxy-runner.py')
    bundle = WORK / 'dist/tg-ws-proxy'
    shutil.copy2(source / 'LICENSE', bundle / 'LICENSE-tg-ws-proxy.txt')
    (bundle / 'SOURCE.txt').write_text(
        f"Flowseal/tg-ws-proxy {PIN['version']}\nhttps://github.com/Flowseal/tg-ws-proxy\n"
        f"Commit: {PIN['commit']}\nSource SHA256: {PIN['sha256']}\n"
        'SVOI adds a headless lifecycle wrapper; upstream proxy code is unchanged.\n', encoding='utf-8')
    destination = ROOT / 'core/tg-ws-proxy'
    if destination.exists():
        if destination.resolve().parent != (ROOT / 'core').resolve():
            raise SystemExit('Unexpected destination')
        shutil.rmtree(destination)
    shutil.copytree(bundle, destination)
    run(python, ROOT / 'scripts/test-tg-proxy.py', destination / 'tg-ws-proxy.exe')


if __name__ == '__main__':
    main()
