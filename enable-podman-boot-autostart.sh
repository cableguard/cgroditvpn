#!/usr/bin/env bash
# Enable rootless Podman autostart on reboot (linger + podman.socket + podman-restart).
# Usage: sudo ./enable-podman-boot-autostart.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID:-0}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"
# shellcheck source=infra-podman-helper.sh
source "$SCRIPT_DIR/infra-podman-helper.sh"

infra_enable_podman_boot_autostart "$INFRA_USER"

echo ""
echo "Verify (as $INFRA_USER):"
uid="$(id -u "$INFRA_USER")"
infra_run_as_user "$INFRA_USER" systemctl --user is-enabled podman.socket podman-restart.service 2>/dev/null || true
loginctl show-user "$INFRA_USER" -p Linger
