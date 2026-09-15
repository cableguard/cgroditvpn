#!/bin/bash
# Production Server Hardening Script
# Implements: SSH key-only auth, fail2ban, auditd with secrets monitoring
# Run with: sudo bash harden-server-oneoff.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration: first *-app from infra-env-helper with a secrets file (override: APP_DIR)
if [[ -z "${APP_DIR:-}" ]]; then
    for candidate in "${!INFRA_APP_DOMAINS[@]}"; do
        if [[ -f "${candidate}/secrets/secrets.env" ]] || [[ -f "${candidate}/secrets/api.env" ]]; then
            APP_DIR="$candidate"
            break
        fi
    done
    if [[ -z "${APP_DIR:-}" ]]; then
        for candidate in "${!INFRA_APP_DOMAINS[@]}"; do
            APP_DIR="$candidate"
            break
        done
    fi
fi
if [[ -f "${APP_DIR}/secrets/secrets.env" ]]; then
    SECRETS_FILE="${APP_DIR}/secrets/secrets.env"
elif [[ -f "${APP_DIR}/secrets/api.env" ]]; then
    SECRETS_FILE="${APP_DIR}/secrets/api.env"
else
    SECRETS_FILE="${APP_DIR}/secrets/secrets.env"
fi

# Detect package manager
detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt-get update"
        PKG_INSTALL="apt-get install -y"
        FAIL2BAN_LOGPATH="/var/log/auth.log"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf check-update"
        PKG_INSTALL="dnf install -y"
        FAIL2BAN_LOGPATH="/var/log/secure"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        PKG_UPDATE="yum check-update"
        PKG_INSTALL="yum install -y"
        FAIL2BAN_LOGPATH="/var/log/secure"
    else
        log_error "No supported package manager found (apt-get, dnf, or yum)"
        exit 1
    fi
    log_info "Detected package manager: $PKG_MANAGER"
}

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Step 1: Disable SSH Password Authentication
harden_ssh() {
    log_info "Hardening SSH configuration..."
    
    # Backup original config
    if [ ! -f /etc/ssh/sshd_config.backup ]; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
        log_success "Backed up sshd_config"
    fi
    
    # Disable root login (handle various existing values)
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    
    # Enable public key authentication
    sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    
    # Disable password authentication
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    
    # Disable empty passwords
    sed -i 's/^#PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
    sed -i 's/^PermitEmptyPasswords.*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
    
    # Disable challenge-response authentication
    sed -i 's/^#ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    # Add if not present
    if ! grep -q "^ChallengeResponseAuthentication" /etc/ssh/sshd_config; then
        echo "ChallengeResponseAuthentication no" >> /etc/ssh/sshd_config
    fi

    # Modern OpenSSH: disable keyboard-interactive password prompts
    if grep -q "^#KbdInteractiveAuthentication" /etc/ssh/sshd_config; then
        sed -i 's/^#KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
    elif grep -q "^KbdInteractiveAuthentication" /etc/ssh/sshd_config; then
        sed -i 's/^KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
    else
        echo "KbdInteractiveAuthentication no" >> /etc/ssh/sshd_config
    fi
    
    # Enable PAM
    sed -i 's/^#UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
    sed -i 's/^UsePAM no/UsePAM yes/' /etc/ssh/sshd_config
    
    # Verify changes
    local all_ssh_good=true
    
    if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config; then
        log_success "SSH root login disabled"
    else
        log_error "Failed to disable SSH root login"
        all_ssh_good=false
    fi
    
    if grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config; then
        log_success "SSH public key authentication enabled"
    else
        log_error "Failed to enable SSH public key authentication"
        all_ssh_good=false
    fi
    
    if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
        log_success "SSH password authentication disabled"
    else
        log_error "Failed to disable SSH password authentication"
        all_ssh_good=false
    fi
    
    if grep -q "^PermitEmptyPasswords no" /etc/ssh/sshd_config; then
        log_success "SSH empty passwords disabled"
    else
        log_error "Failed to disable SSH empty passwords"
        all_ssh_good=false
    fi
    
    if grep -q "^ChallengeResponseAuthentication no" /etc/ssh/sshd_config; then
        log_success "SSH challenge-response authentication disabled"
    else
        log_error "Failed to disable SSH challenge-response authentication"
        all_ssh_good=false
    fi
    
    if grep -q "^UsePAM yes" /etc/ssh/sshd_config; then
        log_success "SSH PAM enabled"
    else
        log_error "Failed to enable SSH PAM"
        all_ssh_good=false
    fi
    
    if [ "$all_ssh_good" = false ]; then
        return 1
    fi
    
    # Drop-in overrides (survives package updates better than sed-only)
    cat > /etc/ssh/sshd_config.d/99-infra-hardening.conf <<EOF
# Managed by ${SCRIPT_DIR}/harden-server-oneoff.sh
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
AllowUsers ${INFRA_USER}
EOF

    if ! sshd -t; then
        log_error "sshd configuration test failed"
        return 1
    fi

    # Reload SSH daemon
    systemctl reload sshd
    log_success "SSH daemon reloaded"
}

