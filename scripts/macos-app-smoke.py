import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

app = Path(sys.argv[1]).resolve()
diagnostics = Path(sys.argv[2]).resolve()
diagnostics.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='svoi-real-app-') as folder:
    data = Path(folder)
    with (diagnostics / 'native-app.log').open('w') as log:
        process = subprocess.Popen([str(app / 'Contents/MacOS/SVOI')], env=dict(os.environ, SVOI_DATA=str(data)), stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 35
            while time.monotonic() < deadline and process.poll() is None:
                if (data / 'session.json').exists():
                    break
                time.sleep(.2)
            assert process.poll() is None, f'app exited: {process.returncode}'
            state = json.loads((data / 'groups.json').read_text())
            session = json.loads((data / 'session.json').read_text())
            assert len(state['groups']) == 1 and state['groups'][0]['identity']['os'] == 'macOS'
            assert session['mode'] == 'system' and session['token']
            backend = int(subprocess.check_output(['pgrep', '-P', str(process.pid), '-x', 'svoi-backend'], text=True).strip())
            subprocess.run(['screencapture', '-x', str(diagnostics / 'native-app.png')], check=True)
            subprocess.run(['osascript', '-e', 'tell application id "dev.svoi.app.macos" to quit'], check=True, timeout=20)
            assert process.wait(timeout=15) == 0
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    os.kill(backend, 0)
                except ProcessLookupError:
                    break
                time.sleep(.1)
            else:
                raise AssertionError('backend survived normal application quit')
            print('PASS: real app, bundled backend IPC, macOS profile identity, persisted default mode, clean quit')
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
