#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sstp-health-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Compile the actual private helper without AppSupport's SwiftUI/app dependencies.
# Fail visibly if its source boundaries change instead of testing a copied runner.
python3 - "$ROOT/Sources/AppSupport.swift" "$WORK/HealthProcessHarness.swift" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
model_marker = "final class QuickHealthModel: ObservableObject {"
assert source.count(model_marker) == 1
model = source.split(model_marker, 1)[1]
start = model.index("    private func run(")
end = model.index("    func refresh(vpn: VPNModel)", start)
helper = model[start:end]
assert helper.count("private func run(") == 1
assert "timeout: TimeInterval = 8" in helper
Path(sys.argv[2]).write_text("import Foundation\nfinal class HealthProcessHarness {\n" + helper + """
    func check(_ executable: String, _ args: [String], timeout: TimeInterval = 8) -> (String, Int32) {
        run(executable, args, timeout: timeout)
    }
}
""")
PY

xcrun swiftc -parse-as-library -module-cache-path "$WORK/module-cache" \
  "$WORK/HealthProcessHarness.swift" "$ROOT/Tests/HealthProcessTests.swift" \
  -o "$WORK/health-process-tests"
"$WORK/health-process-tests"