# Step 2: Install and Configure fail2ban
install_fail2ban() {
    log_info "Installing and configuring fail2ban..."
    
    # Check if already installed
    if command -v fail2ban-client &> /dev/null; then
        log_warn "fail2ban already installed"
    else
        eval "$PKG_UPDATE" > /dev/null 2>&1 || true
        eval "$PKG_INSTALL fail2ban" > /dev/null 2>&1
        log_success "fail2ban installed"
    fi
    
    # Prefer systemd journal on RHEL/Alma when auth.log is not populated.
    local sshd_backend=""
    local sshd_logpath=""
    if [[ -f /etc/fail2ban/paths-fedora.conf ]] || [[ "$PKG_MANAGER" != "apt" ]]; then
        sshd_backend="backend = systemd"
    elif [[ -r "$FAIL2BAN_LOGPATH" ]]; then
        sshd_logpath="logpath = $FAIL2BAN_LOGPATH"
    else
        sshd_backend="backend = systemd"
    fi

    # Create local jail configuration
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
destemail = admin@example.com
sendername = Fail2Ban
action = %(action_mwl)s

[sshd]
enabled = true
port = ssh
filter = sshd
${sshd_logpath}
${sshd_backend}
maxretry = 3
bantime = 7200
EOF
    
    log_success "fail2ban configuration created"
    
    # Enable and start fail2ban
    systemctl enable fail2ban > /dev/null
    systemctl restart fail2ban
    log_success "fail2ban enabled and started"
    
    # Verify (allow time for service to start)
    sleep 2
    if fail2ban-client status sshd &> /dev/null; then
        log_success "fail2ban SSH jail is active"
    else
        log_warn "fail2ban SSH jail status check failed (may still be starting)"
    fi
}

# Step 3: Install and Configure auditd
install_auditd() {
    log_info "Installing and configuring auditd..."
    
    # Check if already installed
    if command -v auditctl &> /dev/null; then
        log_warn "auditd already installed"
    else
        eval "$PKG_UPDATE" > /dev/null 2>&1 || true
        eval "$PKG_INSTALL audit audit-libs" > /dev/null 2>&1
        log_success "auditd installed"
    fi
    
    # Enable and start auditd
    systemctl enable auditd > /dev/null
    systemctl start auditd
    log_success "auditd enabled and started"
}

# Step 4: Add Audit Rule for Secrets File
add_audit_rule() {
    log_info "Adding audit rule for secrets file..."
    
    # Only persist a file watch when the path exists; augenrules fails on missing -w targets.
    mkdir -p /etc/audit/rules.d
    if [ -f "$SECRETS_FILE" ]; then
        cat > /etc/audit/rules.d/secrets.rules <<EOF
-w $SECRETS_FILE -p wa -k secrets_access
EOF
        auditctl -w "$SECRETS_FILE" -p wa -k secrets_access 2>/dev/null || true
        log_success "Persistent audit rule added to /etc/audit/rules.d/secrets.rules"
    else
        log_warn "Secrets file does not exist yet ($SECRETS_FILE) — skipping audit watch until file exists"
        rm -f /etc/audit/rules.d/secrets.rules
    fi
    
    # Verify rule is in persistent config
    if grep -q "secrets_access" /etc/audit/rules.d/secrets.rules; then
        log_success "Audit rule verified in persistent configuration"
    else
        log_error "Failed to add audit rule to persistent configuration"
        return 1
    fi
}

