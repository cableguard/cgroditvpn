#!/bin/bash
# Install, enable, disable, or show status for Podman container liveness monitoring.
#
# Usage:
#   sudo ./manage-monitoring-pods.sh install
#   sudo ./manage-monitoring-pods.sh enable
#   sudo ./manage-monitoring-pods.sh disable
#   ./manage-monitoring-pods.sh status

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"
# shellcheck source=infra-podman-helper.sh
source "$SCRIPT_DIR/infra-podman-helper.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

MONITOR_USER="${MONITOR_USER:-$INFRA_USER}"
USER_UID=$(id -u "$MONITOR_USER" 2>/dev/null || echo "1000")
REPO_DIR="$INFRA_REPO"
MONITOR_SCRIPT="$REPO_DIR/monitor-pods-liveness-helper.sh"
LOG_FILE="/var/log/pod-monitor.log"
TIMER_UNIT="monitor-pods-liveness.timer"
SERVICE_UNIT="monitor-pods-liveness.service"

usage() {
    echo "Usage: sudo $0 install"
    echo "       sudo $0 enable"
    echo "       sudo $0 disable"
    echo "       $0 status"
    exit 1
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: This command must be run with sudo${NC}"
        usage
    fi
}

timer_installed() {
    [ -f "/etc/systemd/system/${TIMER_UNIT}" ]
}

