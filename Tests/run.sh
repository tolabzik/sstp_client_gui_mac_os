#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sstp-gui-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

for script in "$ROOT"/Resources/*.sh "$ROOT"/Tests/*.sh; do
  /bin/bash -n "$script"
done

/bin/bash "$ROOT/Tests/backend_config_test.sh"
/bin/bash "$ROOT/Tests/setup_test.sh"
xcrun swiftc -parse-as-library -module-cache-path "$WORK/module-cache" \
  "$ROOT/Sources/VPNConfiguration.swift" "$ROOT/Tests/ConfigurationTests.swift" \
  -o "$WORK/configuration-tests"
"$WORK/configuration-tests"
