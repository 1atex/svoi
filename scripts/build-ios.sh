#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Run on an Apple Silicon Mac in a native arm64 Terminal.'; exit 1; }
mkdir -p .tools/ios-bin apple/ios-client/Frameworks
for command in go python3 xcodegen; do
  command -v "$command" >/dev/null || { echo "Required tool is missing: $command. Run bash scripts/setup-ios.sh first."; exit 1; }
done
python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ is required"'
xcodebuild -version
python3 scripts/prepare-xray-patch.py
python3 scripts/prepare-ios-resources.py
MOBILE_VERSION=$(python3 -c 'import json; print(json.load(open("config/ios-release.json"))["gomobileVersion"])')
export GOBIN="$ROOT/.tools/ios-bin"
export PATH="$GOBIN:$PATH"
go install "golang.org/x/mobile/cmd/gomobile@$MOBILE_VERSION"
go install "golang.org/x/mobile/cmd/gobind@$MOBILE_VERSION"
gomobile init
FRAMEWORK="$ROOT/apple/ios-client/Frameworks/SvoiMobile.xcframework"
if [[ -e "$FRAMEWORK" ]]; then
  echo 'A framework from an earlier build exists; moving it aside for a fresh build.'
  mv "$FRAMEWORK" "$ROOT/.tools/SvoiMobile-$(date +%s)-$$.xcframework"
fi
(cd mobile && gomobile bind -target=ios/arm64 -iosversion=16.0 -prefix Svoi -trimpath -ldflags='-checklinkname=0 -s -w' -o "$FRAMEWORK" .)
(cd apple/ios-client && xcodegen generate)
xcodebuild -project apple/ios-client/SVOI.xcodeproj -scheme SVOI -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$ROOT/.tools/ios-client-build" CODE_SIGNING_ALLOWED=NO build > .tools/ios-client-build.log 2>&1 || { tail -n 120 .tools/ios-client-build.log; exit 1; }
APP="$ROOT/.tools/ios-client-build/Build/Products/Release-iphoneos/SVOI.app"
codesign --force --sign - --entitlements apple/ios-client/PacketTunnel.entitlements "$APP/PlugIns/PacketTunnel.appex"
codesign --force --sign - --entitlements apple/ios-client/App.entitlements "$APP"
codesign --verify --deep --strict "$APP"
python3 scripts/package-ios.py "$APP"