cmd_install() {
    require_root

    echo -e "${BLUE}=====================================${NC}"
    echo -e "${BLUE}  Podman Monitor Installation${NC}"
    echo -e "${BLUE}=====================================${NC}"

    echo -e "\n${YELLOW}Checking for required files...${NC}"
    local required_files=(
        "$MONITOR_SCRIPT"
        "$REPO_DIR/monitor-pods-liveness.service"
        "$REPO_DIR/monitor-pods-liveness.timer"
    )

    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            echo -e "${RED}Error: Required file not found: $file${NC}"
            exit 1
        fi
        echo -e "${GREEN}✓ Found: $file${NC}"
    done

    if [ ! -x "$MONITOR_SCRIPT" ]; then
        echo -e "${YELLOW}Making monitor-pods-liveness-helper.sh executable...${NC}"
        chmod +x "$MONITOR_SCRIPT"
    fi

    echo -e "\n${YELLOW}Setting up log file...${NC}"
    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE"
        echo -e "${GREEN}✓ Created log file: $LOG_FILE${NC}"
    else
        echo -e "${YELLOW}Log file already exists: $LOG_FILE${NC}"
    fi
    chown "$MONITOR_USER:$MONITOR_USER" "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    echo -e "\n${YELLOW}Enabling rootless Podman session (linger, socket, boot autostart)...${NC}"
    if MONITOR_USER="$MONITOR_USER" "$REPO_DIR/enable-rootless-podman-helper.sh" enable; then
        echo -e "${GREEN}✓ Rootless Podman socket ready for $MONITOR_USER${NC}"
    else
        echo -e "${RED}✗ Failed to enable rootless Podman session for $MONITOR_USER${NC}"
        exit 1
    fi
    if infra_enable_podman_restart_service "$MONITOR_USER"; then
        echo -e "${GREEN}✓ podman-restart.service enabled for $MONITOR_USER${NC}"
    else
        echo -e "${YELLOW}⚠ podman-restart.service not fully configured; unless-stopped may not survive reboot${NC}"
    fi
    if ! loginctl show-user "$MONITOR_USER" -p Linger 2>/dev/null | grep -q yes; then
        echo -e "${RED}✗ Linger is not enabled for $MONITOR_USER${NC}"
        exit 1
    fi

    echo -e "\n${YELLOW}Installing systemd units...${NC}"
    cp "$REPO_DIR/monitor-pods-liveness.service" /etc/systemd/system/
    chmod 644 "/etc/systemd/system/${SERVICE_UNIT}"
    sed -i "s/^User=.*/User=$MONITOR_USER/" "/etc/systemd/system/${SERVICE_UNIT}"
    sed -i "s/^Group=.*/Group=$MONITOR_USER/" "/etc/systemd/system/${SERVICE_UNIT}"
    sed -i "s|^After=.*|After=network-online.target user@${USER_UID}.service|" "/etc/systemd/system/${SERVICE_UNIT}"
    sed -i "/^Wants=user@/d" "/etc/systemd/system/${SERVICE_UNIT}"
    sed -i "/^After=network-online.target/a Wants=user@${USER_UID}.service" "/etc/systemd/system/${SERVICE_UNIT}"
    sed -i "s|^Environment=\"XDG_RUNTIME_DIR=.*|Environment=\"XDG_RUNTIME_DIR=/run/user/${USER_UID}\"|" "/etc/systemd/system/${SERVICE_UNIT}"
    sed -i "s|^Environment=\"DBUS_SESSION_BUS_ADDRESS=.*|Environment=\"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${USER_UID}/bus\"|" "/etc/systemd/system/${SERVICE_UNIT}"
    sed -i "s|^Environment=\"INFRA_USER=.*|Environment=\"INFRA_USER=${MONITOR_USER}\"|" "/etc/systemd/system/${SERVICE_UNIT}"
    sed -i "s|^Environment=\"INFRA_HOME=.*|Environment=\"INFRA_HOME=${INFRA_HOME}\"|" "/etc/systemd/system/${SERVICE_UNIT}"
    sed -i "s|^Environment=\"INFRA_REPO=.*|Environment=\"INFRA_REPO=${REPO_DIR}\"|" "/etc/systemd/system/${SERVICE_UNIT}"
    infra_systemd_set_env "/etc/systemd/system/${SERVICE_UNIT}" INFRA_APP_DIR "${INFRA_APP_DIR}"
    sed -i "s|^Documentation=.*|Documentation=file://${REPO_DIR}/docs/readme.md|" "/etc/systemd/system/${SERVICE_UNIT}"
    sed -i "s|ExecStart=.*|ExecStart=/usr/bin/bash -lc 'exec \"\\\$INFRA_REPO/monitor-pods-liveness-helper.sh\"'|" "/etc/systemd/system/${SERVICE_UNIT}"
    if ! grep -q '^ExecStartPre=' "/etc/systemd/system/${SERVICE_UNIT}"; then
        sed -i "/^ExecStart=/i ExecStartPre=/usr/bin/bash -c 'systemctl --user start podman.socket 2>/dev/null || true'" \
            "/etc/systemd/system/${SERVICE_UNIT}"
    fi

    cp "$REPO_DIR/monitor-pods-liveness.timer" /etc/systemd/system/
    chmod 644 "/etc/systemd/system/${TIMER_UNIT}"
    sed -i "s|^Documentation=.*|Documentation=file://${REPO_DIR}/docs/readme.md|" "/etc/systemd/system/${TIMER_UNIT}"

    systemctl daemon-reload
    systemctl enable "$TIMER_UNIT"
    systemctl start "$TIMER_UNIT"

    if ! systemctl is-active --quiet "$TIMER_UNIT"; then
        echo -e "${RED}✗ Timer is not active${NC}"
        exit 1
    fi

    echo -e "\n${BLUE}Timer Status:${NC}"
    systemctl list-timers "$TIMER_UNIT" --no-pager

    # Always run one check immediately on install so services come up without
    # waiting for the next timer tick (and without requiring interactive input).
    # This is especially important when other scripts (e.g. golive.sh) run this
    # installer non-interactively.
    echo -e "\n${YELLOW}Running initial liveness check now...${NC}"
    systemctl start "$SERVICE_UNIT" || true
    sleep 2
    systemctl status "$SERVICE_UNIT" --no-pager --lines=12 || true
    tail -10 "$LOG_FILE" || true

    echo -e "\n${YELLOW}Would you like to set up log rotation? (y/n)${NC}"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        cat > /etc/logrotate.d/pod-monitor <<EOF
/var/log/pod-monitor.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 $MONITOR_USER $MONITOR_USER
}
EOF
        echo -e "${GREEN}✓ Log rotation configured${NC}"
    fi

    echo -e "\n${GREEN}Installation complete.${NC}"
    echo -e "Edit services: ${YELLOW}$MONITOR_SCRIPT${NC}"
    echo -e "Check status: ${YELLOW}$0 status${NC}"
}

