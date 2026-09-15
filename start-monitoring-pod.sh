#!/usr/bin/env bash
# Start the Grafana/Loki Podman pod (monitoring-pod) without redeploying.
# If the pod is missing, run deploy-monitoring.sh when present.
#
# Usage:
#   ./start-monitoring-pod.sh
#   sudo -u dedalo46 ./start-monitoring-pod.sh   # rootless store

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

POD="${INFRA_MONITORING_POD:-monitoring-pod}"
PROBE="${INFRA_MONITORING_PROBE_CONTAINER:-monitoring-grafana}"
DEPLOY="${INFRA_MONITORING_DEPLOY_SCRIPT:-${INFRA_HOME}/grafanaloki-app/deploy-monitoring.sh}"

podman_cmd() {
  podman "$@"
}

probe_running() {
  [[ "$(podman_cmd inspect -f '{{.State.Status}}' "$PROBE" 2>/dev/null || echo missing)" == "running" ]]
}

if podman_cmd pod exists "$POD" 2>/dev/null; then
  if probe_running; then
    exit 0
  fi
  podman_cmd pod start "$POD"
  exit 0
fi

if [[ -f "$DEPLOY" ]]; then
  exec bash "$DEPLOY"
fi

echo "Error: pod $POD not found and no deploy script at $DEPLOY" >&2
exit 1
