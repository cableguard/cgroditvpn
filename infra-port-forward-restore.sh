#!/usr/bin/env bash
# Re-apply INFRA_PORT_FORWARD_* and INFRA_EXTRA_PORT_FORWARDS NAT REDIRECTs after
# iptables.service restore. Installed by configure-port-forwarding-oneoff.sh
# enable permanent (infra-port-forward.service).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"
# shellcheck source=infra-iptables-helper.sh
source "$SCRIPT_DIR/infra-iptables-helper.sh"

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "infra-port-forward-restore: must run as root" >&2
  exit 1
fi

if ! infra_port_forward_configured; then
  exit 0
fi

infra_ensure_port_forward_rules
