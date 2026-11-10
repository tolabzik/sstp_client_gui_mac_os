#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Resources/vpnctl_config.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sstp-config-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
COUNT=0

check_equal() {
  if [ "$1" != "$2" ]; then
    printf 'FAIL: %s\n' "$3" >&2
    exit 1
  fi
  COUNT=$((COUNT + 1))
}

mock_sstpc() {
  local path="$1" marker="$2"
  printf '#!/bin/bash\n[ "$1" = --version ] || exit 99\nprintf "%%s\\n" "sstpc 1.0.20 %s"\n' "$marker" > "$path"
  chmod 700 "$path"
}
mock_sstpc "$WORK/patched-sstpc" sstp-gui-fixes-1
mock_sstpc "$WORK/stock-sstpc" ''
mock_sstpc "$WORK/wrong-marker-sstpc" sstp-gui-fixes-10
select_sstpc "$WORK/patched-sstpc" "$WORK/missing" "$WORK/stock-sstpc" "$WORK/missing"
check_equal "$SSTPC/$SSTPC_HAS_GUI_FIXES" "$WORK/patched-sstpc/1" "prefer verified private dependency"
select_sstpc "$WORK/wrong-marker-sstpc" "$WORK/stock-sstpc" "$WORK/stock-sstpc" "$WORK/missing"
check_equal "$SSTPC/$SSTPC_HAS_GUI_FIXES" "$WORK/stock-sstpc/0" "unmarked private builds cannot enable fixes"
select_sstpc "$WORK/missing" "$WORK/patched-sstpc" "$WORK/stock-sstpc" "$WORK/missing"
check_equal "$SSTPC/$SSTPC_HAS_GUI_FIXES" "$WORK/patched-sstpc/1" "Intel private dependency"
select_sstpc "$WORK/missing" "$WORK/missing" "$WORK/patched-sstpc" "$WORK/missing"
check_equal "$SSTPC_HAS_GUI_FIXES" 1 "marker is checked on selected stock-path binary too"
if select_sstpc "$WORK/missing" "$WORK/missing" "$WORK/missing" "$WORK/missing"; then
  echo 'FAIL: missing dependency selected' >&2; exit 1
fi
check_equal "$SSTPC/$SSTPC_HAS_GUI_FIXES" '/0' "missing dependency clears prior capability"

valid_endpoint() {
  parse_server_endpoint "$1" "$2" || { echo "FAIL: valid endpoint rejected" >&2; exit 1; }
  check_equal "$SERVER_HOST" "$3" "host must be independent of the port"
  check_equal "$SERVER_PORT" "$4" "normalized port"
  check_equal "$SSTP_TARGET" "$3:$4" "SSTP target"
}

invalid_endpoint() {
  if parse_server_endpoint "$1" "$2"; then
    echo "FAIL: invalid endpoint accepted" >&2
    exit 1
  fi
  [ -n "$CONFIG_ERROR" ] || exit 1
  check_equal "$SERVER_HOST/$SERVER_PORT/$SSTP_TARGET" "//" "invalid endpoints must not leave a stale target"
}

valid_endpoint 'vpn.example.com' 443 'vpn.example.com' 443
valid_endpoint 'vpn.example.com' 8443 'vpn.example.com' 8443
valid_endpoint 'vpn.example.com:9443' 8443 'vpn.example.com' 9443
valid_endpoint '  vpn.example.com  ' ' 443 ' 'vpn.example.com' 443
valid_endpoint '192.0.2.1:1' 443 '192.0.2.1' 1
valid_endpoint 'vpn.example.com.' 65535 'vpn.example.com.' 65535
valid_endpoint 'vpn.example.com' 000000443 'vpn.example.com' 443
# An explicit inline port takes precedence even when the separate field is invalid.
valid_endpoint 'vpn.example.com:443' bad 'vpn.example.com' 443

for host in '' '-vpn.example.com' 'vpn-.example.com' 'vpn..example.com' '.vpn.example.com' \
  'https://vpn.example.com' 'vpn.example.com/path' 'vpn example.com' 'vpn.example.com|x' \
  'vpn.example.com:0' 'vpn.example.com:' 'vpn.example.com:65536' \
  '::1' '[2001:db8::1]:443' '127.1' '1234' '256.1.2.3' '192.0.2.1.' '192.000.002.001'; do
  invalid_endpoint "$host" 443
done
for port in '' 0 65536 -1 +443 4.43 443x 999999999999999999999; do
  invalid_endpoint 'vpn.example.com' "$port"
done
invalid_endpoint "$(printf '%064d' 0).example.com" 443

