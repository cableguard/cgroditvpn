#!/bin/bash

# Vault configuration
export VAULT_ADDR='https://dev-vault.discernible-io.net:8200'

# Constants
POLICIES=(
    "signing-admin-policy"
    "signing-operator-policy"
    "signing-policy"
    "signing-reader-policy"
)
SECRET_PATH="secret/signing"

# AppRole credentials (should be provided as environment variables)
ROLE_ID="${VAULT_ROLE_ID:-}"
SECRET_ID="${VAULT_SECRET_ID:-}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level=$1
    shift
    local message=$@
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        "ERROR")
            echo -e "${RED}[ERROR] ${timestamp} - ${message}${NC}" >&2
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS] ${timestamp} - ${message}${NC}"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN] ${timestamp} - ${message}${NC}"
            ;;
        *)
            echo "[INFO] ${timestamp} - ${message}"
            ;;
    esac
}

# Function to check if required commands exist
check_prerequisites() {
    local required_commands=("vault" "jq" "curl")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log "ERROR" "Required command '$cmd' not found. Please install it first."
            exit 1
        fi
    done
}

# Function to validate policy exists
validate_policy() {
    local policy=$1
    if [[ ! " ${POLICIES[@]} " =~ " ${policy} " ]]; then
        log "ERROR" "Invalid policy: $policy"
        log "INFO" "Available policies: ${POLICIES[*]}"
        return 1
    fi
    return 0
}

# Function to authenticate with Vault
authenticate_vault() {
    if [[ -z "$ROLE_ID" || -z "$SECRET_ID" ]]; then
        log "ERROR" "VAULT_ROLE_ID and VAULT_SECRET_ID environment variables must be set"
        exit 1
    fi

    log "INFO" "Authenticating with Vault..."
    local token_response
    token_response=$(vault write -format=json auth/approle/login \
        role_id="$ROLE_ID" \
        secret_id="$SECRET_ID")
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to authenticate with Vault"
        exit 1
    fi

    export VAULT_TOKEN=$(echo "$token_response" | jq -r '.auth.client_token')
    log "SUCCESS" "Authentication successful"
}

# Function to check Vault connection
check_vault_connection() {
    if ! curl -s -k "${VAULT_ADDR}/v1/sys/health" &>/dev/null; then
        log "ERROR" "Cannot connect to Vault server at ${VAULT_ADDR}"
        exit 1
    fi
}

# Function to create/update a secret
put_secret() {
    local path=$1
    local key=$2
    local value=$3
    local policy=$4

    if ! validate_policy "$policy"; then
        return 1
    fi

    log "INFO" "Storing secret at ${path}/${key} with policy ${policy}..."
    
    if echo "$value" | jq -e . >/dev/null 2>&1; then
        # Value is valid JSON
        vault kv put "${SECRET_PATH}/${path}" "${key}=${value}" \
            "policy=${policy}" \
            metadata="{\"created_by\":\"$(whoami)\",\"created_at\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}"
    else
        # Value is a string
        vault kv put "${SECRET_PATH}/${path}" "${key}=${value}" \
            "policy=${policy}" \
            metadata="{\"created_by\":\"$(whoami)\",\"created_at\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}"
    fi

    if [ $? -eq 0 ]; then
        log "SUCCESS" "Secret stored successfully"
        return 0
    else
        log "ERROR" "Failed to store secret"
        return 1
    fi
}

# Function to retrieve a secret
get_secret() {
    local path=$1
    local key=$2

    log "INFO" "Retrieving secret from ${path}/${key}..."
    local secret_data
    secret_data=$(vault kv get -format=json "${SECRET_PATH}/${path}")
    
    if [ $? -eq 0 ]; then
        local value
        value=$(echo "$secret_data" | jq -r ".data.data.\"$key\"")
        local policy
        policy=$(echo "$secret_data" | jq -r '.data.data.policy')
        
        log "SUCCESS" "Secret retrieved successfully"
        echo "Value: $value"
        echo "Policy: $policy"
        return 0
    else
        log "ERROR" "Failed to retrieve secret"
        return 1
    fi
}

# Function to delete a secret
delete_secret() {
    local path=$1
    local key=$2

    log "INFO" "Deleting secret at ${path}/${key}..."
    vault kv delete "${SECRET_PATH}/${path}"
    
    if [ $? -eq 0 ]; then
        log "SUCCESS" "Secret deleted successfully"
        return 0
    else
        log "ERROR" "Failed to delete secret"
        return 1
    fi
}

# Function to list secrets in a path
list_secrets() {
    local path=$1

    log "INFO" "Listing secrets in ${SECRET_PATH}/${path}..."
    vault kv list -format=json "${SECRET_PATH}/${path}"
    
    if [ $? -eq 0 ]; then
        log "SUCCESS" "Secrets listed successfully"
        return 0
    else
        log "ERROR" "Failed to list secrets"
        return 1
    fi
}

# Main menu function
show_menu() {
    echo -e "\nVault Secret Management"
    echo "======================"
    echo "1. Store/Update Secret"
    echo "2. Retrieve Secret"
    echo "3. Delete Secret"
    echo "4. List Secrets"
    echo "5. Exit"
    echo "======================"
}

# Main execution
check_prerequisites
check_vault_connection
authenticate_vault

while true; do
    show_menu
    read -p "Choose an option (1-5): " choice

    case $choice in
        1)
            read -p "Enter path: " path
            read -p "Enter key: " key
            read -p "Enter value: " value
            read -p "Enter policy (${POLICIES[*]}): " policy
            put_secret "$path" "$key" "$value" "$policy"
            ;;
        2)
            read -p "Enter path: " path
            read -p "Enter key: " key
            get_secret "$path" "$key"
            ;;
        3)
            read -p "Enter path: " path
            read -p "Enter key: " key
            delete_secret "$path" "$key"
            ;;
        4)
            read -p "Enter path: " path
            list_secrets "$path"
            ;;
        5)
            log "INFO" "Exiting..."
            exit 0
            ;;
        *)
            log "WARN" "Invalid option"
            ;;
    esac
done
