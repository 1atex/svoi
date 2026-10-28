#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Apple Silicon macOS is required.'; exit 1; }
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcodebuild -version || { echo 'Install full Xcode and open it once. Command Line Tools alone are insufficient.'; exit 1; }
xcodebuild -checkFirstLaunchStatus || { echo 'Open Xcode and complete its first-launch setup, then retry.'; exit 1; }
if [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
mkdir -p .tools/ios-sdk
if ! command -v brew >/dev/null; then
  curl --fail --location --retry 3 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o .tools/ios-sdk/install-homebrew.sh
  /bin/bash .tools/ios-sdk/install-homebrew.sh
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
export HOMEBREW_NO_AUTO_UPDATE=1
brew install python@3.11 xcodegen
PYTHON_PREFIX=$(brew --prefix python@3.11)
export PATH="$PYTHON_PREFIX/libexec/bin:$PYTHON_PREFIX/bin:$PATH"
GO_VERSION=$(python3 -c 'import json; print(json.load(open("config/ios-release.json"))["goVersion"])')
if ! command -v go >/dev/null || [[ $(go version) != "go version go$GO_VERSION darwin/arm64" ]]; then
  ARCHIVE="$ROOT/.tools/ios-sdk/go-$GO_VERSION.tar.gz"
  curl --fail --location --retry 3 "https://go.dev/dl/go$GO_VERSION.darwin-arm64.tar.gz" -o "$ARCHIVE"
  echo "dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2  $ARCHIVE" | shasum -a 256 -c -
  if [[ -d .tools/ios-sdk/go ]]; then mv .tools/ios-sdk/go ".tools/ios-sdk/go-previous-$(date +%s)-$$"; fi
  tar -xzf "$ARCHIVE" -C .tools/ios-sdk
  export PATH="$ROOT/.tools/ios-sdk/go/bin:$PATH"
fi
bash scripts/build-ios.sh
