import argparse
import http.server
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('bundle', type=Path)
parser.add_argument('--tun', action='store_true')
args = parser.parse_args()
bundle = args.bundle.resolve()

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'svoi-linux-fixture'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *unused): pass

server = http.server.ThreadingHTTPServer(('0.0.0.0', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
client_id = '90e3da82-374e-46ef-9099-761d39b86b82'
with tempfile.TemporaryDirectory(prefix='svoi-linux-smoke-') as folder:
    folder = Path(folder)
    upstream_port = port()
    config = folder / 'server.json'
    config.write_text(json.dumps({'log': {'loglevel': 'warning'}, 'inbounds': [{'listen': '127.0.0.1', 'port': upstream_port, 'protocol': 'vless', 'settings': {'clients': [{'id': client_id}], 'decryption': 'none'}}], 'outbounds': [{'protocol': 'freedom', 'settings': dict({'finalRules': [{'action': 'allow', 'ip': ['127.0.0.1']}]}, **({'redirect': f'127.0.0.1:{server.server_port}'} if args.tun else {}))}]}))
    log = open(folder / 'service.log', 'w+')
    upstream = subprocess.Popen([str(bundle / 'backend/core/xray'), 'run', '-config', str(config)], stdout=log, stderr=log)
    service = subprocess.Popen([str(bundle / 'backend/svoi-backend'), '-native-backend', '-listen', '127.0.0.1:0', '-data', str(folder / 'groups.json')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
    try:
        ready = json.loads(service.stdout.readline())
        assert ready['address'].startswith('http://127.0.0.1:')
        token = ''
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        def api(path, data=None, method=None):
            headers = {'X-SVOI-Backend': ready['key'], 'Content-Type': 'application/json'}
            if token: headers['Authorization'] = 'Bearer ' + token
            request = urllib.request.Request(ready['address'] + '/api/' + path, data=json.dumps(data).encode() if data is not None else None, headers=headers, method=method)
            with opener.open(request, timeout=20) as response: return json.load(response)
        assert opener.open(f'http://127.0.0.1:{server.server_port}/', timeout=3).read() == b'svoi-linux-fixture'
        group = api('groups', {'name': 'Linux smoke', 'deviceName': 'Test PC', 'platform': 'Linux'})
        token = group['token']
        assert group['group']['identity']['os'] == 'Linux'
        content = f'vless://{client_id}@127.0.0.1:{upstream_port}?security=none&type=tcp#Fixture'
        if args.tun:
            content = json.dumps({'remarks': 'Isolated TUN fixture', 'outbounds': [{'tag': 'proxy', 'protocol': 'vless', 'settings': {'vnext': [{'address': '127.0.0.1', 'port': upstream_port, 'users': [{'id': client_id, 'encryption': 'none'}]}]}, 'streamSettings': {'network': 'tcp', 'sockopt': {'interface': 'lo'}}}]})
        group = api('subscription/import', {'content': content})
        server_id = group['servers'][0]['id']
        mode = 'tun' if args.tun else 'local'
        if args.tun:
            assert api('connection')['elevated'], 'Xray network capabilities unavailable'
        for cycle in range(5):
            state = api('connection/start', {'serverId': server_id, 'mode': mode})
            assert state['state'] == 'running', state
            if args.tun:
                target = f'http://198.18.0.1:{server.server_port}/'
                request_opener = opener
            else:
                target = f'http://127.0.0.1:{server.server_port}/'
                proxy = http.client.HTTPConnection('127.0.0.1', state['httpPort'], timeout=10)
                proxy.set_tunnel('127.0.0.1', server.server_port)
                proxy.request('GET', '/', headers={'Connection': 'close'})
                assert proxy.getresponse().read() == b'svoi-linux-fixture'
                proxy.close()
            if args.tun:
                with request_opener.open(target, timeout=10) as response:
                    assert response.read() == b'svoi-linux-fixture'
            stopped = api('connection/stop', {}, 'POST')
            assert stopped['state'] == 'stopped' and stopped['httpPort'] == 0, stopped
            if args.tun:
                links = subprocess.check_output(['ip', '-o', 'link', 'show'], text=True)
                assert 'SVOI:' not in links, 'TUN interface remains after stop'
        api('connection/start', {'serverId': server_id, 'mode': mode})
        service.stdin.close()
        service.wait(timeout=12)
        assert service.returncode == 0
        assert not list((folder / 'runtime').glob('xray-*.json'))
        print(f'PASS: {mode}, 5 reconnects, HTTP traffic, shutdown cleanup')
    except Exception:
        try:
            print(api('connection?logs=1'))
        except Exception: pass
        log.flush(); log.seek(0); print(log.read()); raise
    finally:
        if service.poll() is None:
            service.stdin.close(); service.wait(timeout=12)
        upstream.send_signal(signal.SIGINT)
        upstream.wait(timeout=10)
        log.close()
server.shutdown()
