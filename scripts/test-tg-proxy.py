import json
import queue
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def main():
    executable = Path(sys.argv[1]).resolve()
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    with tempfile.TemporaryDirectory() as folder:
        config = Path(folder) / 'config.json'
        config.write_text(json.dumps({'port': port, 'secret': secrets.token_hex(16)}))
        for _ in range(2):
            lines = queue.Queue()
            process = subprocess.Popen([str(executable), '--config', str(config)],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, text=True)
            def read():
                for line in process.stdout:
                    lines.put(line.strip())
            threading.Thread(target=read, daemon=True).start()
            try:
                deadline = time.monotonic() + 25
                ready = False
                while time.monotonic() < deadline and process.poll() is None:
                    try:
                        if lines.get(timeout=.2) == 'SVOI_TG_READY':
                            ready = True
                            break
                    except queue.Empty:
                        pass
                assert ready, 'Helper did not confirm its listener'
                with socket.create_connection(('127.0.0.1', port), timeout=2):
                    pass
                process.stdin.close()
                assert process.wait(timeout=8) == 0, 'Helper did not stop cleanly'
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
    print('tg-ws-proxy: packaged listener, graceful shutdown and restart passed')


if __name__ == '__main__':
    main()