cmd_enable() {
    require_root

    echo -e "${BLUE}  Enable Pod Monitoring${NC}"

    if ! timer_installed; then
        echo -e "${YELLOW}Warning: ${TIMER_UNIT} not installed${NC}"
        echo -e "${YELLOW}Run: sudo $0 install${NC}"
        exit 1
    fi

    systemctl daemon-reload
    systemctl enable "$TIMER_UNIT"
    systemctl start "$TIMER_UNIT"

    if systemctl is-active --quiet "$TIMER_UNIT"; then
        echo -e "${GREEN}✓ Monitoring enabled${NC}"
        systemctl list-timers "$TIMER_UNIT" --no-pager
    else
        echo -e "${RED}✗ Timer failed to start${NC}"
        systemctl status "$TIMER_UNIT" --no-pager
        exit 1
    fi
}

cmd_disable() {
    require_root

    echo -e "${BLUE}  Disable Pod Monitoring${NC}"

    if ! timer_installed; then
        echo -e "${YELLOW}Monitoring is not installed${NC}"
        exit 0
    fi

    if systemctl is-active --quiet "$TIMER_UNIT"; then
        systemctl stop "$TIMER_UNIT"
    fi
    if systemctl is-enabled --quiet "$TIMER_UNIT" 2>/dev/null; then
        systemctl disable "$TIMER_UNIT"
    fi
    if systemctl is-active --quiet "$SERVICE_UNIT"; then
        systemctl stop "$SERVICE_UNIT"
    fi

    if systemctl is-active --quiet "$TIMER_UNIT"; then
        echo -e "${RED}✗ Timer is still active${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Monitoring disabled${NC}"
}

cmd_status() {
    echo -e "${BLUE}  Pod Monitoring Status${NC}"

    echo -e "\n${CYAN}Installation:${NC}"
    if timer_installed; then
        echo -e "${GREEN}✓ Installed${NC}"
    else
        echo -e "${RED}✗ Not installed — run: sudo $0 install${NC}"
        exit 0
    fi

    echo -e "\n${CYAN}Timer:${NC}"
    if systemctl is-active --quiet "$TIMER_UNIT"; then
        echo -e "${GREEN}✓ Active${NC}"
    else
        echo -e "${RED}✗ Inactive${NC}"
    fi

    if systemctl is-enabled --quiet "$TIMER_UNIT" 2>/dev/null; then
        echo -e "${GREEN}✓ Enabled on boot${NC}"
    else
        echo -e "${YELLOW}○ Disabled on boot${NC}"
    fi

    echo -e "\n${CYAN}Schedule:${NC}"
    if systemctl is-active --quiet "$TIMER_UNIT"; then
        systemctl list-timers "$TIMER_UNIT" --no-pager 2>/dev/null || true
    fi

    echo -e "\n${CYAN}Recent logs:${NC}"
    if [ -f "$LOG_FILE" ]; then
        tail -10 "$LOG_FILE"
    else
        echo -e "${YELLOW}No log file: $LOG_FILE${NC}"
    fi

    echo -e "\n${CYAN}Rootless Podman:${NC}"
    "$SCRIPT_DIR/enable-rootless-podman-helper.sh" status 2>/dev/null | sed 's/^/  /' || true

    echo -e "\n${CYAN}Monitored containers:${NC}"
    if [[ ${#INFRA_MONITOR_SERVICES[@]} -gt 0 ]]; then
        local svc_def name container port
        for svc_def in "${INFRA_MONITOR_SERVICES[@]}"; do
            IFS=':' read -r name container _ port <<<"$svc_def"
            echo -e "  • ${name} → ${container} (port ${port:-?})"
        done
    else
        echo -e "${YELLOW}None configured in infra-env-helper.sh${NC}"
    fi

    echo -e "\n${CYAN}Actions:${NC}"
    if systemctl is-active --quiet "$TIMER_UNIT"; then
        echo -e "  Disable: sudo $0 disable"
    else
        echo -e "  Enable:  sudo $0 enable"
    fi
    echo -e "  Logs:    tail -f $LOG_FILE"
    echo -e "  Edit:    nano $MONITOR_SCRIPT"
}

ACTION="${1:-}"
case "$ACTION" in
    install) cmd_install ;;
    enable) cmd_enable ;;
    disable) cmd_disable ;;
    status) cmd_status ;;
    *) usage ;;
esac
