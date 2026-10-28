#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Run on an Apple Silicon Mac with Xcode.'; exit 1; }
VERSION=$(python3 -c 'import json; print(json.load(open("config/macos-release.json"))["version"])')
XRAY_VERSION=$(python3 -c 'import json; print(json.load(open("config/macos-release.json"))["xrayVersion"])')
XRAY_ASSET=$(python3 -c 'import json; print(json.load(open("config/macos-release.json"))["xrayAsset"])')
XRAY_SHA=$(python3 -c 'import json; print(json.load(open("config/macos-release.json"))["xraySha256"])')
BUILD="$ROOT/.tools/macos-package/$VERSION"
mkdir -p "$BUILD/core" "releases/macos-v$VERSION"
if [[ ! -f "$BUILD/core.zip" ]] || ! echo "$XRAY_SHA  $BUILD/core.zip" | shasum -a 256 -c --status; then
  curl --fail --location --retry 3 "https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION/$XRAY_ASSET" -o "$BUILD/core.zip"
fi
echo "$XRAY_SHA  $BUILD/core.zip" | shasum -a 256 -c -
unzip -oq "$BUILD/core.zip" -d "$BUILD/core"
python3 scripts/prepare-macos-xray.py
(cd .tools/macos-xray-source && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -mod=readonly -buildvcs=false -trimpath -ldflags '-s -w -X github.com/xtls/xray-core/core.build=1b1647c-svoi-macos.1' -o "$BUILD/core/xray" ./main)
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -tags native_core -trimpath -ldflags "-s -w -X main.nativeVersion=$VERSION" -o "$BUILD/svoi-backend" ./backend
xcrun swiftc -O -target arm64-apple-macos13.0 -framework SystemConfiguration -framework Security flutter_client/macos/ProxyHelper.swift -o "$BUILD/svoi-proxy"
"$BUILD/svoi-proxy" --self-test
for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" assets/brand/app-icon-macos.png --out "flutter_client/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png" >/dev/null
done
(cd flutter_client && flutter pub get && flutter build macos --release --build-name="${VERSION%%-*}" --build-number="${VERSION##*.}" --dart-define=SVOI_VERSION="$VERSION")
APP="$ROOT/flutter_client/build/macos/Build/Products/Release/SVOI.app"
BACKEND="$APP/Contents/MacOS/backend"
mkdir -p "$BACKEND/core" "$APP/Contents/Resources/licenses"
cp "$BUILD/svoi-backend" "$BUILD/svoi-proxy" "$BACKEND/"
cp "$BUILD/core/xray" "$BACKEND/core/"
for file in geoip.dat geosite.dat; do
  [[ ! -f "$BUILD/core/$file" ]] || cp "$BUILD/core/$file" "$BACKEND/core/"
done
cp LICENSE "$APP/Contents/Resources/licenses/SVOI-MIT.txt"
cp patches/macos-xray/README.md "$APP/Contents/Resources/licenses/Xray-macOS-patch.md"
cp -R licenses/. "$APP/Contents/Resources/licenses/"
[[ ! -f "$BUILD/core/LICENSE" ]] || cp "$BUILD/core/LICENSE" "$APP/Contents/Resources/licenses/Xray-LICENSE.txt"
cp docs/MACOS.md "$APP/Contents/Resources/MACOS.md"
chmod 755 "$BACKEND/svoi-backend" "$BACKEND/svoi-proxy" "$BACKEND/core/xray"
codesign --force --sign - "$BACKEND/core/xray"
codesign --force --sign - "$BACKEND/svoi-backend"
codesign --force --sign - "$BACKEND/svoi-proxy"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
python3 scripts/package-macos.py "$APP" "$VERSION"
