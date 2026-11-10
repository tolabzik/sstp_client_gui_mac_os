#!/bin/bash
# Pure configuration helpers. Sourcing this file does not change the network.

trim_config_value() {
  local value="$1"
  local LC_ALL=C
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

parse_server_endpoint() {
  local server port host label octet host_without_dot
  local LC_ALL=C
  local -a labels octets
  server="$(trim_config_value "$1")"
  port="$(trim_config_value "${2-443}")"
  CONFIG_ERROR=""
  SERVER_HOST=""
  SERVER_PORT=""
  SSTP_TARGET=""

  case "$server" in
    *:*:*) CONFIG_ERROR="IPv6 VPN server addresses are not supported"; return 1 ;;
    *:*) port="${server##*:}"; server="${server%:*}" ;;
  esac
  host="$server"
  if [ -z "$host" ] || [[ "$host" == *[!a-zA-Z0-9.-]* ]]; then
    CONFIG_ERROR="Enter a hostname or IPv4 address, without a URL or spaces"
    return 1
  fi
  host_without_dot="${host%.}"
  if [ -z "$host_without_dot" ] || [ "${#host_without_dot}" -gt 253 ] || [[ "$host_without_dot" == *..* ]]; then
    CONFIG_ERROR="Invalid VPN server hostname"
    return 1
  fi
  IFS='.' read -r -a labels <<< "$host_without_dot"
  for label in "${labels[@]}"; do
    if [ -z "$label" ] || [ "${#label}" -gt 63 ] || [[ "$label" == -* ]] || [[ "$label" == *- ]]; then
      CONFIG_ERROR="Invalid VPN server hostname"
      return 1
    fi
  done
  if [[ "$host" != *[!0-9.]* ]]; then
    IFS='.' read -r -a octets <<< "$host"
    if [ "${#octets[@]}" -ne 4 ] || [[ "$host" == *. ]]; then
      CONFIG_ERROR="Invalid IPv4 VPN server address"
      return 1
    fi
    for octet in "${octets[@]}"; do
      if [ -z "$octet" ] || [ "${#octet}" -gt 3 ] || [ "$((10#$octet))" -gt 255 ]; then
        CONFIG_ERROR="Invalid IPv4 VPN server address"
        return 1
      fi
    done
  fi
  if [ -z "$port" ] || [[ "$port" == *[!0-9]* ]]; then
    CONFIG_ERROR="Port must be a number from 1 to 65535"
    return 1
  fi
  while [ "${#port}" -gt 1 ] && [[ "$port" == 0* ]]; do port="${port#0}"; done
  if [ "${#port}" -gt 5 ]; then
    CONFIG_ERROR="Port must be a number from 1 to 65535"
    return 1
  fi
  port="$((10#$port))"
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    CONFIG_ERROR="Port must be a number from 1 to 65535"
    return 1
  fi
  SERVER_HOST="$host"
  SERVER_PORT="$port"
  SSTP_TARGET="$host:$port"
}

resolve_certificate() {
  local mode="$1" file="$2"
  CONFIG_ERROR=""
  RESOLVED_CERT_FILE=""
  case "$mode" in
    ignore) return 0 ;;
    verify)
      # Stock sstp-client does not combine certificate-chain and hostname
      # verification when --ca-cert is supplied. Do not silently broaden trust
      # to the system CA bundle until that dependency behavior is corrected.
      if [ -z "$file" ]; then
        CONFIG_ERROR="Select an explicit CA/server certificate file. Automatic public CA trust requires a hostname-verification fix in sstp-client."
        return 1
      fi
      if [ ! -f "$file" ] || [ ! -r "$file" ]; then
        CONFIG_ERROR="CA certificate file was not found or is not readable: $file"
        return 1
      fi
      RESOLVED_CERT_FILE="$file"
      ;;
    *) CONFIG_ERROR="Unknown certificate verification mode"; return 1 ;;
  esac
}

validate_sstpc_password() {
  # Stock sstp-client writes this into a quoted pppd options file without
  # escaping. Escaping --password here would change its MPPE key derivation.
  # Fail before the dependency can corrupt the secret or print a fragment.
  # Its 255-byte output buffer also needs 12 bytes of syntax plus the NUL.
  local password="$1"
  local LC_ALL=C
  CONFIG_ERROR=""
  if [ -z "$password" ]; then
    CONFIG_ERROR="Password is empty"
    return 1
  fi
  case "$password" in
    *'"'*|*'\'*|*$'\r'*|*$'\n'*)
      CONFIG_ERROR="The installed sstp-client cannot safely handle passwords containing quotes, backslashes or line breaks. A dependency fix is required."
      return 1
      ;;
  esac
  if [ "${#password}" -gt 242 ]; then
    CONFIG_ERROR="The installed sstp-client cannot safely handle passwords longer than 242 bytes. A dependency fix is required."
    return 1
  fi
}

read_sstpc_password() {
  local file="$1" bytes
  local LC_ALL=C
  CONFIG_ERROR=""
  PASSWORD=""
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    CONFIG_ERROR="Password handoff file was not found or is not readable"
    return 1
  fi
  # The sentinel preserves trailing newlines so validation can reject them.
  PASSWORD="$(cat "$file" && printf '.')" || {
    CONFIG_ERROR="Could not read password handoff file"
    return 1
  }
  PASSWORD="${PASSWORD%.}"
  bytes="$(/usr/bin/wc -c < "$file")" || {
    CONFIG_ERROR="Could not read password handoff file"
    return 1
  }
  # Bash cannot represent NUL bytes; detect them rather than silently change
  # a credential supplied through a direct controller invocation.
  if [ "$bytes" -ne "${#PASSWORD}" ]; then
    CONFIG_ERROR="Passwords containing NUL bytes are not supported"
    PASSWORD=""
    return 1
  fi
  validate_sstpc_password "$PASSWORD"
}
