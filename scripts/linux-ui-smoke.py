import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

bundle = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='svoi-linux-ui-') as data:
    env = dict(os.environ, SVOI_DATA=data, LIBGL_ALWAYS_SOFTWARE='1', GDK_BACKEND='x11')
    with open(output / 'linux-ui.log', 'w') as log:
        wm = subprocess.Popen(['openbox', '--sm-disable'], env=env, stdout=log, stderr=log)
        time.sleep(.7)
        app = subprocess.Popen([str(bundle / 'svoi')], env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 35
            while time.monotonic() < deadline:
                if app.poll() is not None: raise RuntimeError('GUI exited before first frame')
                result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name', '^SVOI$'], capture_output=True, text=True)
                if result.returncode == 0 and Path(data, 'session.json').exists(): break
                time.sleep(.3)
            else: raise RuntimeError('GUI did not become ready')
            window = result.stdout.splitlines()[0]
            time.sleep(2)
            second = subprocess.run([str(bundle / 'svoi')], env=env, stdout=log, stderr=log, timeout=10)
            assert second.returncode == 0, 'Second launch did not reuse the existing window'
            subprocess.run(['scrot', '--overwrite', str(output / 'linux-first-run.png')], check=True)
            children = subprocess.check_output(['pgrep', '-P', str(app.pid)], text=True).split()
            assert children, 'Native backend was not started'
            subprocess.run(['xdotool', 'windowactivate', '--sync', window], check=True)
            subprocess.run(['xdotool', 'key', '--clearmodifiers', 'alt+F4'], check=True)
            app.wait(timeout=15)
            assert app.returncode == 0, app.returncode
            for child in children:
                assert not Path('/proc', child).exists(), 'Backend remains after GUI close'
            assert not list(Path(data).glob('*.tmp'))
            print('PASS: GTK launch, first-run data, native window close and backend cleanup')
        finally:
            if app.poll() is None: app.terminate(); app.wait(timeout=10)
            wm.terminate(); wm.wait(timeout=10)
