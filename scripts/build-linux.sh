#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
VERSION=$(python3 -c 'import json; print(json.load(open("config/linux-release.json"))["version"])')
XRAY_VERSION=$(python3 -c 'import json; print(json.load(open("config/linux-release.json"))["xrayVersion"])')
XRAY_SHA=$(python3 -c 'import json; print(json.load(open("config/linux-release.json"))["xraySha256"])')
mkdir -p .tools/linux-core .tools/linux-backend releases/linux-v"$VERSION"
if [[ ! -f .tools/linux-core/xray.zip ]] || ! echo "$XRAY_SHA  .tools/linux-core/xray.zip" | sha256sum -c --status; then
  curl --fail --location --retry 3 "https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION/Xray-linux-64.zip" -o .tools/linux-core/xray.zip
fi
echo "$XRAY_SHA  .tools/linux-core/xray.zip" | sha256sum -c -
unzip -oq .tools/linux-core/xray.zip -d .tools/linux-core
chmod 755 .tools/linux-core/xray
python3 scripts/prepare-optional-cores.py --target linux-x64 --output .tools/linux-core
CGO_ENABLED=0 go build -tags native_core -trimpath -ldflags "-s -w -X main.nativeVersion=$VERSION" -o .tools/linux-backend/svoi-backend ./backend
pushd flutter_client
flutter pub get
flutter build linux --release --dart-define=SVOI_VERSION="$VERSION"
popd
python3 scripts/package-linux.py
