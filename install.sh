#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPT_SRC="$REPO_DIR/scripts/keep-dongle-awake.sh"
UNIT_SRC="$REPO_DIR/systemd/keep-dongle-awake.service"

SCRIPT_DST="/usr/local/bin/keep-dongle-awake.sh"
UNIT_DST="/etc/systemd/system/keep-dongle-awake.service"
ENV_DST="/etc/default/keep-dongle-awake"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "This installer needs root (to write $SCRIPT_DST, $UNIT_DST, $ENV_DST)."
  echo "Re-running with sudo..."
  exec sudo -E -- "$0" "$@"
fi

need_cmd install
need_cmd systemctl
need_cmd ip
need_cmd awk
need_cmd sed
need_cmd ping

if [[ ! -f "$SCRIPT_SRC" ]]; then
  die "Not found: $SCRIPT_SRC"
fi
if [[ ! -f "$UNIT_SRC" ]]; then
  die "Not found: $UNIT_SRC"
fi

get_default_gw() {
  ip -4 route show default 2>/dev/null | awk '{print $3; exit}'
}

get_default_gw_for_dev() {
  local dev="$1"
  ip -4 route show default dev "$dev" 2>/dev/null | awk '{print $3; exit}'
}

carrier_status() {
  local dev="$1"
  local f="/sys/class/net/${dev}/carrier"
  if [[ -r "$f" ]]; then
    if [[ "$(cat "$f" 2>/dev/null || echo 0)" == "1" ]]; then
      echo "up"
    else
      echo "down"
    fi
  else
    echo "unknown"
  fi
}

link_state() {
  local dev="$1"
  ip -o link show "$dev" 2>/dev/null | awk -F': ' '{print $3}' | awk '{print $1}'
}

is_usb_iface() {
  local dev="$1"
  if command -v udevadm >/dev/null 2>&1; then
    local path
    path="$(udevadm info -q path -n "$dev" 2>/dev/null || true)"
    [[ "$path" == *"/usb"* ]] && return 0
  fi
  return 1
}

list_ifaces() {
  # Exclude lo
  (cd /sys/class/net && ls -1) | sed '/^lo$/d'
}

prompt_iface() {
  local ifaces=()
  while IFS= read -r dev; do
    [[ -n "$dev" ]] || continue
    ifaces+=("$dev")
  done < <(list_ifaces)

  if [[ ${#ifaces[@]} -eq 0 ]]; then
    warn "No network interfaces found (besides lo)."
    echo ""
    return 0
  fi

  bold "Select the interface for your USB Ethernet dongle (recommended)"
  echo "(Choose the interface that appears when you plug in the dongle; you can also choose 'none'.)"
  echo

  local i
  for i in "${!ifaces[@]}"; do
    local dev="${ifaces[$i]}"
    local carrier="$(carrier_status "$dev")"
    local state="$(link_state "$dev")"
    local usb_hint=""
    if is_usb_iface "$dev"; then
      usb_hint=" usb"
    fi
    printf "  [%d] %s (state=%s, carrier=%s)%s\n" "$((i+1))" "$dev" "${state:-?}" "$carrier" "$usb_hint"
  done
  echo "  [0] none (do not bind ping to an interface)"
  echo

  local choice
  while true; do
    read -r -p "Enter choice [0-${#ifaces[@]}]: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Please enter a number."; continue; }
    if [[ "$choice" == "0" ]]; then
      echo ""
      return 0
    fi
    if (( choice >= 1 && choice <= ${#ifaces[@]} )); then
      echo "${ifaces[$((choice-1))]}"
      return 0
    fi
    echo "Out of range."
  done
}

prompt_target() {
  local dev="${1:-}"
  local gw=""

  if [[ -n "$dev" ]]; then
    gw="$(get_default_gw_for_dev "$dev" || true)"
  fi
  if [[ -z "$gw" ]]; then
    gw="$(get_default_gw || true)"
  fi

  bold "Select ping target"
  echo "A local target (like your default gateway) usually works best." 
  echo

  local options=()
  if [[ -n "$gw" ]]; then
    options+=("$gw")
  fi
  options+=("1.1.1.1" "8.8.8.8" "custom")

  local i
  for i in "${!options[@]}"; do
    printf "  [%d] %s\n" "$((i+1))" "${options[$i]}"
  done
  echo

  local choice
  while true; do
    read -r -p "Enter choice [1-${#options[@]}]: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Please enter a number."; continue; }
    if (( choice >= 1 && choice <= ${#options[@]} )); then
      local picked="${options[$((choice-1))]}"
      if [[ "$picked" == "custom" ]]; then
        local custom
        read -r -p "Enter target IP/hostname: " custom
        [[ -n "$custom" ]] || { echo "Target cannot be empty."; continue; }
        echo "$custom"
        return 0
      fi
      echo "$picked"
      return 0
    fi
    echo "Out of range."
  done
}

prompt_number() {
  local prompt="$1"
  local default="$2"
  local value
  while true; do
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      echo "$value"
      return 0
    fi
    echo "Please enter a number."
  done
}

prompt_int() {
  local prompt="$1"
  local default="$2"
  local value
  while true; do
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      echo "$value"
      return 0
    fi
    echo "Please enter an integer."
  done
}

prompt_yes_no() {
  local prompt="$1"
  local default_yes="$2" # "yes" or "no"
  local suffix
  if [[ "$default_yes" == "yes" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi
  local ans
  while true; do
    read -r -p "$prompt $suffix: " ans
    ans="${ans,,}"
    if [[ -z "$ans" ]]; then
      [[ "$default_yes" == "yes" ]] && return 0 || return 1
    fi
    case "$ans" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

bold "dongle-insomnia installer"
echo

iface="$(prompt_iface)"
target="$(prompt_target "$iface")"
interval="$(prompt_number "Ping interval seconds" "1")"
timeout="$(prompt_int "Ping timeout seconds" "1")"

echo
bold "Summary"
echo "  INTERFACE=${iface:-<none>}"
echo "  TARGET=$target"
echo "  INTERVAL=$interval"
echo "  TIMEOUT=$timeout"
echo

if ! prompt_yes_no "Proceed with install/update?" "yes"; then
  echo "Aborted."
  exit 0
fi

echo
bold "Installing script"
install -m 0755 "$SCRIPT_SRC" "$SCRIPT_DST"

bold "Installing systemd unit"
install -m 0644 "$UNIT_SRC" "$UNIT_DST"

bold "Writing config $ENV_DST"
cat >"$ENV_DST" <<EOF
# Generated by dongle-insomnia installer
TARGET=$target
INTERFACE=${iface}
INTERVAL=$interval
TIMEOUT=$timeout
EOF
chmod 0644 "$ENV_DST"

bold "Reloading systemd"
systemctl daemon-reload

if prompt_yes_no "Enable and start keep-dongle-awake.service now?" "yes"; then
  systemctl enable --now keep-dongle-awake.service
  echo
  systemctl --no-pager --full status keep-dongle-awake.service || true
else
  echo "You can enable later with: systemctl enable --now keep-dongle-awake.service"
fi

echo
bold "Done"
echo "Logs: journalctl -u keep-dongle-awake.service -f"
