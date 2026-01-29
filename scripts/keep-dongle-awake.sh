#!/usr/bin/env bash
set -euo pipefail

# Keeps a USB Ethernet dongle awake by generating periodic traffic.
#
# Config via env vars or CLI args:
#   TARGET   - IP/hostname to ping (default: default gateway, else 1.1.1.1)
#   INTERFACE- Network interface to bind to (optional)
#   METHOD   - Keepalive method: auto|icmp|arp (default: auto)
#   INTERVAL - Seconds between pings (default: 1)
#   TIMEOUT  - Ping timeout seconds (default: 1)
#
# Usage examples:
#   keep-dongle-awake.sh
#   TARGET=1.1.1.1 INTERVAL=1 keep-dongle-awake.sh
#   keep-dongle-awake.sh --interface enp0s20f0u2 --target 192.168.1.1 --interval 1

TARGET="${TARGET:-}"
INTERFACE="${INTERFACE:-}"
METHOD="${METHOD:-auto}"
INTERVAL="${INTERVAL:-1}"
TIMEOUT="${TIMEOUT:-1}"

usage() {
  cat <<'EOF'
Usage: keep-dongle-awake.sh [--target <ip|host>] [--interface <ifname>] [--interval <seconds>] [--timeout <seconds>]

Environment variables:
  TARGET, INTERFACE, METHOD, INTERVAL, TIMEOUT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"; shift 2 ;;
    --interface)
      INTERFACE="$2"; shift 2 ;;
    --method)
      METHOD="$2"; shift 2 ;;
    --interval)
      INTERVAL="$2"; shift 2 ;;
    --timeout)
      TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

is_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

if ! is_number "$INTERVAL"; then
  echo "INTERVAL must be a number (got: $INTERVAL)" >&2
  exit 2
fi
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "TIMEOUT must be an integer (got: $TIMEOUT)" >&2
  exit 2
fi

case "$METHOD" in
  auto|icmp|arp) ;;
  *)
    echo "METHOD must be one of: auto|icmp|arp (got: $METHOD)" >&2
    exit 2
    ;;
esac

get_default_gw() {
  # Outputs the default gateway IP if present.
  ip -4 route show default 2>/dev/null | awk '{print $3; exit}'
}

get_default_gw_for_dev() {
  local dev="$1"
  ip -4 route show default dev "$dev" 2>/dev/null | awk '{print $3; exit}'
}

carrier_up() {
  local ifname="$1"
  local carrier_file="/sys/class/net/${ifname}/carrier"
  [[ -r "$carrier_file" ]] || return 0
  [[ "$(cat "$carrier_file" 2>/dev/null || echo 0)" == "1" ]]
}

pick_target() {
  if [[ -n "$TARGET" ]]; then
    echo "$TARGET"
    return 0
  fi

  local gw
  if [[ -n "$INTERFACE" ]]; then
    gw="$(get_default_gw_for_dev "$INTERFACE" || true)"
  else
    gw=""
  fi
  if [[ -z "$gw" ]]; then
    gw="$(get_default_gw || true)"
  fi
  if [[ -n "$gw" ]]; then
    echo "$gw"
    return 0
  fi

  echo "1.1.1.1"
}

PING_BIN="$(command -v ping || true)"
ARPING_BIN="$(command -v arping || true)"

if [[ -z "$PING_BIN" ]]; then
  echo "ping not found in PATH" >&2
  exit 1
fi

log() {
  # systemd will capture stdout/stderr; keep logs short.
  echo "[$(date -Is)] $*"
}

log "Starting keepalive (METHOD=$METHOD, INTERFACE=${INTERFACE:-<none>}, INTERVAL=${INTERVAL}s, TIMEOUT=${TIMEOUT}s)"

while true; do
  if [[ -n "$INTERFACE" ]]; then
    # If carrier is down, avoid spamming; wait a bit.
    if ! carrier_up "$INTERFACE"; then
      sleep 2
      continue
    fi
  fi

  tgt="$(pick_target)"

  # Prefer a purely local keepalive when possible:
  # - METHOD=arp (or auto with INTERFACE set) will use arping to the gateway if arping is available.
  # - Otherwise, fall back to ICMP ping.
  if [[ "$METHOD" == "arp" ]] || [[ "$METHOD" == "auto" && -n "$INTERFACE" && -n "$ARPING_BIN" ]]; then
    if [[ -n "$INTERFACE" && -n "$ARPING_BIN" ]]; then
      "$ARPING_BIN" -I "$INTERFACE" -c 1 "$tgt" >/dev/null 2>&1 || true
    else
      "$PING_BIN" -n -c 1 -W "$TIMEOUT" "$tgt" >/dev/null 2>&1 || true
    fi
  else
    # Use -I only when an interface is specified.
    if [[ -n "$INTERFACE" ]]; then
      "$PING_BIN" -n -c 1 -W "$TIMEOUT" -I "$INTERFACE" "$tgt" >/dev/null 2>&1 || true
    else
      "$PING_BIN" -n -c 1 -W "$TIMEOUT" "$tgt" >/dev/null 2>&1 || true
    fi
  fi

  sleep "$INTERVAL"
done
