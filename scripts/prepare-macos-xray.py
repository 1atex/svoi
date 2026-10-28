import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
config = json.loads((root / 'config/macos-release.json').read_text())
module = 'github.com/xtls/xray-core@' + config['xrayModuleVersion']
environment = dict(os.environ, GOWORK='off')
with tempfile.TemporaryDirectory(prefix='svoi-xray-module-') as folder:
    metadata = json.loads(subprocess.check_output(['go', 'mod', 'download', '-json', module], cwd=folder, env=environment))
    original = Path(metadata['Dir']) / 'main/run.go'
    source = original.read_bytes()
    assert hashlib.sha256(source).hexdigest() == config['xrayRunSha256'], 'Unexpected upstream Xray run.go'
    text = source.decode()
    before = '\tif err := server.Start(); err != nil {'
    registration = '\tosSignals := make(chan os.Signal, 1)\n\tsignal.Notify(osSignals, os.Interrupt, syscall.SIGTERM)\n\tdefer signal.Stop(osSignals)\n\n'
    late = '\t{\n\t\tosSignals := make(chan os.Signal, 1)\n\t\tsignal.Notify(osSignals, os.Interrupt, syscall.SIGTERM)\n\t\t<-osSignals\n\t}'
    assert text.count(before) == 1 and text.count(late) == 1
    patched = text.replace(before, registration + before).replace(late, '\t<-osSignals').encode()
    target = root / '.tools/macos-xray-source'
    if not target.exists():
        shutil.copytree(metadata['Dir'], target)
    file = target / 'main/run.go'
    assert file.read_bytes() in (source, patched), 'Unexpected existing local Xray modification'
    file.chmod(file.stat().st_mode | stat.S_IWUSR)
    file.write_bytes(patched)
    print('Prepared Xray 1b1647c with early shutdown signal registration; global module cache unchanged')
