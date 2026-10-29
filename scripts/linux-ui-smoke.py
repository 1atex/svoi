import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def capture_native_crash(app, bundle, output):
    """Inspect an already exited process without changing its close timing."""
    if app.returncode is None or app.returncode >= 0:
        return
    core_directory = os.environ.get('SVOI_LINUX_CORE_DIR')
    with open(output / 'linux-close-backtrace.log', 'w') as diagnostic:
        diagnostic.write(f'GUI PID {app.pid} exited with signal {-app.returncode}\n')
        if not core_directory:
            diagnostic.write('SVOI_LINUX_CORE_DIR is not configured; no core dump available.\n')
            return
        core = Path(core_directory).resolve() / f'core.{app.pid}'
        if not core.is_file():
            diagnostic.write(f'Expected core dump was not produced: {core.name}\n')
            return
        try:
            diagnostic.flush()
            subprocess.run(['gdb', '--batch', '-ex', 'set pagination off',
                '-ex', 'info sharedlibrary', '-ex', 'thread apply all bt',
                str(bundle / 'svoi'), str(core)], stdout=diagnostic,
                stderr=subprocess.STDOUT, timeout=60, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            diagnostic.write(f'Core analysis failed: {error}\n')
        finally:
            # Only remove this process's generated dump, never a glob or a
            # directory. Diagnostics must not upload a multi-gigabyte core.
            core.unlink(missing_ok=True)


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
            subprocess.run(['xdotool', 'windowactivate', '--sync', window], check=True)
            subprocess.run(['xdotool', 'key', '--clearmodifiers', 'alt+F4'], check=True)
            app.wait(timeout=15)
            assert app.returncode == 0, app.returncode
            for child in children:
                assert not Path('/proc', child).exists(), 'Backend remains after GUI close'
            assert not list(Path(data).glob('*.tmp'))
            print('PASS: GTK launch, first-run onboarding, persisted completion, native window close and backend cleanup')
        finally:
            capture_native_crash(app, bundle, output)
            if app.poll() is None: app.terminate(); app.wait(timeout=10)
            wm.terminate(); wm.wait(timeout=10)
