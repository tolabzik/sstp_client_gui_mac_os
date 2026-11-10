#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sstp-upstream-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ARCHIVE="${1:-$WORK/sstp-client-1.0.20.tar.gz}"
if [ "$#" -eq 0 ]; then
  curl --fail --location --silent --show-error --proto '=https' \
    https://gitlab.com/sstp-project/sstp-client/-/releases/1.0.20/downloads/dist-gzip/sstp-client-1.0.20.tar.gz \
    -o "$ARCHIVE"
fi
EXPECTED=6c84b6cdcc21ebea6daeb8c5356dcdfd8681f4981a734f8485ed0b31fc30aadd
ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || { echo 'Upstream source checksum mismatch' >&2; exit 1; }
python3 - "$ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
embedded = (root / 'Formula/sstp-client-gui.rb').read_text().split('__END__\n', 1)[1]
assert embedded == (root / 'Patches/sstp-client-1.0.20-gui.patch').read_text(), 'Formula patch differs from reviewed patch'
PY
tar -xzf "$ARCHIVE" -C "$WORK"
export OPENSSL_PREFIX="${OPENSSL_PREFIX:-$(brew --prefix openssl@3)}"
python3 "$ROOT/Tests/upstream_regression.py" "$WORK/sstp-client-1.0.20"
