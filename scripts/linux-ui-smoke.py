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
version = json.loads((Path(__file__).resolve().parents[1] / 'config/linux-release.json').read_text())['version']
with tempfile.TemporaryDirectory(prefix='svoi-linux-ui-') as data:
    env = dict(os.environ, SVOI_DATA=data, LIBGL_ALWAYS_SOFTWARE='1', GDK_BACKEND='x11')
    with open(output / 'linux-ui.log', 'w') as log:
        wm = subprocess.Popen(['openbox', '--sm-disable'], env=env, stdout=log, stderr=log)
        time.sleep(.7)
        app = subprocess.Popen([str(bundle / 'svoi')], env=env, stdout=log, stderr=log)
        debugger = None
        debug_log = None
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
            subprocess.run(['scrot', '--overwrite', str(output / 'linux-onboarding.png')], check=True)
            subprocess.run(['xdotool', 'windowactivate', '--sync', window], check=True)
            subprocess.run(['xdotool', 'key', '--clearmodifiers', 'Escape'], check=True)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    notice = json.loads(Path(data, 'release-notice.json').read_text())
                    if notice.get('onboardingVersion') == version:
                        break
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                if app.poll() is not None:
                    raise RuntimeError('GUI exited while skipping onboarding')
                time.sleep(.1)
            else:
                raise RuntimeError('First-run onboarding did not persist its completion')
            second = subprocess.run([str(bundle / 'svoi')], env=env, stdout=log, stderr=log, timeout=10)
            assert second.returncode == 0, 'Second launch did not reuse the existing window'
            subprocess.run(['scrot', '--overwrite', str(output / 'linux-first-run.png')], check=True)
            children = subprocess.check_output(['pgrep', '-P', str(app.pid)], text=True).split()
            assert children, 'Native backend was not started'
            if os.environ.get('SVOI_LINUX_DEBUG_CLOSE') == '1':
                debug_log = open(output / 'linux-close-backtrace.log', 'w')
                debugger = subprocess.Popen(['sudo', '-n', 'gdb', '--batch', '-p', str(app.pid),
                    '-ex', 'set pagination off', '-ex', 'continue', '-ex', 'thread apply all bt',
                    '-ex', 'kill'], stdout=debug_log, stderr=debug_log)
                time.sleep(2)
            subprocess.run(['xdotool', 'windowactivate', '--sync', window], check=True)
            subprocess.run(['xdotool', 'key', '--clearmodifiers', 'alt+F4'], check=True)
            app.wait(timeout=15)
            assert app.returncode == 0, app.returncode
            if debugger is not None:
                debugger.wait(timeout=10)
                debug_log.flush()
                trace = (output / 'linux-close-backtrace.log').read_text()
                assert 'received signal' not in trace, 'Native crash captured by debugger'
            for child in children:
                assert not Path('/proc', child).exists(), 'Backend remains after GUI close'
            assert not list(Path(data).glob('*.tmp'))
            print('PASS: GTK launch, first-run onboarding, persisted completion, native window close and backend cleanup')
        finally:
            if debugger is not None:
                try: debugger.wait(timeout=10)
                except subprocess.TimeoutExpired: debugger.terminate(); debugger.wait(timeout=5)
            if debug_log is not None: debug_log.close()
            if app.poll() is None: app.terminate(); app.wait(timeout=10)
            wm.terminate(); wm.wait(timeout=10)
