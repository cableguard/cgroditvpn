#!/usr/bin/env bash
# Start the Grafana/Loki Podman pod without redeploying.
# If the pod is missing, run the monitoring deploy script when present.
#
# Usage:
#   ./start-monitoring-pod.sh
#   sudo -u <infra-user> ./start-monitoring-pod.sh   # rootless store

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

exec "$SCRIPT_DIR/start-pod.sh" \
  "${INFRA_MONITORING_POD:-monitoring-pod}" \
  "${INFRA_MONITORING_PROBE_CONTAINER:-monitoring-grafana}" \
  "${INFRA_MONITORING_DEPLOY_SCRIPT:-${INFRA_HOME}/grafanaloki-app/deploy-monitoring.sh}"
