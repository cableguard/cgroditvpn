#!/usr/bin/env bash
# Repair audit watch rules that reference missing paths (audit-rules.service fails
# with "No such file or directory" on augenrules --load).
#
# Usage: sudo ./fix-audit-rules-oneoff.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID:-0}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

resolve_secrets_watch_path() {
  local candidate dir secrets
  for dir in "${!INFRA_APP_DOMAINS[@]}"; do
    for secrets in "${dir}/secrets/secrets.env" "${dir}/secrets/api.env"; do
      if [[ -f "$secrets" ]]; then
        printf '%s' "$secrets"
        return 0
      fi
    done
  done
  return 1
}

WATCH_PATH="$(resolve_secrets_watch_path || true)"
if [[ -z "$WATCH_PATH" ]]; then
  echo "Error: no existing secrets.env/api.env found under INFRA_APP_DOMAINS." >&2
  exit 1
fi

RULES_DIR="/etc/audit/rules.d"
SECRETS_RULES="${RULES_DIR}/secrets.rules"
install -d -m 0750 -o root -g root "$RULES_DIR"

cat >"$SECRETS_RULES" <<EOF
# Managed by fix-audit-rules-oneoff.sh — watch an existing secrets file.
-w ${WATCH_PATH} -p wa -k secrets_access
EOF
chmod 0640 "$SECRETS_RULES"

echo "Wrote ${SECRETS_RULES}:"
cat "$SECRETS_RULES"
echo ""

if ! systemctl is-active --quiet auditd; then
  systemctl start auditd
fi

echo "Loading rules..."
augenrules --load
systemctl reset-failed audit-rules.service 2>/dev/null || true
systemctl restart audit-rules.service
systemctl status audit-rules.service --no-pager -l || true
echo ""
echo "Active watch rules:"
auditctl -l | grep -F secrets_access || auditctl -l | head -10
