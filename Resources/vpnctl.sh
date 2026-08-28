#!/bin/bash
set -u
umask 077

ACTION="${1:-}"
SERVER="${2:-}"
USER_NAME="${3:-}"
SECRET_FILE="${4:-}"
CERT_MODE="${5:-ignore}"
CERT_FILE="${6:-}"
FULL_TUNNEL="${7:-1}"

LOG="/tmp/sstp-gui.log"
PIDFILE="/tmp/sstp-gui.pid"
STATEFILE="/tmp/sstp-gui.state"
RESULT="/tmp/sstp-gui.result"
WATCHDOG_PIDFILE="/tmp/sstp-gui-watchdog.pid"
WATCHDOG_LOG="/tmp/sstp-gui-watchdog.log"
STOPFILE="/tmp/sstp-gui.stop"

SSTPC=""
if [ -x /opt/homebrew/sbin/sstpc ]; then
  SSTPC="/opt/homebrew/sbin/sstpc"
elif [ -x /usr/local/sbin/sstpc ]; then
  SSTPC="/usr/local/sbin/sstpc"
fi

write_result() {
  printf '%s\n' "$1" > "$RESULT"
  chmod 0644 "$RESULT" 2>/dev/null || true
}

cleanup_test_routes() {
  /sbin/route -n delete -host 1.1.1.1 >/dev/null 2>&1 || true
  /sbin/route -n delete -host 1.0.0.1 >/dev/null 2>&1 || true
}

stop_watchdog() {
  : > "$STOPFILE"
  chmod 0644 "$STOPFILE" 2>/dev/null || true

  if [ -f "$WATCHDOG_PIDFILE" ]; then
    WD_PID="$(cat "$WATCHDOG_PIDFILE" 2>/dev/null || true)"
    if [ -n "${WD_PID:-}" ] && kill -0 "$WD_PID" >/dev/null 2>&1; then
      kill -TERM "$WD_PID" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$WATCHDOG_PIDFILE"
}

kill_owned_client() {
  if [ -f "$PIDFILE" ]; then
    PID="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "${PID:-}" ] && kill -0 "$PID" >/dev/null 2>&1; then
      kill -TERM "$PID" >/dev/null 2>&1 || true
      sleep 1
      kill -KILL "$PID" >/dev/null 2>&1 || true
    fi
  fi
}

delete_owned_routes() {
  cleanup_test_routes
  /sbin/route -n delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
  /sbin/route -n delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
  if [ -n "$SERVER" ]; then
    /sbin/route -n delete -host "$SERVER" >/dev/null 2>&1 || true
  fi
}

cleanup_all() {
  stop_watchdog
  delete_owned_routes
  kill_owned_client
  rm -f "$PIDFILE" "$STATEFILE"
}

fail() {
  MSG="$1"
  cleanup_all
  write_result "FAIL|$MSG"
  exit 0
}

list_ppp() {
  /sbin/ifconfig -l | /usr/bin/tr ' ' '\n' | /usr/bin/grep '^ppp[0-9]' 2>/dev/null || true
}

find_new_ppp() {
  BEFORE="$1"
  CURRENT="$(list_ppp)"
  for P in $CURRENT; do
    if ! printf '%s\n' "$BEFORE" | /usr/bin/grep -qx "$P"; then
      printf '%s\n' "$P"
      return
    fi
  done
}

probe_via_ppp() {
  PPP="$1"
  for PROBE in 1.1.1.1 1.0.0.1; do
    if /sbin/route -n add -host "$PROBE" -interface "$PPP" >/dev/null 2>&1; then
      if /usr/bin/nc -z -G 5 "$PROBE" 443 >/dev/null 2>&1; then
        /sbin/route -n delete -host "$PROBE" >/dev/null 2>&1 || true
        return 0
      fi
      /sbin/route -n delete -host "$PROBE" >/dev/null 2>&1 || true
    fi
  done
  return 1
}

conflicting_full_tunnel_routes() {
  /usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/awk '
    ($1 == "0/1" || $1 == "0.0.0.0/1" || $1 == "128.0/1" || $1 == "128.0.0.0/1") { print }
  '
}