printf 'fixture\n' > "$WORK/custom-ca.pem"
resolve_certificate verify "$WORK/custom-ca.pem"
check_equal "$RESOLVED_CERT_FILE" "$WORK/custom-ca.pem" "explicit CA selection"
if resolve_certificate verify "$WORK/missing.pem"; then
  echo "FAIL: missing explicit CA accepted" >&2; exit 1
fi
check_equal "$RESOLVED_CERT_FILE" '' "missing CA must not fall back or ignore verification"
if resolve_certificate verify ''; then
  echo "FAIL: automatic public CA trust accepted with unpatched sstpc" >&2; exit 1
fi
check_equal "$RESOLVED_CERT_FILE" '' "verification requires explicit CA until hostname checking is fixed"
if [ -r /etc/ssl/cert.pem ]; then
  resolve_certificate verify '' 1
  check_equal "$RESOLVED_CERT_FILE" /etc/ssl/cert.pem "patched dependency enables public CA bundle"
else
  if resolve_certificate verify '' 1; then
    echo 'FAIL: missing default CA bundle accepted' >&2; exit 1
  fi
fi
if resolve_certificate verify "$WORK/missing.pem" 1; then
  echo 'FAIL: patched dependency ignores missing explicit CA' >&2; exit 1
fi
resolve_certificate ignore "$WORK/missing.pem"
check_equal "$RESOLVED_CERT_FILE" '' "explicit ignore mode"
if resolve_certificate unexpected ''; then
  echo "FAIL: unknown certificate mode accepted" >&2; exit 1
fi

validate_sstpc_password 'spaces, $dollars; #hashes and apostrophes '\'' stay unchanged'
validate_sstpc_password "$(printf '%0242d' 0)"
for password in '' 'secret"fragment' 'secret\fragment' $'secret\rfragment' $'secret\nfragment' $'secret\n' "$(printf '%0243d' 0)"; do
  if validate_sstpc_password "$password"; then
    echo 'FAIL: unsafe password accepted' >&2; exit 1
  fi
  if [[ "$CONFIG_ERROR" == *secret* ]] || [[ "$CONFIG_ERROR" == *fragment* ]]; then
    echo 'FAIL: error message contains password material' >&2; exit 1
  fi
  COUNT=$((COUNT + 1))
done
# The dependency limit is bytes, not Swift characters or Unicode scalars.
unicode_password=''
for ((i=0; i<122; i++)); do unicode_password="${unicode_password}é"; done
if validate_sstpc_password "$unicode_password"; then
  echo 'FAIL: UTF-8 password byte limit ignored' >&2; exit 1
fi

validate_sstpc_password 'quote"backslash\ and spaces' 1
validate_sstpc_password "$(printf '%0255d' 0)" 1
for password in "$(printf '%0256d' 0)" $'secret\n' $'secret\r'; do
  if validate_sstpc_password "$password" 1; then
    echo 'FAIL: patched password limits ignored' >&2; exit 1
  fi
done
printf '%s' 'quote"backslash\ and spaces' > "$WORK/password"
read_sstpc_password "$WORK/password" 1
check_equal "$PASSWORD" 'quote"backslash\ and spaces' "patched dependency receives unchanged password"

printf 'plain password' > "$WORK/password"
read_sstpc_password "$WORK/password"
check_equal "$PASSWORD" 'plain password' "password handoff preserves bytes"
printf 'secret\n' > "$WORK/password"
if read_sstpc_password "$WORK/password"; then
  echo 'FAIL: trailing newline was silently removed' >&2; exit 1
fi
printf 'secret\0fragment' > "$WORK/password"
if read_sstpc_password "$WORK/password"; then
  echo 'FAIL: NUL byte was silently removed' >&2; exit 1
fi

# Exercise the real controller rejection path in an isolated copy. The first
# operation after validation is replaced with a fail-fast boundary: even if a
# validation regresses, this harness cannot reach route/process cleanup.
cp "$ROOT/Resources/vpnctl_config.sh" "$WORK/vpnctl_config.sh"
awk '
  /^case "\$ACTION" in$/ {
    print "RESULT=\"$TEST_WORK/result\""
    print "SSTPC=/usr/bin/false"
    print "SSTPC_HAS_GUI_FIXES=\"${TEST_GUI_FIXES:-0}\""
    print "cleanup_all() {"
    print "  if [ \"${TEST_ALLOW_CONFIG:-0}\" = 1 ]; then"
    print "    printf \"%s\\n\" \"$SERVER_HOST\" \"$SSTP_TARGET\" \"$CERT_FILE\" > \"$TEST_WORK/accepted-config\""
    print "    printf \"%s\" \"$PASSWORD\" > \"$TEST_WORK/accepted-password\""
    print "    printf \"%s\\n\" \"${SSTPC_ARGS[@]}\" > \"$TEST_WORK/accepted-arguments\""
    print "    exit 0"
    print "  fi"
    print "  echo \"FAIL: invalid input reached cleanup\" >&2; exit 91"
    print "}"
  }
  { print }
