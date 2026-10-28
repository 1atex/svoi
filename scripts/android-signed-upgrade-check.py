import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'config/android-release.json').read_text())
PACKAGE = CONFIG['packageName']


def run(*args):
    return subprocess.check_output(args, text=True, timeout=90)


if os.environ.get('GITHUB_ACTIONS') != 'true':
    raise RuntimeError('Run only in the disposable CI emulator')
previous = ROOT / '.tools/previous-release.apk'
urllib.request.urlretrieve('https://github.com/1atex/svoi/releases/download/android-v0.1.0-preview.8/SVOI-Android-0.1.0-preview.8-x64.apk', previous)
current = next((ROOT / '.tools/android-release').glob('*-x64.apk'))
signer = str(Path(os.environ['ANDROID_HOME']) / 'build-tools/36.0.0/apksigner')
for file in (previous, current):
    certs = run(signer, 'verify', '--print-certs', str(file))
    if CONFIG['signingCertificateSha256'] not in certs:
        raise RuntimeError('Release signing certificate changed')
run('adb', 'uninstall', PACKAGE)
print(run('adb', 'install', str(previous)), flush=True)
before = run('adb', 'shell', 'dumpsys', 'package', PACKAGE)
if 'versionCode=8 ' not in before:
    raise RuntimeError('Previous release was not installed')
run('adb', 'shell', 'am', 'start', '-n', PACKAGE + '/dev.svoi.app.MainActivity')
time.sleep(5)
run('adb', 'logcat', '-c')
print(run('adb', 'install', '-r', str(current)), flush=True)
installed = run('adb', 'shell', 'dumpsys', 'package', PACKAGE)
if f"versionCode={CONFIG['versionCode']} " not in installed:
    raise RuntimeError('Signed in-place update failed')
run('adb', 'shell', 'am', 'start', '-n', PACKAGE + '/dev.svoi.app.MainActivity', '--ez', 'enable-software-rendering', 'true')
time.sleep(8)
run('adb', 'shell', 'pidof', PACKAGE)
log = run('adb', 'logcat', '-d')
Path('/tmp/svoi-release-smoke.log').write_text(log)
if 'FATAL EXCEPTION' in log or 'Fatal signal' in log:
    raise RuntimeError('Release crashed after upgrade')
with open('/tmp/svoi-release-screen.png', 'wb') as image:
    subprocess.run(['adb', 'exec-out', 'screencap', '-p'], stdout=image, check=True, timeout=20)
print('Permanent signature verified; public Preview 8 upgraded in place to ' + CONFIG['versionName'], flush=True)
