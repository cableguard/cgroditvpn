#!/bin/bash
# Restart Podman API stacks (infra → app → nginx) in dependency order.
# Skips services with no matching infra container on this host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"
# shellcheck source=infra-podman-helper.sh
source "$SCRIPT_DIR/infra-podman-helper.sh"

podman_cmd() {
    infra_run_as_user "$INFRA_USER" podman "$@"
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if a container is running
check_container_status() {
    local container_name=$1
    local status=$(podman_cmd inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null)
    
    if [ "$status" = "running" ]; then
        return 0
    else
        return 1
    fi
}

# Function to get container logs
get_container_logs() {
    local container_name=$1
    echo -e "${YELLOW}Last few lines of logs for $container_name:${NC}"
    podman_cmd logs --tail 10 "$container_name"
}

# Function to stop a container
stop_container() {
    local container_name=$1
    echo -e "${YELLOW}Stopping $container_name...${NC}"
    podman_cmd stop "$container_name" >/dev/null 2>&1
    sleep 2
}

# Function to start a container and verify it's running
start_container() {
    local container_name=$1
    local max_retries=3
    local retry_count=0
    echo -e "${YELLOW}Starting $container_name...${NC}"
    
    while [ $retry_count -lt $max_retries ]; do
        podman_cmd start "$container_name" >/dev/null 2>&1
        
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

# Function to check if container exists
container_exists() {
    local container_name=$1
    podman_cmd container exists "$container_name"
    return $?
}

# Function to restart a service group
restart_service() {
    local service_name=$1
    local port=$2
    
    echo -e "\n${YELLOW}Restarting $service_name service...${NC}"
    
    # Find the infra container for this service
    local INFRA_CONTAINER
    INFRA_CONTAINER="$(infra_find_infra_container "$port")"
    if [ -z "$INFRA_CONTAINER" ]; then
        echo -e "${YELLOW}○ Skipping $service_name (no infra container on port $port)${NC}"
        return 0
    fi
    
    # Mint-style stacks: infra + $service-container + $service-nginx.
    # Agent ingress: infra + openclaw-nginx (no $service-container).
    local wanted=(
        "$INFRA_CONTAINER"
        "$service_name-container"
        "$service_name-nginx"
    )
    local probe=""
    local def name rest
    for def in "${INFRA_MONITOR_SERVICES[@]}"; do
        name="${def%%:*}"
        if [[ "$name" == "$service_name" ]]; then
            rest="${def#*:}"
            probe="${rest%%:*}"
            break
        fi
    done
    if [[ -n "$probe" ]]; then
        wanted+=("$probe")
    fi

    local containers=()
    local container
    for container in "${wanted[@]}"; do
        [[ -n "$container" ]] || continue
        local already=0
        local c
        for c in "${containers[@]+"${containers[@]}"}"; do
            [[ "$c" == "$container" ]] && already=1 && break
        done
        [[ "$already" -eq 1 ]] && continue
        if container_exists "$container"; then
            containers+=("$container")
        fi
    done

    if [[ ${#containers[@]} -eq 0 ]]; then
        echo -e "${YELLOW}○ Skipping $service_name (no matching containers)${NC}"
        return 0
    fi
    
    # Stop containers in reverse order
    for ((i=${#containers[@]}-1; i>=0; i--)); do
        stop_container "${containers[i]}"
    done
    
    # Prune logs for this service
    echo -e "${YELLOW}Pruning logs for $service_name containers...${NC}"
    for container in "${containers[@]}"; do
        podman_cmd logs --truncate 0 "$container" >/dev/null 2>&1
    done
    
    # Start containers in order
    for container in "${containers[@]}"; do
        if ! start_container "$container"; then
            echo -e "${RED}Error: Failed to start $container. Stopping script.${NC}"
            get_container_logs "$container"
            return 1
        fi
        sleep 5
    done
    
    return 0
}

# Main script
echo "Starting service restart process..."

# Restart each service defined in infra-env-helper (Alma host layout)
all_successful=true
skipped_any=false
for service in "${!INFRA_API_PORTS[@]}"; do
    port="${INFRA_API_PORTS[$service]}"
    if ! infra_find_infra_container "$port" >/dev/null; then
        skipped_any=true
        continue
    fi
    if ! restart_service "$service" "$port"; then
        all_successful=false
        echo -e "${RED}Failed to restart $service service${NC}"
    fi
done

# Final status report
echo -e "\n${YELLOW}Final status report:${NC}"
for service in "${!INFRA_API_PORTS[@]}"; do
    port="${INFRA_API_PORTS[$service]}"
    INFRA_CONTAINER="$(infra_find_infra_container "$port")"
    [[ -z "$INFRA_CONTAINER" ]] && continue
    echo -e "\n${YELLOW}$service service containers:${NC}"
    containers=("$INFRA_CONTAINER")
    container_exists "$service-container" && containers+=("$service-container")
    container_exists "$service-nginx" && containers+=("$service-nginx")
    probe=""
    for def in "${INFRA_MONITOR_SERVICES[@]}"; do
        name="${def%%:*}"
        if [[ "$name" == "$service" ]]; then
            rest="${def#*:}"
            probe="${rest%%:*}"
            break
        fi
    done
    if [[ -n "$probe" ]] && container_exists "$probe"; then
        already=0
        for c in "${containers[@]}"; do
            [[ "$c" == "$probe" ]] && already=1 && break
        done
        [[ "$already" -eq 0 ]] && containers+=("$probe")
    fi

    for container in "${containers[@]}"; do
        if check_container_status "$container"; then
            echo -e "${GREEN}✓ $container is running${NC}"
        else
            echo -e "${RED}✗ $container is not running${NC}"
            get_container_logs "$container"
            all_successful=false
        fi
    done
done

if [ "$all_successful" = true ]; then
    echo -e "\n${GREEN}All services restarted successfully!${NC}"
    echo -e "Services should now be accessible on their respective ports:"
    for service in "${!INFRA_API_PORTS[@]}"; do
        port="${INFRA_API_PORTS[$service]}"
        if infra_find_infra_container "$port" >/dev/null; then
            echo -e "${GREEN}$service: $port${NC}"
        fi
    done
    exit 0
else
    echo -e "\n${RED}Some services failed to restart. Please check the logs for more information.${NC}"
    exit 1
fi