' "$ROOT/Resources/vpnctl_core.sh" > "$WORK/vpnctl_core.sh"
export TEST_WORK="$WORK"

controller_rejects() {
  local server="$1" port="$2" cert="$3" password="$4" expected="$5"
  printf '%s' "$password" > "$WORK/handoff"
  /bin/bash "$WORK/vpnctl_core.sh" connect "$server" username "$WORK/handoff" verify "$cert" 1 "$port"
  [ ! -e "$WORK/handoff" ] || { echo 'FAIL: rejected password handoff remains' >&2; exit 1; }
  local result
  result="$(cat "$WORK/result")"
  [[ "$result" == "FAIL|$expected"* ]] || { echo 'FAIL: controller rejection result' >&2; exit 1; }
  [[ "$result" != *secret* ]] || { echo 'FAIL: controller leaked password' >&2; exit 1; }
  COUNT=$((COUNT + 1))
}

controller_rejects 'vpn.example.com' 0 "$WORK/custom-ca.pem" plain 'Port must be'
controller_rejects 'vpn.example.com:0' 443 "$WORK/custom-ca.pem" plain 'Port must be'
controller_rejects 'vpn.example.com' 443 "$WORK/missing.pem" plain 'CA certificate file'
controller_rejects 'vpn.example.com' 443 "$WORK/custom-ca.pem" 'secret"fragment' 'The installed sstp-client'
controller_rejects 'vpn.example.com' 443 "$WORK/custom-ca.pem" $'secret\n' 'Passwords containing line breaks'
controller_rejects 'vpn.example.com' 443 '' plain 'Select an explicit CA/server certificate'

printf '%s' 'secret"with\quotes' > "$WORK/handoff"
TEST_GUI_FIXES=1 TEST_ALLOW_CONFIG=1 /bin/bash "$WORK/vpnctl_core.sh" connect 'vpn.example.com:8443' username "$WORK/handoff" verify "$WORK/custom-ca.pem" 1 443
[ ! -e "$WORK/handoff" ] || { echo 'FAIL: accepted handoff not removed' >&2; exit 1; }
check_equal "$(cat "$WORK/accepted-password")" 'secret"with\quotes' "controller preserves original patched password"
check_equal "$(sed -n '1p' "$WORK/accepted-config")" vpn.example.com "controller route host"
check_equal "$(sed -n '2p' "$WORK/accepted-config")" vpn.example.com:8443 "controller SSTP target"
check_equal "$(sed -n '4p' "$WORK/accepted-arguments")" --tls-ext "patched dependency enables normalized SNI"
check_equal "$(sed -n '5p' "$WORK/accepted-arguments")" --ca-cert "patched dependency keeps certificate verification"
printf plain > "$WORK/handoff"
TEST_GUI_FIXES=0 TEST_ALLOW_CONFIG=1 /bin/bash "$WORK/vpnctl_core.sh" connect vpn.example.com username "$WORK/handoff" verify "$WORK/custom-ca.pem" 1 443
check_equal "$(sed -n '4p' "$WORK/accepted-arguments")" --ca-cert "stock dependency does not enable unsafe SNI"
if /usr/bin/grep -qx -- --tls-ext "$WORK/accepted-arguments"; then
  echo 'FAIL: stock dependency received --tls-ext' >&2; exit 1
fi
if [ -r /etc/ssl/cert.pem ]; then
  printf plain > "$WORK/handoff"
  TEST_GUI_FIXES=1 TEST_ALLOW_CONFIG=1 /bin/bash "$WORK/vpnctl_core.sh" connect vpn.example.com username "$WORK/handoff" verify '' 1 443
  check_equal "$(sed -n '3p' "$WORK/accepted-config")" /etc/ssl/cert.pem "controller public CA only with patched capability"
fi

# Emergency repair uses the host only as an optional cleanup hint. Malformed
# input must not disable it, and an inline port must never reach the cleaner.
cat > "$WORK/emergency_cleanup.sh" <<'CLEANER'
#!/bin/bash
printf '%s' "$1" > "$TEST_WORK/purge-server"
CLEANER
/bin/bash "$WORK/vpnctl_core.sh" purge 'vpn.example.com:8443'
check_equal "$(cat "$WORK/purge-server")" 'vpn.example.com' "repair passes host without port"
/bin/bash "$WORK/vpnctl_core.sh" purge 'bad server:broken'
check_equal "$(cat "$WORK/purge-server")" '' "repair still runs for invalid editable profile"
check_equal "$(cat "$WORK/result")" 'OFF|Emergency SSTP cleanup completed' "repair succeeds without optional host"

printf 'Backend configuration tests passed (%s assertions). No network changes made.\n' "$COUNT"
