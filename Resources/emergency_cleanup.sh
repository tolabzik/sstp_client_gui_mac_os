#!/bin/bash
set -u
umask 077

SERVER="${1:-}"
LOG="/tmp/sstp-gui-purge.log"

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash $0 [vpn-server]" >&2
  exit 1
fi

: > "$LOG"
chmod 0644 "$LOG" 2>/dev/null || true
exec >>"$LOG" 2>&1

echo "=== SSTP Client GUI emergency cleanup ==="
/bin/date

echo
echo "--- Before: SSTP related processes ---"
/bin/ps ax -o pid=,ppid=,user=,command= | /usr/bin/grep -E 'sstpc|sstp-pppd\.|sstp-gui.*watchdog' | /usr/bin/grep -v grep || true

PPP_BEFORE="$(/sbin/ifconfig -l | /usr/bin/tr ' ' '\n' | /usr/bin/grep '^ppp[0-9]' 2>/dev/null || true)"
echo
echo "--- Before: PPP interfaces ---"
printf '%s\n' "$PPP_BEFORE"

echo
echo "--- Killing SSTP GUI watchdog / sstpc / sstp-pppd helpers ---"
PIDS=""
for PIDFILE in /tmp/sstp-gui.pid /tmp/sstp-gui-watchdog.pid /tmp/sstp-gui-helper.pids; do
  [ -f "$PIDFILE" ] || continue
  while IFS= read -r PID; do
    case "$PID" in
      ''|*[!0-9]*) continue ;;
    esac
    PIDS="$PIDS $PID"
  done < "$PIDFILE"
done

for PID in $(/usr/bin/pgrep -x sstpc 2>/dev/null || true); do PIDS="$PIDS $PID"; done
for PID in $(/usr/bin/pgrep -f '/(opt/homebrew|usr/local)/sbin/sstpc([[:space:]]|$)' 2>/dev/null || true); do PIDS="$PIDS $PID"; done
for PID in $(/usr/bin/pgrep -f '/tmp/+sstp-pppd\.' 2>/dev/null || true); do PIDS="$PIDS $PID"; done

UNIQUE_PIDS="$(printf '%s\n' $PIDS 2>/dev/null | /usr/bin/awk '/^[0-9]+$/ && !seen[$1]++ {print $1}')"
for PID in $UNIQUE_PIDS; do
  [ "$PID" -eq "$$" ] && continue
  CMD="$(/bin/ps -p "$PID" -o command= 2>/dev/null || true)"
  echo "TERM $PID $CMD"
  /bin/kill -TERM "$PID" >/dev/null 2>&1 || true
done

sleep 1
for PID in $UNIQUE_PIDS; do
  [ "$PID" -eq "$$" ] && continue
  if /bin/kill -0 "$PID" >/dev/null 2>&1; then
    CMD="$(/bin/ps -p "$PID" -o command= 2>/dev/null || true)"
    echo "KILL $PID $CMD"
    /bin/kill -KILL "$PID" >/dev/null 2>&1 || true
  fi
done

# Wait briefly for pppd to tear down PPP interfaces and SystemConfiguration state.
I=0
while [ "$I" -lt 10 ]; do
  LEFT="$(/usr/bin/pgrep -f '/tmp/+sstp-pppd\.' 2>/dev/null || true)"
  [ -z "$LEFT" ] && break
  sleep 0.3
  I=$((I + 1))
done

echo
echo "--- Removing stale split-default routes from PPP interfaces seen before cleanup ---"
for PPP in $PPP_BEFORE; do
  for DEST in 0.0.0.0/1 128.0.0.0/1; do
    if /usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/awk -v ppp="$PPP" -v a="$DEST" '
      ($1 == a || ($1 == "0/1" && a == "0.0.0.0/1") || ($1 == "128.0/1" && a == "128.0.0.0/1")) {
        for (i=1; i<=NF; i++) if ($i == ppp) found=1
      }
      END { exit(found ? 0 : 1) }
    '; then
      echo "delete $DEST via $PPP"
      /sbin/route -n delete -net "$DEST" -interface "$PPP" >/dev/null 2>&1 || true
    fi
  done
done

if [ -n "$SERVER" ]; then
  echo
  echo "--- Removing explicit host route for $SERVER ---"
  /sbin/route -n delete -host "$SERVER" >/dev/null 2>&1 || true
fi

echo
echo "--- Removing temp/state files ---"
/bin/rm -f /tmp/sstp-pppd.* /tmp/sstp-gui-secret-* \
  /tmp/sstp-gui.pid /tmp/sstp-gui.state /tmp/sstp-gui-watchdog.pid \
  /tmp/sstp-gui-helper.pids /tmp/sstp-gui-helper.files /tmp/sstp-gui.stop \
  /tmp/sstp-gui.result 2>/dev/null || true

# If a PPP interface survives even though all sstp helper processes are gone,
# mark only interfaces that existed before this purge down. Do not touch utun.
for PPP in $PPP_BEFORE; do
  if /sbin/ifconfig "$PPP" >/dev/null 2>&1; then
    echo "forcing $PPP down"
    /sbin/ifconfig "$PPP" down >/dev/null 2>&1 || true
  fi
done

echo
echo "--- Refreshing DNS resolver cache ---"
/usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
/usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
sleep 1

echo
echo "--- After: SSTP helper processes ---"
LEFT_HELPERS="$(/usr/bin/pgrep -lf '/tmp/+sstp-pppd\.' 2>/dev/null || true)"
printf '%s\n' "${LEFT_HELPERS:-NONE}"

echo
echo "--- After: PPP interfaces ---"
PPP_AFTER="$(/sbin/ifconfig -l | /usr/bin/tr ' ' '\n' | /usr/bin/grep '^ppp[0-9]' 2>/dev/null || true)"
printf '%s\n' "${PPP_AFTER:-NONE}"

echo
echo "--- After: split-default routes ---"
SPLIT_AFTER="$(/usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/awk '$1=="0/1" || $1=="0.0.0.0/1" || $1=="128.0/1" || $1=="128.0.0.0/1" {print}')"
printf '%s\n' "${SPLIT_AFTER:-NONE}"

echo
echo "--- After: PPP DNS resolvers ---"
PPP_DNS="$(/usr/sbin/scutil --dns 2>/dev/null | /usr/bin/grep -B2 -A4 -E '\(ppp[0-9]+\)' || true)"
printf '%s\n' "${PPP_DNS:-NONE}"

if [ -n "$LEFT_HELPERS" ]; then
  echo
  echo "ERROR: SSTP helper processes are still alive"
  exit 2
fi

echo
echo "Cleanup complete"
exit 0
