#!/bin/bash

# macOS pppd accepts an explicit serviceid and publishes its transient state
# below State:/Network/Service/<serviceid>. Never infer ownership from pppN:
# interface numbers can be reused, and another VPN may own older records.
# Apple implementation: apple-oss-distributions/ppp, Helpers/pppd/sys-MacOSX.c.

valid_sstp_service_id() {
  [[ "$1" =~ ^sstp-gui-[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]]
}

service_file_is_owned() {
  [ -f "$SERVICEFILE" ] && [ ! -L "$SERVICEFILE" ] && [ -O "$SERVICEFILE" ] || return 1
  case "$(/usr/bin/stat -f '%Lp' "$SERVICEFILE" 2>/dev/null)" in
    400|600) return 0 ;;
    *) return 1 ;;
  esac
}

create_owned_service_id() {
  local generated
  generated="sstp-gui-$(/usr/bin/uuidgen)"
  valid_sstp_service_id "$generated" || return 1
  # Do not overwrite a previous session that still requires cleanup, or follow
  # an unexpected file/symlink in the shared temporary directory.
  (umask 077; set -o noclobber; printf '%s\n' "$generated" > "$SERVICEFILE") 2>/dev/null || return 1
  SERVICE_ID="$generated"
}

service_pppd_pids() {
  valid_sstp_service_id "$1" || return 2
  /usr/bin/pgrep -f "(^|[[:space:]])serviceid[[:space:]]+$1([[:space:]]|$)" 2>/dev/null
}

service_pppd_running() {
  # Includes the SSTP parent carrying forwarded PPP arguments: do not remove
  # state while either process could still create or republish this service.
  service_pppd_pids "$1" >/dev/null
}

service_scutil() {
  /usr/sbin/scutil
}

cleanup_owned_service() {
  local owned_id entity remaining
  [ -e "$SERVICEFILE" ] || { [ ! -L "$SERVICEFILE" ]; return; }
  service_file_is_owned || return 1
  owned_id="$(cat "$SERVICEFILE" 2>/dev/null)"
  valid_sstp_service_id "$owned_id" || return 1
  # pppd normally removes these records itself. If it needed SIGKILL, only its
  # explicitly assigned namespace is ours to remove. Keep the record for Repair
  # if the process is still alive; it could otherwise republish stale DNS.
  if service_pppd_running "$owned_id"; then
    return 1
  else
    # pgrep status 1 means no matching process; errors are not proof of exit.
    [ "$?" -eq 1 ] || return 1
  fi
  {
    for entity in DNS IPv4 IPv6 PPP Proxies SMB Interface; do
      printf 'remove State:/Network/Service/%s/%s\n' "$owned_id" "$entity"
    done
  } | service_scutil >/dev/null 2>&1 || return 1
  remaining="$(printf 'list State:/Network/Service/%s/.*\n' "$owned_id" | service_scutil 2>/dev/null)" || return 1
  if printf '%s\n' "$remaining" | /usr/bin/grep -Fq "State:/Network/Service/$owned_id/"; then
    return 1
  fi
  /bin/rm -f "$SERVICEFILE"
}
