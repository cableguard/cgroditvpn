#!/usr/bin/env bash
# Install or remove the idclaw API scan fail2ban jail.
# Usage: sudo ./configure-fail2ban-idclaw-api-jail-oneoff.sh install [logpath]
#        sudo ./configure-fail2ban-idclaw-api-jail-oneoff.sh remove

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/infra-env-helper.sh" ]]; then
  # shellcheck source=infra-env-helper.sh
  source "$SCRIPT_DIR/infra-env-helper.sh"
fi

FILTER_NAME="idclaw-api-scan"
FILTER_PATH="/etc/fail2ban/filter.d/${FILTER_NAME}.conf"
JAIL_PATH="/etc/fail2ban/jail.d/${FILTER_NAME}.local"
DEFAULT_LOGPATH="${INFRA_IDCLAW_API_LOGPATH:-/var/log/idclawserver/api.log}"

usage() {
  echo "Usage: sudo $0 install [logpath]"
  echo "       sudo $0 remove"
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0 ..."
    exit 1
  fi
}

cmd_install() {
  local logpath="${1:-$DEFAULT_LOGPATH}"

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    echo "fail2ban not found; installing epel-release (if needed) and fail2ban..."
    if command -v rpm >/dev/null 2>&1 && ! rpm -q epel-release >/dev/null 2>&1; then
      dnf install -y epel-release || true
    fi
    dnf install -y fail2ban
  fi

  echo "Installing fail2ban filter: ${FILTER_PATH}"
  cat > "${FILTER_PATH}" <<'EOF'
[Definition]
# Match JSON API request logs for common discovery/probe endpoints.
failregex = ^.*"component":"API".*"url":"/(?:swagger\.json|openapi\.json|\.well-known/mcp)".*"clientIP":"<HOST>".*$
ignoreregex =
EOF

  echo "Installing fail2ban jail: ${JAIL_PATH}"
  cat > "${JAIL_PATH}" <<EOF
[${FILTER_NAME}]
enabled  = true
port     = http,https
filter   = ${FILTER_NAME}
logpath  = ${logpath}
findtime = 10m
maxretry = 6
bantime  = 1h
EOF

  local logdir
  logdir="$(dirname "${logpath}")"
  if [[ ! -d "${logdir}" ]]; then
    install -d -m 0755 "${logdir}"
    echo "Created log directory: ${logdir}"
  fi
  if [[ ! -f "${logpath}" ]]; then
    install -m 0644 /dev/null "${logpath}"
    echo "Created placeholder log (fail2ban requires the file to exist): ${logpath}"
  fi

  if [[ -s "${logpath}" ]]; then
    echo "Testing regex against log file: ${logpath}"
    fail2ban-regex "${logpath}" "${FILTER_PATH}" || true
  else
    echo "Log file is empty; regex test skipped."
  fi

  echo "Restarting fail2ban..."
  systemctl restart fail2ban

  echo "Verifying jail status..."
  if ! fail2ban-client status "${FILTER_NAME}"; then
    echo "Warning: ${FILTER_NAME} jail not active yet (fail2ban may still be starting)." >&2
    systemctl is-active fail2ban || systemctl status fail2ban --no-pager -l | tail -5
    exit 1
  fi
}

cmd_remove() {
  if command -v fail2ban-client >/dev/null 2>&1; then
    echo "Stopping jail if running..."
    fail2ban-client stop "${FILTER_NAME}" >/dev/null 2>&1 || true
  else
    echo "fail2ban is not installed; only removing local files (if any)."
  fi

  if [[ -f "${JAIL_PATH}" ]]; then
    echo "Removing jail file: ${JAIL_PATH}"
    rm -f "${JAIL_PATH}"
  else
    echo "Jail file not present: ${JAIL_PATH}"
  fi

  if [[ -f "${FILTER_PATH}" ]]; then
    echo "Removing filter file: ${FILTER_PATH}"
    rm -f "${FILTER_PATH}"
  else
    echo "Filter file not present: ${FILTER_PATH}"
  fi

  if command -v fail2ban-client >/dev/null 2>&1; then
    echo "Restarting fail2ban..."
    systemctl restart fail2ban
    echo "Current fail2ban status:"
    fail2ban-client status
  fi

  echo "Rollback completed."
}

require_root

ACTION="${1:-}"
shift || true

case "$ACTION" in
  install) cmd_install "${1:-}" ;;
  remove) cmd_remove ;;
  *) usage ;;
esac
