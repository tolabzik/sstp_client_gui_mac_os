#!/bin/bash
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$HERE/vpnctl_core.sh"

if [ ! -f "$CORE" ]; then
  printf '%s\n' 'FAIL|vpnctl_core.sh is missing from the app bundle' > /tmp/sstp-gui.result
  chmod 0644 /tmp/sstp-gui.result 2>/dev/null || true
  exit 0
fi

exec /bin/bash "$CORE" "$@"
