#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT/apple/ios-tunnel-check"
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen'; exit 1; }
xcodegen generate
xcodebuild -project SvoiTunnelCheck.xcodeproj -scheme SvoiTunnelCheck -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$ROOT/.tools/ios-tunnel-check" CODE_SIGNING_ALLOWED=NO build > "$ROOT/.tools/ios-tunnel-check-build.log" 2>&1 || { tail -n 100 "$ROOT/.tools/ios-tunnel-check-build.log"; exit 1; }
APP="$ROOT/.tools/ios-tunnel-check/Build/Products/Release-iphoneos/SvoiTunnelCheck.app"
codesign --force --sign - --entitlements PacketTunnel.entitlements "$APP/PlugIns/PacketTunnel.appex"
codesign --force --sign - --entitlements App.entitlements "$APP"
codesign --verify --deep --strict "$APP"
OUTPUT="$ROOT/releases/ios-tunnel-check"
mkdir -p "$OUTPUT"
python3 "$ROOT/scripts/package-ios-check.py" "$APP" "$OUTPUT"
