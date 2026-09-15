#!/usr/bin/env bash
# Create generic host runtime layout under each *-app directory.
# Layout: certs/, logs/, data/, nginx/, secrets/secrets.env
# Permissions per discernible-io/docs cicd-deployment-standard.md
#
# Usage:
#   ./bootstrap-app-dir-layout.sh              # all INFRA_APP_DOMAINS + ~/*-app
#   ./bootstrap-app-dir-layout.sh /path/foo-app ...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

bootstrap_app_dir() {
    local app_dir="$1"
    local env_rel="${INFRA_APP_ENV_FILES[$app_dir]:-secrets/secrets.env}"
    local app_name
    app_name="$(basename "$app_dir")"

    if [[ ! -d "$app_dir" ]]; then
        mkdir -p "$app_dir"
        echo -e "${GREEN}✓ Created $app_dir${NC}"
    fi

    mkdir -p "$app_dir"/{certs,logs,data,nginx,secrets}
    chmod 0711 "$app_dir/certs"
    chmod 750 "$app_dir/secrets"

    local env_file="$app_dir/$env_rel"
    local env_dir
    env_dir="$(dirname "$env_file")"
    if [[ "$env_dir" != "$app_dir" ]]; then
        mkdir -p "$env_dir"
        chmod 750 "$env_dir" 2>/dev/null || chmod 755 "$env_dir"
    fi

    if [[ ! -f "$env_file" ]]; then
        if [[ "$env_rel" == "secrets/secrets.env" ]]; then
            cat >"$env_file" <<'EOF'
# Runtime secrets — populate on this host only; never commit.
# Key list: discernible-io/docs configuration-standard.md
EOF
        else
            printf '%s\n' "# Runtime env — populate on this host only; never commit." >"$env_file"
        fi
        echo -e "${GREEN}✓ Created $env_file${NC}"
    fi

    if [[ "$env_rel" == "secrets/secrets.env" || "$env_rel" == ".env" ]]; then
        chmod 0644 "$env_file"
    else
        chmod 0600 "$env_file" 2>/dev/null || chmod 0644 "$env_file"
    fi

    # Generic layout always includes secrets/secrets.env for CI/CD parity.
    local generic_env="$app_dir/secrets/secrets.env"
    if [[ "$env_rel" != "secrets/secrets.env" && ! -f "$generic_env" ]]; then
        cat >"$generic_env" <<'EOF'
# Optional; this app may use a different --env-file path (see infra-env-helper INFRA_APP_ENV_FILES).
EOF
        chmod 0644 "$generic_env"
    fi

    if [[ "$(id -u)" -eq 0 ]]; then
        chown -R "$INFRA_USER:$INFRA_USER" "$app_dir"
    fi

    echo -e "${BLUE}=== $app_name ===${NC}"
    echo -e "  ${GREEN}✓ certs/ logs/ data/ nginx/ secrets/${NC}"
    echo -e "  ${GREEN}✓ runtime env: $env_rel${NC}"
}

declare -A APP_DIRS=()

if [[ $# -gt 0 ]]; then
    for app_dir in "$@"; do
        APP_DIRS["$app_dir"]=1
    done
else
    for app_dir in "${!INFRA_APP_DOMAINS[@]}"; do
        APP_DIRS["$app_dir"]=1
    done
    shopt -s nullglob
    for app_dir in "$INFRA_HOME"/*-app; do
        [[ -d "$app_dir" ]] && APP_DIRS["$app_dir"]=1
    done
    shopt -u nullglob
fi

echo -e "${BLUE}========== Bootstrap app directory layout ==========${NC}"
echo -e "${YELLOW}User: $INFRA_USER  Home: $INFRA_HOME${NC}"
echo ""

for app_dir in "${!APP_DIRS[@]}"; do
    bootstrap_app_dir "$app_dir"
    echo ""
done

echo -e "${GREEN}Done. Populate secrets in each *-app directory and install TLS PEMs before deploy.${NC}"
echo -e "${YELLOW}Runtime secrets stay under ~/<service>-app/ (see INFRA_APP_ENV_FILES). Host config is ~/infra-app/.${NC}"
