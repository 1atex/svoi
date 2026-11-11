import concurrent.futures
import http.server
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

root = Path(__file__).resolve().parents[1]
bundle = Path(sys.argv[1]).resolve()
island = Path(sys.argv[2]).resolve()
data = Path(sys.argv[sys.argv.index('--fixture-dir') + 1]).resolve() if '--fixture-dir' in sys.argv else root / '.ui-preview/night-island-qa'
assert data.is_relative_to(root / '.ui-preview')
data.mkdir(parents=True, exist_ok=True)
assert not (data / 'groups.json').exists(), 'Use a fresh fixture directory'


class Target(http.server.BaseHTTPRequestHandler):
    hits = 0

    def do_GET(self):
        type(self).hits += 1
        time.sleep(0.15)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


def port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


target = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Target)
threading.Thread(target=target.serve_forever, daemon=True).start()
url = 'http://127.0.0.1:' + str(target.server_port) + '/health'
ports = [port(), port()]
uuid = '22fdab02-e8d0-4b10-9c45-77c53d9aa721'
config = {
    'log': {'loglevel': 'warning'},
    'inbounds': [{'listen': '127.0.0.1', 'port': value, 'protocol': 'vless', 'settings': {'clients': [{'id': uuid}], 'decryption': 'none'}} for value in ports],
    'outbounds': [{'protocol': 'freedom', 'settings': {'finalRules': [{'action': 'allow', 'ip': ['127.0.0.1']}]}}],
}
(data / 'fixture-xray.json').write_text(json.dumps(config), encoding='utf-8')
core = subprocess.Popen([str(bundle / 'backend/core/xray.exe'), 'run', '-c', str(data / 'fixture-xray.json')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
backend = None
reports = []


def check(name, condition):
    assert condition, name
    reports.append(name)
    print('PASS:', name, flush=True)


def start_backend():
    global backend, ready
    backend = subprocess.Popen([str(bundle / 'backend/svoi-backend.exe'), '-native-backend', '-desktop-exe', str(bundle / 'svoi.exe'), '-listen', '127.0.0.1:0', '-data', str(data / 'groups.json')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    ready = json.loads(backend.stdout.readline())


def stop_backend():
    global backend
    if backend is not None:
        backend.stdin.close()
        backend.wait(timeout=10)
        backend = None


def api(path, method='GET', body=None, authenticated=True):
    headers = {'X-SVOI-Backend': ready['key']}
    if authenticated:
        headers['Authorization'] = 'Bearer ' + token
    if body is not None:
        headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(ready['address'] + '/api/' + path, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def rpc(action='state', server_id=''):
    result = subprocess.run([str(island), '--svoi-integration-check', action, server_id], capture_output=True, timeout=45)
    assert result.returncode == 0, 'Island CLI failed'
    return json.loads(result.stdout.decode('utf-8'))


try:
    (data / 'groups.json.settings.json').write_text(json.dumps({'autoUpdate': False, 'autoDownload': False, 'autoRefresh': False, 'routing': {'mode': 'all', 'processes': []}}), encoding='utf-8')
    check('SVOI closed is distinct from disabled', rpc()['access'] == 'closed')
    start_backend()
    group = api('groups', 'POST', {'name': 'Night Island QA', 'deviceName': 'QA Windows', 'platform': 'Windows'}, False)
    token = group['token']
    lines = ['vless://' + uuid + '@127.0.0.1:' + str(value) + '?encryption=none#' + urllib.parse.quote(name) for value, name in zip(ports, ['QA · Финляндия', 'QA · Германия'])]
    lines.append('vless://' + uuid + '@127.0.0.1:1?security=reality&pbk=not-a-valid-key&sni=example.test#QA-broken')
    group = api('subscription/import', 'POST', {'content': '\n'.join(lines)})
    nodes = group['servers']
    assert len(nodes) == 3
    ids = [entry['id'] for entry in nodes]
    api('settings', 'PUT', {'autoUpdate': False, 'autoDownload': False, 'autoRefresh': False, 'routing': {'mode': 'all', 'processes': []}, 'probe': {'url': url, 'urlSource': 'custom', 'timeoutSeconds': 2, 'parallel': 2}})
    view = {'selected': ids[0], 'mode': 'local', 'favorites': ids[:2], 'servers': ids, 'revision': 1}
    api('night-island/context', 'POST', view)
    denied = rpc()
    check('control is disabled by default and no private server data is returned', denied['access'] == 'denied' and not denied.get('favorites') and not denied.get('active'))
    candidate = api('night-island')['candidate']
    api('night-island', 'PUT', {'enabled': True, 'candidate': candidate})
    check('permission grants the exact observed Island executable', rpc()['access'] == 'allowed')
    rogue = data / 'unapproved' / 'night-island.exe'
    rogue.parent.mkdir(exist_ok=True)
    shutil.copy2(island, rogue)
    with rogue.open('ab') as output:
        output.write(b'unapproved-build-probe')
    result = subprocess.run([str(rogue), '--svoi-integration-check', 'state'], capture_output=True, timeout=10)
    unapproved = json.loads(result.stdout.decode('utf-8'))
    check('another process with the same filename cannot reuse the permission', unapproved['access'] != 'allowed' and not unapproved.get('favorites'))
    rpc()
    with concurrent.futures.ThreadPoolExecutor() as pool:
        first = pool.submit(rpc, 'connect')
        time.sleep(0.03)
        second = pool.submit(rpc, 'connect')
        results = [first.result(), second.result()]
    state = rpc()
    check('double connect yields one running connection', state['active']['id'] == ids[0] and state['verified'] and any(result.get('busy') for result in results))
    start = state['startedAt']
    state = rpc('connect')
    check('repeated connect does not restart the active server', state['startedAt'] == start)
    state = rpc('switch', ids[1])
    check('favorite switch succeeds through real Xray and real HTTP check', state['active']['id'] == ids[1] and state['verified'] and state['latency'] >= 0 and Target.hits >= 2)
    check('SVOI backend agrees with Island', api('connection')['serverId'] == state['active']['id'])
    bad = rpc('switch', ids[2])
    check('failed core validation reports the actually active server', bad['active']['id'] == ids[1] and bad.get('error'))
    api('connection/start', 'POST', {'serverId': ids[0], 'mode': 'local'})
    api('connection/check', 'POST')
    state = rpc()
    check('switch via SVOI is reflected by Island', state['active']['id'] == ids[0] and state['verified'])
    state = rpc('disconnect')
    check('disconnect clears active server and measured latency', state['state'] == 'stopped' and not state.get('active') and not state.get('latency'))
    api('night-island', 'PUT', {'enabled': False})
    check('permission revocation immediately denies subsequent control', rpc('connect')['access'] == 'denied' and api('connection')['state'] == 'stopped')
    rpc()
    api('night-island', 'PUT', {'enabled': True, 'candidate': api('night-island')['candidate']})
    stop_backend()
    check('closing SVOI returns closed instead of disconnected', rpc()['access'] == 'closed')
    start_backend()
    view['revision'] = 2
    api('night-island/context', 'POST', view)
    state = rpc()
    check('restart preserves local permission without inventing a connection', state['access'] == 'allowed' and state['state'] == 'stopped' and not state['verified'])
    serialized = json.dumps(state)
    check('IPC omits backend key, token, subscription URL and full configurations', all(value not in serialized for value in [ready['key'], token, uuid, 'outbounds', '127.0.0.1']))
    fixture = {'token': token, 'selected': ids[0], 'mode': 'local', 'sessions': [{'token': token, 'name': 'Night Island QA'}], 'libraries': {group['id']: {'favorites': ids[:2], 'lastUsed': ids[0]}}}
    (data / 'session.json').write_text(json.dumps(fixture, ensure_ascii=False), encoding='utf-8')
    (data / 'release-notice.json').write_text(json.dumps({'onboardingVersion': '0.7.1-rc.3', 'version': '0.7.1-rc.3'}), encoding='utf-8')
    stop_backend()
    (data / 'test-report.json').write_text(json.dumps({'passed': reports, 'liveExternalVpn': False, 'transport': 'Windows named pipe, real two-binary IPC', 'traffic': 'real Xray VLESS between localhost endpoints; HTTP 204 through proxy'}, ensure_ascii=False, indent=2), encoding='utf-8')
    if '--ui-fixture' in sys.argv:
        print('UI fixture ready:', data, flush=True)
        end = time.monotonic() + 1800
        while time.monotonic() < end and not (data / 'ui.stop').exists():
            time.sleep(0.25)
finally:
    stop_backend()
    target.shutdown()
    core.terminate()
    core.wait(timeout=5)
