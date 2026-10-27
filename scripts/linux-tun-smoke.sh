#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(python3 -c "import json; print(json.load(open('$ROOT/config/linux-release.json'))['version'])")
BUNDLE="$ROOT/.tools/linux-package/$VERSION/svoi"
if [[ "$EUID" != 0 ]]; then echo 'Run this isolated network test with sudo' >&2; exit 1; fi
if [[ "${1:-}" == --isolated ]]; then
  TEST_USER=$2
  ip link set lo up
  ip link add svoi-uplink type dummy
  ip addr add 192.0.2.2/24 dev svoi-uplink
  ip link set svoi-uplink up
  ip route add default via 192.0.2.1 metric 0
  runuser -u "$TEST_USER" -- python3 "$ROOT/scripts/linux-backend-smoke.py" "$BUNDLE" --tun
else
  TEST_USER=${1:?Pass an unprivileged test username}
  [[ $(id -u "$TEST_USER") != 0 ]]
  [[ -f "$BUNDLE/backend/core/xray" && ! -L "$BUNDLE/backend/core/xray" ]]
  chown root:"$(id -gn "$TEST_USER")" "$BUNDLE/backend/core/xray"
  chmod 0750 "$BUNDLE/backend/core/xray"
  setcap cap_net_admin,cap_net_raw+ep "$BUNDLE/backend/core/xray"
  unshare --net bash "$ROOT/scripts/linux-tun-smoke.sh" --isolated "$TEST_USER"
fi
