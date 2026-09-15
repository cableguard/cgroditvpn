#!/usr/bin/env bash
# Apply post-assessment security improvements on dedalo47-class hosts.
# Run from your terminal: ./apply-security-improvements-oneoff.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

AUTH_KEYS="${INFRA_HOME}/.ssh/authorized_keys"
AUTH_KEYS_BACKUP="${AUTH_KEYS}.bak.$(date +%Y%m%d%H%M%S)"

echo "== 1/5 SSH authorized_keys cleanup =="
if [[ -f "$AUTH_KEYS" ]]; then
  cp -a "$AUTH_KEYS" "$AUTH_KEYS_BACKUP"
  valid=0
  : > "${AUTH_KEYS}.tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "$line" >> "${AUTH_KEYS}.tmp"
    elif [[ "$line" =~ ^ssh- ]]; then
      if printf '%s\n' "$line" | ssh-keygen -lf - >/dev/null 2>&1; then
        printf '%s\n' "$line" >> "${AUTH_KEYS}.tmp"
        valid=$((valid + 1))
      else
        echo "# removed-invalid: $line" >&2
      fi
    elif [[ -n "${line//[[:space:]]/}" ]]; then
      echo "# removed-invalid: $line" >&2
    fi
  done < "$AUTH_KEYS"
  if [[ "$valid" -eq 0 ]]; then
    rm -f "${AUTH_KEYS}.tmp"
    echo "  Error: no valid SSH public keys in $AUTH_KEYS; leaving file unchanged." >&2
    echo "  Backup: $AUTH_KEYS_BACKUP" >&2
    exit 1
  fi
  mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
  chown "${INFRA_USER}:${INFRA_USER}" "$AUTH_KEYS"
  chmod 600 "$AUTH_KEYS"
  echo "  Valid keys: $valid"
  echo "  Backup: $AUTH_KEYS_BACKUP"
else
  echo "  Warning: $AUTH_KEYS not found"
fi

echo ""
echo "== 2/5 SSH hardening + fail2ban (journald backend) =="
"$SCRIPT_DIR/harden-server-oneoff.sh"

echo ""
echo "== 3/5 Host firewall (monitoring ports CIDR-restricted when enabled) =="
"$SCRIPT_DIR/configure-host-firewall-oneoff.sh" enable permanent

echo ""
echo "== 4/5 idclaw API scan fail2ban jail =="
if [[ -f "$SCRIPT_DIR/configure-fail2ban-idclaw-api-jail-oneoff.sh" ]]; then
  "$SCRIPT_DIR/configure-fail2ban-idclaw-api-jail-oneoff.sh" install || {
    echo "  Warning: idclaw API jail install failed (log path may not exist yet)"
  }
fi

echo ""
echo "== 5/5 Verification =="
echo "SSH drop-in:"
grep -E '^(PasswordAuthentication|PermitRootLogin|AllowUsers)' /etc/ssh/sshd_config.d/99-infra-hardening.conf 2>/dev/null || true
echo ""
echo "fail2ban sshd:"
fail2ban-client status sshd || true
echo ""
echo "Host firewall:"
"$SCRIPT_DIR/configure-host-firewall-oneoff.sh" status | head -30

echo ""
echo "Done. Open a second SSH session before closing this one to confirm key access still works."