watchdog_cleanup_after_crash() {
  [ -f "$STATEFILE" ] || return 0

  STATE="$(cat "$STATEFILE" 2>/dev/null || true)"
  OLD_IFS="$IFS"
  IFS='|'
  set -- $STATE
  IFS="$OLD_IFS"

  PPP="${1:-}"
  PHY="${2:-}"
  GW="${3:-}"
  SAVED_SERVER="${4:-}"

  if [ -n "$PPP" ]; then
    ROUTES="$(conflicting_full_tunnel_routes)"
    if printf '%s\n' "$ROUTES" | /usr/bin/grep -qE "(^|[[:space:]])${PPP}([[:space:]]|$)"; then
      /sbin/route -n delete -net 0.0.0.0/1 >/dev/null 2>&1 || true
      /sbin/route -n delete -net 128.0.0.0/1 >/dev/null 2>&1 || true
    fi
  fi

  cleanup_test_routes

  if [ -n "$SAVED_SERVER" ]; then
    ROUTE_INFO="$(/sbin/route -n get "$SAVED_SERVER" 2>/dev/null || true)"
    ROUTE_GW="$(printf '%s\n' "$ROUTE_INFO" | /usr/bin/awk '/gateway:/{print $2; exit}')"
    ROUTE_IF="$(printf '%s\n' "$ROUTE_INFO" | /usr/bin/awk '/interface:/{print $2; exit}')"
    if [ -n "$GW" ] && [ -n "$PHY" ] && [ "$ROUTE_GW" = "$GW" ] && [ "$ROUTE_IF" = "$PHY" ]; then
      /sbin/route -n delete -host "$SAVED_SERVER" >/dev/null 2>&1 || true
    fi
  fi

  rm -f "$PIDFILE" "$STATEFILE" "$WATCHDOG_PIDFILE"
  write_result "FAIL|VPN disconnected unexpectedly; routing restored automatically"
}

