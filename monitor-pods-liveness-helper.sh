#!/bin/bash
# Podman container liveness monitor helper (invoked by monitor-pods-liveness.service).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

LOG_FILE="/var/log/pod-monitor.log"
SERVICES=("${INFRA_MONITOR_SERVICES[@]}")

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Rootless Podman is per-user. If this script is ever run under sudo/root,
# ensure we still target the intended INFRA_USER store.
podman_cmd() {
    if [[ "${EUID:-0}" -eq 0 && -n "${INFRA_USER:-}" ]] && command -v runuser >/dev/null 2>&1; then
        local uid
        uid="$(id -u "$INFRA_USER" 2>/dev/null || true)"
        if [[ -n "$uid" ]]; then
            runuser -u "$INFRA_USER" -- env \
                XDG_RUNTIME_DIR="/run/user/${uid}" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
                podman "$@"
            return $?
        fi
    fi
    podman "$@"
}

# Rootless Podman may not be ready immediately after boot (socket/session lag).
wait_for_podman() {
    local infra_uid runtime_dir sock attempt max_attempts=24

    infra_uid="$(id -u "${INFRA_USER:-$(id -un)}" 2>/dev/null || echo "$(id -u)")"
    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/${infra_uid}}"
    sock="${runtime_dir}/podman/podman.sock"

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if [[ -S "$sock" ]] && podman_cmd info >/dev/null 2>&1; then
            [[ "$attempt" -gt 1 ]] && log_message "Podman ready after ${attempt} attempt(s)"
            return 0
        fi
        if [[ "$attempt" -eq 1 ]]; then
            log_message "Waiting for rootless Podman ($sock)..."
        fi
        # After reboot the user socket may not exist until podman.socket / user@ starts.
        if [[ "$attempt" -eq 3 || "$attempt" -eq 8 ]]; then
            if command -v systemctl >/dev/null 2>&1; then
                systemctl --user start podman.socket 2>/dev/null \
                    || log_message "Note: could not start podman.socket (user session may still be coming up)"
            fi
        fi
        sleep 5
    done

    log_message "ERROR: Podman not ready after $((max_attempts * 5))s ($sock); check linger: sudo loginctl enable-linger ${INFRA_USER:-$(id -un)}"
    return 1
}

# podman container exists can fail with stale locks ("file exists") or when the
# user session is down; fall back to podman ps -a name listing.
container_exists() {
    local name="$1"
    local err

    if podman_cmd container exists "$name" 2>/dev/null; then
        return 0
    fi

    err=$(podman_cmd container exists "$name" 2>&1) || true
    if [[ "$err" == *"file exists"* || "$err" == *"acquiring lock"* || "$err" == *"retrieving lock"* ]]; then
        log_message "WARNING: Podman lock error for $name ($err)"
    fi

    podman_cmd ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "$name"
}

restart_monitoring_pod() {
    local pod="${INFRA_MONITORING_POD:-monitoring-pod}"
    if ! podman_cmd pod exists "$pod" 2>/dev/null; then
        return 1
    fi
    log_message "Starting pod $pod for monitoring"
    podman_cmd pod start "$pod" >>"$LOG_FILE" 2>&1
}

restart_via_podman() {
    local service_name="$1"
    local container_name="$2"
    local port="$3"
    local infra pod_id pod_name
    local -a stack=()

    infra="$(infra_find_infra_container "$port")"
    [[ -n "$infra" ]] && stack+=("$infra")
    stack+=("$container_name" "${service_name}-nginx")

    # Prefer starting the pod (API stacks are pod-based on this host).
    pod_id="$(podman_cmd inspect -f '{{.PodID}}' "$container_name" 2>/dev/null || true)"
    if [[ -n "$pod_id" && "$pod_id" != "<nil>" && "$pod_id" != "null" ]]; then
        pod_name="$(podman_cmd pod inspect -f '{{.Name}}' "$pod_id" 2>/dev/null || true)"
        if [[ -n "$pod_name" && "$pod_name" != "<no value>" ]]; then
            log_message "Starting pod $pod_name for $service_name"
            if podman_cmd pod start "$pod_name" >>"$LOG_FILE" 2>&1; then
                return 0
            fi
        fi
        log_message "Pod start failed for $service_name; falling back to container start"
    fi

    for c in "${stack[@]}"; do
        if container_exists "$c"; then
            podman_cmd start "$c" >>"$LOG_FILE" 2>&1 || true
        fi
    done
}

check_and_restart() {
    local service_name="$1"
    local container_name="$2"
    local start_script="$3"
    local port="${4:-}"
    local infra_uid runtime_dir

    infra_uid="$(id -u "${INFRA_USER:-$(id -un)}" 2>/dev/null || echo "$(id -u)")"
    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/${infra_uid}}"

    if ! container_exists "$container_name"; then
        if [[ ! -d "$runtime_dir" ]]; then
            log_message "ERROR: User runtime missing ($runtime_dir); enable linger: sudo loginctl enable-linger ${INFRA_USER:-$(id -un)}"
        else
            log_message "WARNING: Container $container_name does not exist for $service_name"
        fi
        return 1
    fi

    local status
    status=$(podman_cmd inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || echo "missing")
    if [[ "$status" == "running" ]]; then
        return 0
    fi

    log_message "ALERT: $service_name ($container_name) is $status - initiating restart"

    if [[ -n "$start_script" && -f "$start_script" ]]; then
        if SERVICE_NAME="$service_name" SERVICE_PORT="$port" bash "$start_script" "$service_name" "$port" >>"$LOG_FILE" 2>&1; then
            log_message "SUCCESS: $service_name restarted via $start_script"
            return 0
        fi
        log_message "ERROR: start script failed for $service_name ($start_script); falling back to podman restart"
    elif [[ -n "$start_script" ]]; then
        log_message "ERROR: configured start script not found for $service_name ($start_script); falling back to podman restart"
    fi

    if [[ -z "$port" ]]; then
        if [[ "$service_name" == "monitoring" ]] && restart_monitoring_pod; then
            status=$(podman_cmd inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || echo "missing")
            if [[ "$status" == "running" ]]; then
                log_message "SUCCESS: $service_name restarted via podman pod start"
                return 0
            fi
        fi
        log_message "ERROR: no start script and no infra port for $service_name"
        return 1
    fi

    restart_via_podman "$service_name" "$container_name" "$port"
    status=$(podman_cmd inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || echo "missing")
    if [[ "$status" == "running" ]]; then
        log_message "SUCCESS: $service_name restarted via podman (port $port)"
        return 0
    fi
    log_message "ERROR: podman restart did not bring $container_name up"
    return 1
}

log_message "Starting pod monitoring check (user=${INFRA_USER:-?} home=${INFRA_HOME})"

if ! wait_for_podman; then
    log_message "Monitoring check complete - Errors: 1 (podman unavailable)"
    exit 1
fi

error_count=0
for service_def in "${SERVICES[@]}"; do
    IFS=':' read -r name container script port <<<"$service_def"
    if ! check_and_restart "$name" "$container" "$script" "$port"; then
        ((error_count++)) || true
    fi
done

log_message "Monitoring check complete - Errors: $error_count"
