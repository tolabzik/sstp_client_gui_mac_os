#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Resources/vpnctl_dns.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sstp-dns-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SERVICEFILE="$WORK/service.id"
OWNED_ID='sstp-gui-01234567-89AB-CDEF-0123-456789ABCDEF'
FOREIGN_ID='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
PROCESS_STATUS=1
SCUTIL_STATUS=0
LEAVE_DNS=0
COUNT=0

check() {
  "$@" || { echo "FAIL: $*" >&2; exit 1; }
  COUNT=$((COUNT + 1))
}

service_pppd_running() { return "$PROCESS_STATUS"; }
service_scutil() {
  local command key prefix
  [ "$SCUTIL_STATUS" -eq 0 ] || return "$SCUTIL_STATUS"
  while IFS=' ' read -r command key; do
    printf '%s %s\n' "$command" "$key" >> "$WORK/commands"
    case "$command" in
      remove)
        if [ "$LEAVE_DNS" = 1 ] && [ "$key" = "State:/Network/Service/$OWNED_ID/DNS" ]; then
          continue
        fi
        /usr/bin/grep -Fvx "$key" "$WORK/keys" > "$WORK/next" || true
        mv "$WORK/next" "$WORK/keys"
        ;;
      list)
        prefix="${key%.*}"
        /usr/bin/grep -F "$prefix" "$WORK/keys" || true
        ;;
      *) return 99 ;;
    esac
  done
}

reset_fixture() {
  printf '%s\n' "$OWNED_ID" > "$SERVICEFILE"
  chmod 600 "$SERVICEFILE"
  : > "$WORK/commands"
  printf 'State:/Network/Service/%s/DNS\nState:/Network/Service/%s/IPv4\nState:/Network/Service/%s/PPP\nState:/Network/Service/%s/DNS\nSetup:/Network/Service/%s/DNS\nState:/Network/Global/DNS\n' \
    "$OWNED_ID" "$OWNED_ID" "$OWNED_ID" "$FOREIGN_ID" "$OWNED_ID" > "$WORK/keys"
  PROCESS_STATUS=1 SCUTIL_STATUS=0 LEAVE_DNS=0
}

check cleanup_owned_service
create_owned_service_id
check valid_sstp_service_id "$SERVICE_ID"
check service_file_is_owned
check test "$(cat "$SERVICEFILE")" = "$SERVICE_ID"
if create_owned_service_id; then echo 'FAIL: overwrote existing ownership record' >&2; exit 1; fi
check test "$(cat "$SERVICEFILE")" = "$SERVICE_ID"

reset_fixture
PROCESS_STATUS=0
if cleanup_owned_service; then echo 'FAIL: removed running PPP state' >&2; exit 1; fi
check test ! -s "$WORK/commands"
check test -f "$SERVICEFILE"
PROCESS_STATUS=2
if cleanup_owned_service; then echo 'FAIL: treated process query error as exit' >&2; exit 1; fi
check test ! -s "$WORK/commands"

reset_fixture
cleanup_owned_service
check test ! -e "$SERVICEFILE"
check test "$(wc -l < "$WORK/keys" | tr -d ' ')" = 3
check grep -Fxq "State:/Network/Service/$FOREIGN_ID/DNS" "$WORK/keys"
check grep -Fxq "Setup:/Network/Service/$OWNED_ID/DNS" "$WORK/keys"
check grep -Fxq 'State:/Network/Global/DNS' "$WORK/keys"
check test "$(grep -c '^remove ' "$WORK/commands")" = 7

for invalid in "$FOREIGN_ID" $'sstp-gui-invalid\nremove State:/Network/Global/DNS' 'sstp-gui-../../Global'; do
  reset_fixture
  printf '%s\n' "$invalid" > "$SERVICEFILE"
  if cleanup_owned_service; then echo 'FAIL: accepted invalid/unowned service ID' >&2; exit 1; fi
  check test ! -s "$WORK/commands"
done

reset_fixture
chmod 666 "$SERVICEFILE"
if cleanup_owned_service; then echo 'FAIL: trusted writable ownership record' >&2; exit 1; fi
check test ! -s "$WORK/commands"
rm "$SERVICEFILE"
printf '%s\n' "$OWNED_ID" > "$WORK/symlink-target"
chmod 600 "$WORK/symlink-target"
ln -s "$WORK/symlink-target" "$SERVICEFILE"
if cleanup_owned_service; then echo 'FAIL: followed ownership symlink' >&2; exit 1; fi
check test ! -s "$WORK/commands"
rm "$SERVICEFILE"

