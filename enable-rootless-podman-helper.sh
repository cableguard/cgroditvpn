#!/usr/bin/env bash
# Ensure rootless Podman is reachable from systemd timers after boot/reboot.
# Enables user linger and podman.socket for INFRA_USER (or MONITOR_USER).
#
# Usage:
#   sudo ./enable-rootless-podman-helper.sh enable
#   ./enable-rootless-podman-helper.sh status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

TARGET_USER="${MONITOR_USER:-$INFRA_USER}"

usage() {
  cat <<EOF
Usage: sudo $0 enable
       $0 status

Ensures rootless Podman survives logout and reboot:
  1. loginctl enable-linger for $TARGET_USER
  2. systemctl --user enable --now podman.socket (as $TARGET_USER)
  3. Lower net.ipv4.ip_unprivileged_port_start when an API port is below 1024 (OpenClaw :88)

Called automatically by manage-monitoring-pods.sh install and golive.sh.
EOF
}

require_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    echo "Error: enable requires root (sudo)." >&2
    exit 1
  fi
}

run_as_user() {
  local uid
  uid="$(id -u "$TARGET_USER")"
  if [[ "$(id -un 2>/dev/null || true)" == "$TARGET_USER" ]]; then
    env \
      XDG_RUNTIME_DIR="/run/user/${uid}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
      HOME="$INFRA_HOME" \
      "$@"
    return
  fi
  runuser -u "$TARGET_USER" -- env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    HOME="$INFRA_HOME" \
    "$@"
}

# Rootless Podman cannot publish host ports below net.ipv4.ip_unprivileged_port_start
# (Alma default 1024). OpenClaw agents listen on 88 (Telegram Bot API webhook port).
infra_apply_unprivileged_port_start() {
  local min_port=1024
  local p
  local conf=/etc/sysctl.d/99-infra-unprivileged-ports.conf
  local -a ports=()

  if declare -p INFRA_PUBLIC_API_TCP_PORTS &>/dev/null; then
    ports+=("${INFRA_PUBLIC_API_TCP_PORTS[@]}")
  fi
  for p in "${ports[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    if (( p < min_port )); then
      min_port=$p
    fi
  done
  if (( min_port >= 1024 )); then
    return 0
  fi
  echo "Setting net.ipv4.ip_unprivileged_port_start=${min_port} (rootless publish of API ports)..."
  printf 'net.ipv4.ip_unprivileged_port_start=%s\n' "$min_port" >"$conf"
  sysctl -w "net.ipv4.ip_unprivileged_port_start=${min_port}" >/dev/null
}

cmd_enable() {
  require_root
  if ! id "$TARGET_USER" &>/dev/null; then
    echo "Error: user $TARGET_USER does not exist." >&2
    exit 1
  fi
  if ! command -v runuser >/dev/null 2>&1; then
    echo "Error: runuser not found." >&2
    exit 1
  fi
  if ! command -v podman >/dev/null 2>&1; then
    echo "Error: podman is not installed (podman.socket unit missing)." >&2
    echo "Install prerequisites, then re-run:" >&2
    echo "  sudo dnf install -y podman jq" >&2
    echo "  sudo $0 enable" >&2
    exit 1
  fi

  infra_apply_unprivileged_port_start

  echo "Enabling linger for $TARGET_USER..."
  loginctl enable-linger "$TARGET_USER"

  echo "Enabling podman.socket for $TARGET_USER..."
  run_as_user systemctl --user enable --now podman.socket

  if run_as_user systemctl --user is-active --quiet podman.socket; then
    echo "✓ podman.socket is active"
  else
    echo "✗ podman.socket failed to start" >&2
    run_as_user systemctl --user status podman.socket --no-pager || true
    exit 1
  fi
}

cmd_status() {
  local uid sock linger socket_state
  uid="$(id -u "$TARGET_USER" 2>/dev/null || echo "?")"
  sock="/run/user/${uid}/podman/podman.sock"

  linger="$(loginctl show-user "$TARGET_USER" -p Linger --value 2>/dev/null || echo unknown)"
  echo "User:           $TARGET_USER (uid $uid)"
  echo "Linger:         $linger"
  echo "Socket path:    $sock"
  if [[ -S "$sock" ]]; then
    echo "Socket present: yes"
  else
    echo "Socket present: no"
  fi

  if command -v runuser >/dev/null 2>&1 && id "$TARGET_USER" &>/dev/null; then
    socket_state="$(run_as_user systemctl --user is-active podman.socket 2>/dev/null || echo inactive)"
    enabled="$(run_as_user systemctl --user is-enabled podman.socket 2>/dev/null || echo disabled)"
    echo "podman.socket:  $socket_state (enabled: $enabled)"
    if run_as_user podman info >/dev/null 2>&1; then
      echo "podman info:    ok"
    else
      echo "podman info:    unavailable"
    fi
  fi
}

ACTION="${1:-status}"
case "$ACTION" in
  enable) cmd_enable ;;
  status) cmd_status ;;
  -h|--help|help) usage ;;
  *)
    usage
    exit 1
    ;;
esac
