import json
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import time

helper = str(Path(sys.argv[1]).resolve())
subprocess.run([helper, '--self-test'], check=True)

def proxy_settings():
    with open('/Library/Preferences/SystemConfiguration/preferences.plist', 'rb') as stream:
        return plistlib.load(stream).get('NetworkServices', {})

def check_settings(expected):
    keys = {'HTTPEnable', 'HTTPProxy', 'HTTPPort', 'HTTPSEnable', 'HTTPSProxy',
            'HTTPSPort', 'ProxyAutoConfigEnable', 'ProxyAutoDiscoveryEnable', 'SOCKSEnable'}
    deadline = time.monotonic() + 4
    while True:
        services = proxy_settings()
        if all({k: v for k, v in services.get(service, {}).get('Proxies', {}).items() if k in keys}
               == {k: v for k, v in value.items() if k in keys}
               for service, value in expected.items()):
            return
        if time.monotonic() >= deadline:
            raise AssertionError('system proxy configuration did not match the expected values')
        time.sleep(0.1)

with tempfile.TemporaryDirectory(prefix='svoi-broker-') as folder:
    process = subprocess.Popen([helper, 'broker'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    def call(operation, **values):
        process.stdin.write(json.dumps({'operation': operation, **values}) + '\n')
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        assert response['pid'] == process.pid, response
        return response
    try:
        for operation in ['ping', 'stop', 'recover', 'invalid', 'ping']:
            response = call(operation, directory=folder)
            assert response['ready'] == (operation != 'invalid'), response
            assert response['authorizationRequests'] == 0, 'read-only operations requested authorization'
        if '--apply' in sys.argv:
            assert os.geteuid() == 0, 'apply test is only intended for the disposable CI runner under sudo'
            snapshot = Path(folder) / 'macos-proxy.plist'
            before = None
            for cycle in range(3):
                response = call('start', directory=folder, port=12345 + cycle)
                assert response['ready'] and response['authorizationRequests'] == 1, response
                with snapshot.open('rb') as stream:
                    state = plistlib.load(stream)
                before = state['original']
                check_settings(state['expected'])
                response = call('stop', directory=folder)
                assert response['ready'] and response['authorizationRequests'] == 1, response
                assert not snapshot.exists(), 'stop did not remove the restored snapshot'
                check_settings(before)
            response = call('start', directory=folder, port=12349)
            assert response['ready'] and response['authorizationRequests'] == 1, response
            with snapshot.open('rb') as stream:
                before = plistlib.load(stream)['original']
            process.stdin.close()
            assert process.wait(timeout=15) == 0, 'broker failed to restore on parent EOF'
            assert not snapshot.exists(), 'parent EOF left an active proxy snapshot'
            check_settings(before)
    finally:
        if process.poll() is None:
            try:
                response = call('stop', directory=folder)
                assert response['ready'], response
            finally:
                process.stdin.close()
                process.wait(timeout=15)
        process.stdout.close()

for normal_close in [False, True]:
    child = subprocess.Popen(['/bin/sleep', '60'], start_new_session=True)
    watcher = subprocess.Popen([helper, 'watch', str(child.pid)], stdin=subprocess.PIPE)
    try:
        if normal_close:
            watcher.stdin.write(b'release\n')
        watcher.stdin.close()
        assert watcher.wait(timeout=4) == 0
        if normal_close:
            assert child.poll() is None, 'normal release killed an unrelated living process'
        else:
            assert child.wait(timeout=4) == -15, 'orphan Xray process was not terminated'
    finally:
        if child.poll() is None:
            child.terminate()
        child.wait(timeout=4)
        if watcher.poll() is None:
            watcher.kill()
            watcher.wait()
with tempfile.TemporaryDirectory(prefix='svoi-proxy-') as folder:
    result = subprocess.run([helper, 'recover', folder], capture_output=True)
    assert result.returncode == 0
    snapshot = Path(folder) / 'macos-proxy.plist'
    snapshot.write_bytes(b'invalid snapshot')
    result = subprocess.run([helper, 'recover', folder], capture_output=True)
    assert result.returncode != 0 and json.loads(result.stdout)['error']
    assert snapshot.read_bytes() == b'invalid snapshot', 'failed recovery deleted its evidence'
print('PASS: persistent proxy broker, authorization reuse, safe recovery, orphan cleanup, normal release')
