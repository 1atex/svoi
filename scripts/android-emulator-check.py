import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'dev.svoi.app.preview'


def run(*args, cwd=ROOT, timeout=90):
    subprocess.run(args, cwd=cwd, check=True, timeout=timeout)


def stored_profiles():
    data = subprocess.check_output(['adb', 'shell', 'run-as', PACKAGE, 'cat', 'files/groups.json'])
    return hashlib.sha256(data).hexdigest()


try:
    run('adb', 'install', '-r', str(ROOT / '.tools/android-debug.apk'))
    run('adb', 'shell', 'appops', 'set', PACKAGE, 'ACTIVATE_VPN', 'allow')
    run('adb', 'shell', 'appops', 'set', PACKAGE, 'REQUEST_INSTALL_PACKAGES', 'allow')
    run('./gradlew', ':app:assembleDebugAndroidTest', '-Ptarget-platform=android-x64', cwd=ROOT / 'flutter_client/android', timeout=240)
    run('adb', 'install', '-r', str(ROOT / 'flutter_client/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk'))
    with open('/tmp/svoi-instrumentation.log', 'w', encoding='utf-8') as output:
        result = subprocess.run(['adb', 'shell', 'am', 'instrument', '-w', '-r', PACKAGE + '.test/androidx.test.runner.AndroidJUnitRunner'], stdout=output, stderr=subprocess.STDOUT, timeout=180)
    transcript = Path('/tmp/svoi-instrumentation.log').read_text(encoding='utf-8')
    print(transcript, flush=True)
    passed = re.search(r'OK \((\d+) tests?\)', transcript)
    if result.returncode != 0 or not passed or int(passed.group(1)) < 5 or 'INSTRUMENTATION_CODE: -1' not in transcript:
        raise RuntimeError('Android instrumentation tests did not pass')
    run('adb', 'shell', 'appops', 'set', PACKAGE, 'REQUEST_INSTALL_PACKAGES', 'deny')
    denied = subprocess.run(['adb', 'shell', 'am', 'instrument', '-w', '-r', '-e', 'class', 'dev.svoi.app.UpdateTest#persistedApkIsVerifiedBeforeNetworkCheckAndInstallerGetsContentUri', '-e', 'installAllowed', 'false', PACKAGE + '.test/androidx.test.runner.AndroidJUnitRunner'], capture_output=True, text=True, timeout=60)
    with open('/tmp/svoi-instrumentation.log', 'a', encoding='utf-8') as output:
        output.write(denied.stdout + denied.stderr)
    print(denied.stdout, flush=True)
    if denied.returncode != 0 or not re.search(r'OK \(1 tests?\)', denied.stdout) or 'INSTRUMENTATION_CODE: -1' not in denied.stdout:
        raise RuntimeError('Installer permission-denied test did not pass')
    run('adb', 'shell', 'am', 'force-stop', PACKAGE)
    before = stored_profiles()
    run('adb', 'install', '-r', str(ROOT / 'flutter_client/android/app/src/androidTest/assets/update.apk'))
    expected = json.loads((ROOT / 'config/android-release.json').read_text())['versionCode'] + 1
    installed = subprocess.check_output(['adb', 'shell', 'dumpsys', 'package', PACKAGE], text=True)
    if f'versionCode={expected} ' not in installed:
        raise RuntimeError('New APK version was not installed')
    if stored_profiles() != before:
        raise RuntimeError('Profiles changed during in-place APK update')
    print('Verified in-place APK update: saved profiles unchanged', flush=True)
finally:
    with open('/tmp/svoi-android-resources.log', 'wb') as log:
        subprocess.run(['adb', 'logcat', '-d'], stdout=log, check=False, timeout=20)
