#!/usr/bin/env bash
# certbot --deploy-hook target: install certs to apps and reload services.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

"$SCRIPT_DIR/install-certs-to-apps.sh"

if [[ -f "$SCRIPT_DIR/restart-containers-apis.sh" ]]; then
    "$SCRIPT_DIR/restart-containers-apis.sh" || true
fi

restart_monitoring_nginx() {
    if ! command -v podman >/dev/null 2>&1; then
        return 0
    fi

    if podman container exists monitoring-nginx 2>/dev/null; then
        podman restart monitoring-nginx || true
        return 0
    fi

    if command -v runuser >/dev/null 2>&1 && id "$INFRA_USER" >/dev/null 2>&1; then
        local user_uid
        user_uid="$(id -u "$INFRA_USER")"
        if runuser -u "$INFRA_USER" -- env XDG_RUNTIME_DIR="/run/user/$user_uid" podman container exists monitoring-nginx 2>/dev/null; then
            runuser -u "$INFRA_USER" -- env XDG_RUNTIME_DIR="/run/user/$user_uid" podman restart monitoring-nginx || true
        fi
    fi
}

restart_monitoring_nginx