case "$ACTION" in
  watchdog)
    rm -f "$STOPFILE"
    while true; do
      [ -f "$STOPFILE" ] && exit 0
      [ -f "$PIDFILE" ] || exit 0

      PID="$(cat "$PIDFILE" 2>/dev/null || true)"
      [ -n "$PID" ] || exit 0

      if kill -0 "$PID" >/dev/null 2>&1; then
        COMM="$(/bin/ps -p "$PID" -o comm= 2>/dev/null || true)"
        if printf '%s' "$COMM" | /usr/bin/grep -q 'sstpc'; then
          sleep 3
          continue
        fi
      fi

      [ -f "$STOPFILE" ] && exit 0
      watchdog_cleanup_after_crash
      exit 0
    done
    ;;

  repair|disconnect)
    cleanup_all
    rm -f "$STOPFILE"
    write_result "OFF|Disconnected"
    exit 0
    ;;

  connect)
    [ -n "$SERVER" ] || fail "Server is empty"
    [ -n "$USER_NAME" ] || fail "Username is empty"
    [ -n "$SSTPC" ] || fail "sstpc was not found"
    [ -f "$SECRET_FILE" ] || fail "Password handoff file was not found"

    PASSWORD="$(cat "$SECRET_FILE")"
    rm -f "$SECRET_FILE"
    [ -n "$PASSWORD" ] || fail "Password is empty"

    if [ "$CERT_MODE" = "verify" ] && [ ! -f "$CERT_FILE" ]; then
      fail "Certificate file was not found"
    fi

    cleanup_all
    rm -f "$STOPFILE"
    sleep 1

    BASE_IF="$(/sbin/route -n get 1.1.1.1 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}')"
    if [ "$FULL_TUNNEL" = "1" ] && printf '%s' "$BASE_IF" | /usr/bin/grep -q '^ppp'; then
      fail "Another PPP/VPN full tunnel is already active on $BASE_IF. Disconnect the other VPN first."
    fi

    CONFLICT_ROUTES="$(conflicting_full_tunnel_routes)"
    if [ "$FULL_TUNNEL" = "1" ] && [ -n "$CONFLICT_ROUTES" ]; then
      fail "Existing split-default VPN routes (0/1 or 128/1) were found. They may be leftovers from another VPN. Use Diagnostics to identify them or disconnect/repair the other VPN first."
    fi

    GW="$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/gateway:/{print $2; exit}')"
    PHY="$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}')"
    [ -n "$GW" ] && [ -n "$PHY" ] || fail "Physical default gateway was not found"

    /sbin/route -n delete -host "$SERVER" >/dev/null 2>&1 || true
    /sbin/route -n add -host "$SERVER" "$GW" >/dev/null 2>&1 || fail "Could not pin VPN server route"

    SERVER_IF="$(/sbin/route -n get "$SERVER" 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}')"
    [ "$SERVER_IF" = "$PHY" ] || fail "VPN server route points to unexpected interface $SERVER_IF"

    PPP_BEFORE="$(list_ppp)"
    rm -f "$LOG" "$PIDFILE" "$STATEFILE" "$WATCHDOG_LOG"
    : > "$LOG"
    chmod 0644 "$LOG" 2>/dev/null || true

    if [ "$CERT_MODE" = "verify" ]; then
      "$SSTPC" --log-stderr --log-level 4 --ca-cert "$CERT_FILE" \
        --user "$USER_NAME" --password "$PASSWORD" "$SERVER" \
        usepeerdns require-mschap-v2 noauth >"$LOG" 2>&1 </dev/null &
    else
      "$SSTPC" --log-stderr --log-level 4 --cert-warn \
        --user "$USER_NAME" --password "$PASSWORD" "$SERVER" \
        usepeerdns require-mschap-v2 noauth >"$LOG" 2>&1 </dev/null &
    fi

    SSTP_PID=$!
    unset PASSWORD
    printf '%s\n' "$SSTP_PID" > "$PIDFILE"
    chmod 0644 "$PIDFILE" 2>/dev/null || true

    PPP=""
    I=0
    while [ "$I" -lt 25 ]; do
      if ! kill -0 "$SSTP_PID" >/dev/null 2>&1; then
        LAST="$(tail -n 4 "$LOG" 2>/dev/null | tr '\n' ' ')"
        fail "sstpc exited: $LAST"
      fi

      if grep -q "Connection Established" "$LOG" 2>/dev/null; then
        PPP="$(find_new_ppp "$PPP_BEFORE")"
        [ -n "$PPP" ] && break
      fi
      sleep 1
      I=$((I + 1))
    done

    [ -n "$PPP" ] || fail "SSTP connected, but no new PPP interface appeared"

    if ! probe_via_ppp "$PPP"; then
      fail "PPP is up, but internet test through this PPP failed"
    fi

    if [ "$FULL_TUNNEL" = "1" ]; then
      /sbin/route -n add -net 0.0.0.0/1 -interface "$PPP" >/dev/null 2>&1 || fail "Could not add 0.0.0.0/1"
      /sbin/route -n add -net 128.0.0.0/1 -interface "$PPP" >/dev/null 2>&1 || fail "Could not add 128.0.0.0/1"

      INTERNET_IF="$(/sbin/route -n get 1.1.1.1 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}')"
      [ "$INTERNET_IF" = "$PPP" ] || fail "Full tunnel did not become active"

      SERVER_IF="$(/sbin/route -n get "$SERVER" 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}')"
      [ "$SERVER_IF" != "$PPP" ] || fail "VPN server was routed into its own tunnel"

      if ! /usr/bin/nc -z -G 5 1.1.1.1 443 >/dev/null 2>&1; then
        fail "Internet is unavailable after enabling full tunnel"
      fi
    fi

    printf '%s|%s|%s|%s\n' "$PPP" "$PHY" "$GW" "$SERVER" > "$STATEFILE"
    chmod 0644 "$STATEFILE" 2>/dev/null || true
    write_result "OK|$PPP|$PHY|$GW"

    rm -f "$STOPFILE"
    /bin/bash "$0" watchdog "$SERVER" >"$WATCHDOG_LOG" 2>&1 </dev/null &
    WD_PID=$!
    printf '%s\n' "$WD_PID" > "$WATCHDOG_PIDFILE"
    chmod 0644 "$WATCHDOG_PIDFILE" "$WATCHDOG_LOG" 2>/dev/null || true

    exit 0
    ;;

  *)
    write_result "FAIL|Unknown action"
    exit 0
    ;;
esac
