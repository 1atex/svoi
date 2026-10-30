import base64
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import urllib.parse
import urllib.request

BASE = 'https://api.github.com/repos/1atex/svoi'


def api(method, path, data=None):
    headers = {'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
               'Accept': 'application/vnd.github+json', 'User-Agent': 'SVOI-release'}
    if data is not None:
        raw = isinstance(data, bytes)
        headers['Content-Type'] = 'application/octet-stream' if raw else 'application/json'
        if not raw:
            data = json.dumps(data).encode()
    request = urllib.request.Request(path if path.startswith('https:') else BASE + path,
                                     data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=300) as response:
        return json.load(response)


run_id = os.environ['SVOI_LINUX_RUN_ID']
assert run_id.isdigit()
run = api('GET', '/actions/runs/' + run_id)
assert run['status'] == 'completed'
assert run['path'] == '.github/workflows/linux.yml'
tag = run['head_branch']
assert re.fullmatch(r'linux-v\d+\.\d+\.\d+(?:-[a-z]+\.\d+)?', tag)
ref = api('GET', '/git/ref/tags/' + tag)
assert ref['object']['sha'] == run['head_sha']
jobs = api('GET', f'/actions/runs/{run_id}/jobs?per_page=100')['jobs']
job = next(j for j in jobs if j['name'] == 'linux')
required = ('Verify tag and build packages', 'Check backend and interface',
            'Verify traffic, reconnects and window lifecycle', 'Verify Debian installation')
for name in required:
    assert next(s for s in job['steps'] if s['name'] == name)['conclusion'] == 'success', name
print('Verified source and all Linux release checks:', tag, flush=True)
if sys.argv[1] == '--validate-only':
    sys.exit(0)

version = tag.removeprefix('linux-v')
directory = Path(sys.argv[1])
names = [f'SVOI-{version}-linux-amd64.deb', f'SVOI-{version}-linux-x64.tar.gz']
files = []
for name in names:
    package = next(directory.rglob(name))
    checksum = package.with_name(name + '.sha256')
    assert hashlib.sha256(package.read_bytes()).hexdigest() == checksum.read_text().split()[0]
    files.extend((package, checksum))
notes = api('GET', '/contents/docs/LINUX-RELEASE-NOTES.md?ref=' + tag)
body = base64.b64decode(notes['content']).decode()
body += f'\nПакеты проверены в [сборке](https://github.com/1atex/svoi/actions/runs/{run_id}); публикация повторена после ошибки GitHub.\n'
releases = []
for page in range(1, 100):
    items = api('GET', f'/releases?per_page=100&page={page}')
    releases.extend(items)
    if len(items) < 100:
        break
release = next((r for r in releases if r['tag_name'] == tag), None)
if release is None:
    release = api('POST', '/releases', {'tag_name': tag, 'name': 'SVOI Linux ' + version,
        'target_commitish': run['head_sha'], 'body': body, 'draft': True,
        'prerelease': True, 'make_latest': 'false'})
assert release['draft'], 'Published releases must not be replaced'
assets = api('GET', f'/releases/{release["id"]}/assets')
for path in files:
    data = path.read_bytes()
    digest = 'sha256:' + hashlib.sha256(data).hexdigest()
    asset = next((a for a in assets if a['name'] == path.name), None)
    if asset is None:
        asset = api('POST', release['upload_url'].split('{')[0] + '?name=' + urllib.parse.quote(path.name), data)
    assert asset['size'] == len(data) and asset['digest'] == digest, path.name
    print('Verified uploaded asset:', path.name, flush=True)
published = api('PATCH', f'/releases/{release["id"]}',
                {'draft': False, 'prerelease': True, 'make_latest': 'false'})
print(published['html_url'])
