#!/bin/bash
# Start service containers in dependency order.
#
# Usage:
#   ./archive/start-service-template-helper.sh <service_name> [service_port]
#   SERVICE_NAME=mintserveridc SERVICE_PORT=2443 ./archive/start-service-template-helper.sh
#
# If service_port is omitted, the script looks it up from infra-env-helper.sh
# (INFRA_API_PORTS). EXTRA_CONTAINERS may contain additional container names
# to append after the default app + nginx containers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$INFRA_ROOT/infra-env-helper.sh" ]]; then
    # shellcheck source=../infra-env-helper.sh
    source "$INFRA_ROOT/infra-env-helper.sh"
fi

# ============================================================================
# CONFIGURATION
# ============================================================================
SERVICE_NAME="${1:-${SERVICE_NAME:-}}"
SERVICE_PORT="${2:-${SERVICE_PORT:-}}"

if [[ -z "$SERVICE_NAME" ]]; then
    echo "Usage: $0 <service_name> [service_port]"
    exit 1
fi

if [[ -z "$SERVICE_PORT" ]] && declare -p INFRA_API_PORTS >/dev/null 2>&1; then
    SERVICE_PORT="${INFRA_API_PORTS[$SERVICE_NAME]:-}"
fi

if [[ -z "$SERVICE_PORT" ]]; then
    echo "Error: service port is required for $SERVICE_NAME"
    exit 1
fi

CONTAINERS=(
    "${SERVICE_NAME}-container"
    "${SERVICE_NAME}-nginx"
)

if [[ -n "${EXTRA_CONTAINERS:-}" ]]; then
    # shellcheck disable=SC2206
    CONTAINERS+=($EXTRA_CONTAINERS)
fi

# ============================================================================
# COLOR DEFINITIONS
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Function to check if a container is running
check_container_status() {
    local container_name=$1
    local status=$(podman inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null)
    
    if [ "$status" = "running" ]; then
        return 0
    else
        return 1
    fi
}

# Function to get container logs
get_container_logs() {
    local container_name=$1
    echo -e "${YELLOW}Last 10 lines of logs for $container_name:${NC}"
    podman logs --tail 10 "$container_name"
}

# Function to check if container exists
container_exists() {
    local container_name=$1
    podman container exists "$container_name"
    return $?
}

# Function to start a container and verify it's running
start_container() {
    local container_name=$1
    local max_retries=3
    local retry_count=0
    
    echo -e "${YELLOW}Starting $container_name...${NC}"
    
    while [ $retry_count -lt $max_retries ]; do
        podman start "$container_name" >/dev/null 2>&1
        
        # Wait for container to start (with timeout)
        local wait_count=0
        while [ $wait_count -lt 10 ]; do
            if check_container_status "$container_name"; then
                echo -e "${GREEN}✓ Successfully started $container_name${NC}"
                return 0
            fi
            sleep 1
            ((wait_count++))
        done
        
        # If container failed to start, get logs
        get_container_logs "$container_name"
        
        ((retry_count++))
        if [ $retry_count -lt $max_retries ]; then
            echo -e "${YELLOW}Retrying to start $container_name (attempt $retry_count of $max_retries)${NC}"
        fi
    done
    
    echo -e "${RED}✗ Failed to start $container_name after $max_retries attempts${NC}"
    return 1
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

echo "Starting ${SERVICE_NAME} containers..."

# Find the infra container for the specified port
if declare -F infra_find_infra_container >/dev/null 2>&1; then
    INFRA_CONTAINER="$(infra_find_infra_container "$SERVICE_PORT")"
else
    INFRA_CONTAINER=$(podman ps -a --format '{{if eq .Ports "0.0.0.0:'"$SERVICE_PORT"'->'"$SERVICE_PORT"'/tcp"}}{{.Names}}{{end}}' | grep -E ".*-infra$" | head -n 1)
fi

if [ -z "$INFRA_CONTAINER" ]; then
    echo -e "${YELLOW}Warning: Could not find infrastructure container for port ${SERVICE_PORT}${NC}"
    echo -e "${YELLOW}Proceeding without infra container...${NC}"
else
    echo -e "${GREEN}Found infra container: $INFRA_CONTAINER${NC}"
    # Prepend infra container to the array
    CONTAINERS=("$INFRA_CONTAINER" "${CONTAINERS[@]}")
fi

# Verify all containers exist before starting
echo -e "\n${YELLOW}Verifying containers exist...${NC}"
for container in "${CONTAINERS[@]}"; do
    if ! container_exists "$container"; then
        echo -e "${RED}Error: Container $container does not exist${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ $container exists${NC}"
done

# Start each container in order
echo -e "\n${YELLOW}Starting containers in sequence...${NC}"
for container in "${CONTAINERS[@]}"; do
    if ! start_container "$container"; then
        echo -e "${RED}Error: Failed to start $container. Stopping script.${NC}"
        get_container_logs "$container"
        exit 1
    fi
    sleep 5  # Wait between container starts
done

# Final status check
echo -e "\n${YELLOW}Checking final status of all containers...${NC}"
all_running=true

for container in "${CONTAINERS[@]}"; do
    if check_container_status "$container"; then
        echo -e "${GREEN}✓ $container is running${NC}"
    else
        echo -e "${RED}✗ $container is not running${NC}"
        get_container_logs "$container"
        all_running=false
    fi
done

# Final summary
if [ "$all_running" = true ]; then
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}All containers started successfully!${NC}"
    echo -e "${GREEN}${SERVICE_NAME} service is accessible on port ${SERVICE_PORT}${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    echo -e "\n${RED}========================================${NC}"
    echo -e "${RED}Some containers failed to start.${NC}"
    echo -e "${RED}Please check the logs above.${NC}"
    echo -e "${RED}========================================${NC}"
    exit 1
fi
