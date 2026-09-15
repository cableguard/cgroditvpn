#!/usr/bin/env bash
# Dev go-live helper: enable reboot persistence and liveness checks.
#
# Usage:
#   sudo ./golive.sh
#   sudo ./golive.sh --with-port-forwarding
#
# This is intentionally scoped for dev for now. It does not issue certificates,
# harden SSH, prune disks, or scan images.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"
# shellcheck source=infra-podman-helper.sh
source "$SCRIPT_DIR/infra-podman-helper.sh"

WITH_PORT_FORWARDING=false

usage() {
  cat <<EOF
Usage: sudo $0 [--with-port-forwarding]

Dev go-live sequence:
  1. Install and enable Podman liveness monitoring.
  2. Enable rootless Podman socket (survives reboot; lowers unprivileged port start if needed).
  3. Install and enable weekly maintenance timers.
  4. Install and enable hourly host uptime checks.
  5. Set existing Podman containers to restart unless stopped.
  6. Restart API stacks in dependency order.
  7. Ensure Grafana/Loki monitoring pod is running.
  8. Persist host firewall allowlist from infra-app (iptables INFRA_HOST_FW).
  9. Print monitoring, uptime, firewall, and container status.

Options:
  --with-port-forwarding  Also persist iptables 443->${INFRA_PORT_FORWARD_DEST} REDIRECT
                          (${INFRA_PORT_FORWARD_SERVICE}). Host firewall is always persisted.
  -h, --help              Show this help.
EOF
}

log() {
  printf '\n== %s ==\n' "$1"
}

require_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    echo "Run as root: sudo $0 $*" >&2
    exit 1
  fi
}

run_step() {
  local label="$1"
  shift
  log "$label"
  "$@"
}

# Podman rootless stores are per-user; when golive runs under sudo, invoke podman as INFRA_USER.
run_as_infra_user() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    "$@"
    return
  fi
  if ! command -v runuser >/dev/null 2>&1 || ! id "$INFRA_USER" &>/dev/null; then
    echo "Error: cannot run as $INFRA_USER (need runuser and a valid user)" >&2
    return 1
  fi
  local uid
  uid="$(id -u "$INFRA_USER")"
  runuser -u "$INFRA_USER" -- env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    HOME="$INFRA_HOME" \
    "$@"
}

install_pod_monitor() {
  export MONITOR_USER="${MONITOR_USER:-$INFRA_USER}"
  # manage-monitoring-pods.sh asks whether to run a test and configure
  # logrotate. For dev go-live, answer no/no and leave those as manual choices.
  printf 'n\nn\n' | "$SCRIPT_DIR/manage-monitoring-pods.sh" install
}

set_podman_restart_policy() {
  if ! run_as_infra_user podman --version >/dev/null 2>&1; then
    echo "podman not found for $INFRA_USER; skipping container restart policy."
    return 0
  fi

  local -a containers=()
  mapfile -t containers < <(
    run_as_infra_user podman ps -a --format '{{.Names}}' | sed '/^$/d'
  )
  if [[ ${#containers[@]} -eq 0 ]]; then
    echo "No Podman containers found for $INFRA_USER."
    return 0
  fi

  echo "Setting restart=unless-stopped on ${#containers[@]} container(s) for $INFRA_USER."
  local c
  for c in "${containers[@]}"; do
    run_as_infra_user podman update --restart=unless-stopped "$c"
  done
  infra_enable_podman_boot_autostart "$INFRA_USER"
}

enable_host_firewall() {
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "Disabling firewalld (required for iptables host firewall)..."
    systemctl disable --now firewalld
  fi
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y iptables-services
  fi
  systemctl enable --now iptables
  "$SCRIPT_DIR/configure-host-firewall-oneoff.sh" enable permanent
}

enable_port_forwarding() {
  "$SCRIPT_DIR/configure-port-forwarding-oneoff.sh" enable permanent
}

print_status() {
  "$SCRIPT_DIR/enable-rootless-podman-helper.sh" status || true
  "$SCRIPT_DIR/manage-monitoring-pods.sh" status || true
  "$SCRIPT_DIR/manage-weekly-maintenance.sh" status || true
  "$SCRIPT_DIR/host-uptime-prep.sh" status || true
  "$SCRIPT_DIR/configure-host-firewall-oneoff.sh" status || true
  run_as_infra_user podman ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
}

for arg in "$@"; do
  case "$arg" in
    --with-port-forwarding) WITH_PORT_FORWARDING=true ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $arg" >&2
      usage
      exit 1
      ;;
  esac
done

require_root "$@"

log "Dev Go-Live"
echo "Repo: $INFRA_REPO"
echo "User: $INFRA_USER"
echo "Home: $INFRA_HOME"

run_step "Install and enable Podman liveness monitoring" install_pod_monitor
run_step "Enable rootless Podman socket" env MONITOR_USER="$INFRA_USER" "$SCRIPT_DIR/enable-rootless-podman-helper.sh" enable
run_step "Install weekly maintenance timers" "$SCRIPT_DIR/manage-weekly-maintenance.sh" install
run_step "Install host uptime timer" "$SCRIPT_DIR/host-uptime-prep.sh" init
run_step "Enable host uptime timer" "$SCRIPT_DIR/host-uptime-prep.sh" enable-permanent
run_step "Set Podman containers to restart unless stopped" set_podman_restart_policy
run_step "Restart API stacks" run_as_infra_user bash "$SCRIPT_DIR/restart-containers-apis.sh"
run_step "Ensure Grafana/Loki monitoring pod is running" \
  run_as_infra_user bash "$SCRIPT_DIR/start-monitoring-pod.sh"

run_step "Persist host firewall allowlist" enable_host_firewall
if [[ "$WITH_PORT_FORWARDING" == true ]]; then
  run_step "Enable permanent port forwarding" enable_port_forwarding
else
  log "443 REDIRECT skipped"
  echo "Run with --with-port-forwarding to persist 443->${INFRA_PORT_FORWARD_DEST} (${INFRA_PORT_FORWARD_SERVICE})."
fi

run_step "Final status" print_status

log "Done"
echo "Dev go-live sequence complete."
