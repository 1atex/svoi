import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VERSION = json.loads((ROOT / 'config/linux-release.json').read_text())['version']
OUTPUT = ROOT / 'releases' / ('linux-v' + VERSION)
BUNDLE = ROOT / '.tools/linux-package' / VERSION
STAGE = BUNDLE / 'svoi'
if BUNDLE.exists():
    if BUNDLE.resolve().parent != (ROOT / '.tools/linux-package').resolve():
        raise RuntimeError('Unexpected staging path')
    shutil.rmtree(BUNDLE)
STAGE.parent.mkdir(parents=True)
shutil.copytree(ROOT / 'flutter_client/build/linux/x64/release/bundle', STAGE)
(STAGE / 'backend/core').mkdir(parents=True)
shutil.copy2(ROOT / '.tools/linux-backend/svoi-backend', STAGE / 'backend/svoi-backend')
for name in ('xray', 'geoip.dat', 'geosite.dat', 'LICENSE'):
    shutil.copy2(ROOT / '.tools/linux-core' / name, STAGE / 'backend/core' / name)
shutil.copy2(ROOT / 'LICENSE', STAGE / 'LICENSE')
shutil.copytree(ROOT / 'licenses', STAGE / 'licenses')
shutil.copy2(ROOT / 'docs/LINUX.md', STAGE / 'LINUX.md')
for entry in STAGE.rglob('*'):
    if not entry.is_symlink(): entry.chmod(0o755 if entry.is_dir() else 0o644)
STAGE.chmod(0o755)
for name in ('svoi', 'backend/svoi-backend', 'backend/core/xray'):
    (STAGE / name).chmod(0o755)
OUTPUT.mkdir(parents=True, exist_ok=True)
archive = OUTPUT / f'SVOI-{VERSION}-linux-x64.tar.gz'
subprocess.run(['tar', '-czf', str(archive), '-C', str(BUNDLE), 'svoi'], check=True)
package = BUNDLE / 'deb'
(package / 'opt').mkdir(parents=True)
shutil.copytree(STAGE, package / 'opt/svoi')
(package / 'usr/bin').mkdir(parents=True)
(package / 'usr/bin/svoi').symlink_to('/opt/svoi/svoi')
applications = package / 'usr/share/applications'
applications.mkdir(parents=True)
(applications / 'dev.svoi.app.desktop').write_text("""[Desktop Entry]
Type=Application
Name=SVOI
Comment=VPN configuration manager
Comment[ru]=Менеджер подключений VPN
Exec=/opt/svoi/svoi
Icon=dev.svoi.app
Terminal=false
Categories=Network;Security;
StartupWMClass=dev.svoi.app
""", encoding='utf-8')
icons = package / 'usr/share/icons/hicolor/256x256/apps'
icons.mkdir(parents=True)
shutil.copy2(ROOT / 'flutter_client/assets/svoi-mark.png', icons / 'dev.svoi.app.png')
control = package / 'DEBIAN'
control.mkdir()
(control / 'control').write_text(f"""Package: svoi
Version: {VERSION.replace('-preview.', '~preview.')}
Section: net
Priority: optional
Architecture: amd64
Maintainer: SVOI contributors
Homepage: https://github.com/1atex/svoi
Depends: libc6 (>= 2.35), libstdc++6, libgtk-3-0, libblkid1, liblzma5, libayatana-appindicator3-1, libcap2-bin
Description: SVOI VPN configuration manager
 Flutter desktop client and Xray core with TUN and local proxy support.
""")
(control / 'postinst').write_text("""#!/bin/sh
set -e
if [ "$1" = configure ]; then
  chown root:sudo /opt/svoi/backend/core/xray
  chmod 0750 /opt/svoi/backend/core/xray
  setcap cap_net_admin,cap_net_raw+ep /opt/svoi/backend/core/xray
fi
""")
(control / 'postinst').chmod(0o755)
for entry in package.rglob('*'):
    if not entry.is_symlink() and entry.is_dir(): entry.chmod(0o755)
deb = OUTPUT / f'SVOI-{VERSION}-linux-amd64.deb'
subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(package), str(deb)], check=True)
for file in (archive, deb):
    digest = hashlib.sha256(file.read_bytes()).hexdigest()
    file.with_name(file.name + '.sha256').write_text(f'{digest}  {file.name}\n')
    print(file)
