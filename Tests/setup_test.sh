#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sstp-setup-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/standalone" "$WORK/component/sbin"
export TEST_SETUP_BREW="$WORK/mock-brew" TEST_SETUP_PREFIX="$WORK/component"

# Only the setup script is copied, matching the GUI's temporary .command
# handoff. Its directory deliberately has no vpnctl_config.sh resource.
awk '
  {
    gsub("/opt/homebrew/bin/brew", ENVIRON["TEST_SETUP_BREW"])
    gsub("/usr/local/bin/brew", ENVIRON["TEST_SETUP_BREW"])
    print
  }
  /^set -e$/ {
    print "clear() { :; }"
    print "sudo() { :; }"
    print "ls() { :; }"
  }
' "$ROOT/Resources/setup.sh" > "$WORK/standalone/SSTP-Client-GUI-Setup.command"

cat > "$WORK/mock-brew" <<'BREW'
#!/bin/bash
case "$*" in
  --version) printf 'Homebrew fixture\n' ;;
  'tap tolabzik/sstp-client-gui https://github.com/tolabzik/sstp_client_gui_mac_os.git') : ;;
  'install tolabzik/sstp-client-gui/sstp-client-gui') : ;;
  '--prefix tolabzik/sstp-client-gui/sstp-client-gui') printf '%s\n' "$TEST_SETUP_PREFIX" ;;
  *) echo 'Unexpected dependency setup command' >&2; exit 99 ;;
esac
BREW
chmod 700 "$WORK/mock-brew"

cat > "$WORK/component/sbin/sstpc" <<'SSTPC'
#!/bin/bash
[ "$1" = --version ] || exit 99
printf '%s\n' "sstpc 1.0.20 ${TEST_SETUP_MARKER:-sstp-gui-fixes-1}"
SSTPC
chmod 700 "$WORK/component/sbin/sstpc"

/bin/bash "$WORK/standalone/SSTP-Client-GUI-Setup.command" <<< x > "$WORK/result" 2>&1
if TEST_SETUP_MARKER=sstp-gui-fixes-10 /bin/bash "$WORK/standalone/SSTP-Client-GUI-Setup.command" <<< x > "$WORK/result" 2>&1; then
  echo 'FAIL: setup accepted an incorrect capability marker' >&2
  exit 1
fi
printf 'Standalone setup tests passed. No components installed.\n'
