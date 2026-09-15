#!/usr/bin/env bash
# Alma Linux: Let's Encrypt via certbot (standalone HTTP-01).
# Usage: sudo ./generate-cert-letsencrypt.sh <domain> [email]
#
# Port 80 must be free (httpd is stopped). Installs bind-utils for dig DNS checks.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"
if ! declare -F infra_cert_san_domains_for &>/dev/null; then
  # shellcheck source=infra-env-helper-shared.sh
  source "$SCRIPT_DIR/infra-env-helper-shared.sh"
fi
if ! declare -p INFRA_CERT_SAN_DOMAINS &>/dev/null 2>&1; then
  declare -gA INFRA_CERT_SAN_DOMAINS=()
fi
# shellcheck source=prepare-httpd-for-certbot-helper.sh
source "$SCRIPT_DIR/prepare-httpd-for-certbot-helper.sh"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}" >&2
   exit 1
fi

if [ $# -lt 1 ]; then
    echo -e "${RED}Usage: sudo $0 <domain> [email]${NC}" >&2
    echo -e "${YELLOW}Example: sudo $0 grafana.example.net admin@example.com${NC}" >&2
    exit 1
fi

DOMAIN="$1"
EMAIL="${2:-}"

setup_httpd_cleanup_trap
ensure_httpd_stopped

SAN_DOMAINS="$(infra_cert_san_domains_for "$DOMAIN")"
CERT_DOMAINS=("$DOMAIN")
if [[ -n "$SAN_DOMAINS" ]]; then
    read -r -a _infra_san_list <<< "$SAN_DOMAINS"
    for _infra_san in "${_infra_san_list[@]}"; do
        [[ -n "$_infra_san" ]] && CERT_DOMAINS+=("$_infra_san")
    done
fi

echo -e "${BLUE}========== Let's Encrypt Certificate Generation for ${CERT_DOMAINS[*]} ==========${NC}"

if command -v rpm >/dev/null 2>&1 && ! rpm -q epel-release >/dev/null 2>&1; then
  dnf install -y epel-release || true
fi

ensure_bind_utils

echo -e "${YELLOW}Checking server's public IP...${NC}"
IPV4=$(infra_server_ipv4 || echo "")
echo -e "${GREEN}Server public IPv4: ${IPV4:-unknown}${NC}"
for _infra_domain in "${CERT_DOMAINS[@]}"; do
    if ! infra_check_dns_a "$_infra_domain" "$IPV4"; then
        echo -e "${YELLOW}Fix DNS A record for $_infra_domain → $IPV4 before retrying.${NC}"
        exit 1
    fi
done

echo -e "${YELLOW}Installing certbot...${NC}"
dnf install -y certbot

open_firewall_http_for_certbot

if ss -tlnH 2>/dev/null | grep -q ':80 '; then
    echo -e "${RED}Port 80 is in use. Stop the service using it, then retry.${NC}" >&2
    ss -tlnp | grep ':80 ' || true
    exit 1
fi

CERT_PATH="/etc/letsencrypt/live/$DOMAIN"
if [[ -d "$CERT_PATH" ]]; then
    echo -e "${YELLOW}Existing certificate found; expanding/renewing ${CERT_DOMAINS[*]}...${NC}"
    certbot_args=(
        certbot certonly --standalone
        --cert-name "$DOMAIN"
        --expand
        --non-interactive
        --agree-tos
    )
    for _infra_domain in "${CERT_DOMAINS[@]}"; do
        certbot_args+=(-d "$_infra_domain")
    done
    if [[ -n "$EMAIL" ]]; then
        certbot_args+=(--email "$EMAIL")
    fi
    "${certbot_args[@]}"
else
    echo -e "${YELLOW}Requesting new certificate (standalone on port 80)...${NC}"
    certbot_args=(
        certbot certonly --standalone
        --non-interactive
        --agree-tos
    )
    for _infra_domain in "${CERT_DOMAINS[@]}"; do
        certbot_args+=(-d "$_infra_domain")
    done
    if [[ -n "$EMAIL" ]]; then
        certbot_args+=(--email "$EMAIL")
        echo -e "${GREEN}Using email: $EMAIL${NC}"
    else
        certbot_args+=(--register-unsafely-without-email)
        echo -e "${YELLOW}No email provided; registering without email${NC}"
    fi
    "${certbot_args[@]}"
fi

if [[ -d "$CERT_PATH" ]]; then
    echo -e "${GREEN}Certificate successfully obtained!${NC}"
    echo -e "${GREEN}Certificate files:${NC}"
    echo -e "  ${BLUE}Full chain: $CERT_PATH/fullchain.pem${NC}"
    echo -e "  ${BLUE}Private key: $CERT_PATH/privkey.pem${NC}"

    echo -e "\n${YELLOW}Certificate details:${NC}"
    openssl x509 -in "$CERT_PATH/cert.pem" -noout -subject -issuer -dates
else
    echo -e "${RED}Certificate generation failed!${NC}"
    exit 1
fi

echo -e "\n${GREEN}========== Certificate Generation Complete ==========${NC}"
echo -e "${GREEN}Domain: $DOMAIN${NC}"
echo -e "${GREEN}Certificate path: $CERT_PATH${NC}"
