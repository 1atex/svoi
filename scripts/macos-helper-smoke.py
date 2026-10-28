import json
from pathlib import Path
import subprocess
import sys
import tempfile

helper = str(Path(sys.argv[1]).resolve())
subprocess.run([helper, '--self-test'], check=True)
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
print('PASS: proxy state, orphan cleanup, normal release, safe recovery failure')
