#!/usr/bin/env bash
# Start the lastcradle-be production pod (slcbackend-pod) without rebuilding.
# Used on boot (user systemd unit) and by monitor-pods-liveness.
#
# Usage:
#   ./start-slcbackend-pod.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

POD="${INFRA_SLCBACKEND_POD:-slcbackend-pod}"
PROBE="${INFRA_SLCBACKEND_PROBE_CONTAINER:-slcbackend-container}"
DEPLOY="${INFRA_SLCBACKEND_DEPLOY_SCRIPT:-${INFRA_HOME}/slcbackend-slc/scripts/deploy-local-podman.sh}"

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
  exec env TARGET=main bash "$DEPLOY" --skip-build
fi

echo "Error: pod $POD not found and no deploy script at $DEPLOY" >&2
exit 1