reset_fixture
SCUTIL_STATUS=1
if cleanup_owned_service; then echo 'FAIL: ignored scutil failure' >&2; exit 1; fi
check test -f "$SERVICEFILE"
reset_fixture
LEAVE_DNS=1
if cleanup_owned_service; then echo 'FAIL: lost ownership before DNS disappeared' >&2; exit 1; fi
check test -f "$SERVICEFILE"
check grep -Fxq "State:/Network/Service/$OWNED_ID/DNS" "$WORK/keys"
LEAVE_DNS=0
cleanup_owned_service
check test ! -e "$SERVICEFILE"

echo "$COUNT DNS ownership checks passed"

# Exercise the real controller cleanup functions with OS mutations replaced at
# their boundaries. Keep all state paths inside this fixture directory.
cp "$ROOT/Resources/vpnctl_config.sh" "$ROOT/Resources/vpnctl_dns.sh" "$WORK/"
awk '/^case "\$ACTION" in$/ { exit } { print }' "$ROOT/Resources/vpnctl_core.sh" > "$WORK/core-functions.sh"
cat > "$WORK/controller-check.sh" <<'CONTROLLER'
#!/bin/bash
set -eu
. "$TEST_WORK/core-functions.sh"
PIDFILE="$TEST_WORK/client.pid"
STATEFILE="$TEST_WORK/state"
HELPER_PIDFILE="$TEST_WORK/helpers.pid"
HELPER_FILELIST="$TEST_WORK/helper.files"
WATCHDOG_PIDFILE="$TEST_WORK/watchdog.pid"
RESULT="$TEST_WORK/result"
TRACE="$TEST_WORK/trace"
DNS_RETURN=1

stop_watchdog() { echo stop >> "$TRACE"; }
delete_owned_routes() { echo routes >> "$TRACE"; }
kill_owned_helpers() { echo ppp >> "$TRACE"; }
kill_owned_client() { echo client >> "$TRACE"; }
cleanup_tracked_temp_files() { echo temp >> "$TRACE"; }
cleanup_owned_service() { echo dns >> "$TRACE"; return "$DNS_RETURN"; }
flush_dns_cache() { echo flush >> "$TRACE"; }
kill_orphan_sstp_helpers() { :; }
cleanup_test_routes() { :; }
read_state() { STATE_PPP='' STATE_SERVER='' STATE_GW='' STATE_PHY=''; }

for path in "$PIDFILE" "$STATEFILE" "$HELPER_PIDFILE" "$HELPER_FILELIST" "$WATCHDOG_PIDFILE"; do
  printf 'fixture\n' > "$path"
done
if cleanup_all; then echo 'FAIL: controller ignored DNS cleanup failure' >&2; exit 1; fi
for path in "$PIDFILE" "$STATEFILE" "$HELPER_PIDFILE" "$HELPER_FILELIST"; do
  [ -f "$path" ] || { echo 'FAIL: controller lost retry ownership' >&2; exit 1; }
done
[ "$(tr '\n' ' ' < "$TRACE")" = 'stop routes ppp client temp dns flush ' ] || {
  echo 'FAIL: pppd must shut down before its SSTP transport' >&2; exit 1;
}
watchdog_cleanup_after_crash
for path in "$PIDFILE" "$STATEFILE" "$HELPER_PIDFILE" "$HELPER_FILELIST"; do
  [ -f "$path" ] || { echo 'FAIL: watchdog lost retry ownership' >&2; exit 1; }
done
[ ! -f "$WATCHDOG_PIDFILE" ]
grep -q 'DNS cleanup is incomplete' "$RESULT"
DNS_RETURN=0
cleanup_all
for path in "$PIDFILE" "$STATEFILE" "$HELPER_PIDFILE" "$HELPER_FILELIST"; do
  [ ! -f "$path" ] || { echo 'FAIL: successful retry left tracking state' >&2; exit 1; }
done
echo 'Controller cleanup ordering and retry checks passed'
CONTROLLER
TEST_WORK="$WORK" /bin/bash "$WORK/controller-check.sh"