# Step 5: Verify All Changes
verify_hardening() {
    log_info "Verifying hardening configuration..."
    
    local all_good=true
    
    # Check SSH configurations
    if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config; then
        log_success "SSH root login is disabled"
    else
        log_error "SSH root login is NOT disabled"
        all_good=false
    fi
    
    if grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config; then
        log_success "SSH public key authentication is enabled"
    else
        log_error "SSH public key authentication is NOT enabled"
        all_good=false
    fi
    
    if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
        log_success "SSH password authentication is disabled"
    else
        log_error "SSH password authentication is NOT disabled"
        all_good=false
    fi
    
    if grep -q "^PermitEmptyPasswords no" /etc/ssh/sshd_config; then
        log_success "SSH empty passwords are disabled"
    else
        log_error "SSH empty passwords are NOT disabled"
        all_good=false
    fi
    
    if grep -q "^ChallengeResponseAuthentication no" /etc/ssh/sshd_config; then
        log_success "SSH challenge-response authentication is disabled"
    else
        log_error "SSH challenge-response authentication is NOT disabled"
        all_good=false
    fi
    
    if grep -q "^UsePAM yes" /etc/ssh/sshd_config; then
        log_success "SSH PAM is enabled"
    else
        log_error "SSH PAM is NOT enabled"
        all_good=false
    fi
    
    # Check fail2ban running
    if systemctl is-active --quiet fail2ban; then
        log_success "fail2ban is running"
    else
        log_error "fail2ban is NOT running"
        all_good=false
    fi
    
    # Check auditd running
    if systemctl is-active --quiet auditd; then
        log_success "auditd is running"
    else
        log_error "auditd is NOT running"
        all_good=false
    fi
    
    # Check audit rule (in persistent config, may not be active if file doesn't exist yet)
    if grep -q "secrets_access" /etc/audit/rules.d/secrets.rules; then
        log_success "Audit rule for secrets is configured (will activate when file is created)"
    else
        log_error "Audit rule for secrets is NOT configured"
        all_good=false
    fi
    
    return $([ "$all_good" = true ] && echo 0 || echo 1)
}

# Step 6: Check critical settings haven't drifted
check_hardening_drift() {
    log_info "Checking critical hardening settings..."

    local drift_found=false

    # Ensure root SSH login stays disabled
    if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config; then
        log_success "Root SSH login is disabled"
    else
        log_error "Root SSH login is NOT disabled — drift detected"
        drift_found=true
    fi

    # Ensure password auth stays disabled
    if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
        log_success "Password authentication is disabled"
    else
        log_error "Password authentication is NOT disabled — drift detected"
        drift_found=true
    fi

    # Ensure fail2ban is enabled
    if systemctl is-enabled fail2ban &> /dev/null; then
        log_success "fail2ban is enabled"
    else
        log_error "fail2ban is NOT enabled — drift detected"
        drift_found=true
    fi

    # Ensure firewalld is NOT active (infra uses raw iptables for port filtering)
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        log_error "firewalld is active — conflicts with iptables host firewall, drift detected"
        drift_found=true
    else
        log_success "firewalld is inactive (iptables-based filtering expected)"
    fi

    # Ensure iptables host firewall chain is present
    if iptables -nL INFRA_HOST_FW &>/dev/null 2>&1; then
        log_success "iptables INFRA_HOST_FW chain is active"
    else
        log_warn "iptables INFRA_HOST_FW chain not found — run configure-host-firewall-oneoff.sh enable"
    fi

    if [ "$drift_found" = true ]; then
        log_error "Configuration drift detected! Review and re-run hardening."
        return 1
    fi

    log_success "No drift detected — all critical settings intact"
}

# Main execution
main() {
    log_info "Starting server hardening process..."
    log_warn "This script will modify SSH configuration and install security tools"
    echo ""
    
    check_root
    detect_package_manager
    
    # Execute hardening steps
    harden_ssh || { log_error "SSH hardening failed"; exit 1; }
    install_fail2ban || { log_error "fail2ban installation failed"; exit 1; }
    install_auditd || { log_error "auditd installation failed"; exit 1; }
    add_audit_rule || { log_error "Audit rule addition failed"; exit 1; }
    
    check_hardening_drift || { log_error "Hardening drift check failed"; exit 1; }

    echo ""
    if verify_hardening; then
        log_success "All hardening steps completed successfully!"
        echo ""
        log_info "Next steps:"
        echo "  1. Test SSH key auth in a new terminal: ssh -i ~/.ssh/id_rsa_main deploy@<host>"
        echo "  2. Review fail2ban status: sudo fail2ban-client status sshd"
        echo "  3. Monitor audit logs: sudo ausearch -k secrets_access"
        echo "  4. Read docs/SERVER_HARDENING.md for detailed monitoring instructions"
    else
        log_error "Some hardening steps failed. Please review the output above."
        exit 1
    fi
}

main "$@"
