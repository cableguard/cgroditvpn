#!/usr/bin/env bash
# Start a Podman pod if it exists; otherwise run an optional deploy script.
#
# Usage:
#   ./start-pod.sh <pod> <probe-container> [deploy-script] [deploy-arg...]
#   ./start-pod.sh <service> [ignored-port]
#       Looks up INFRA_POD_START[<service>] =
#         "pod|probe|deploy-script|deploy-arg..."
#       Optional INFRA_POD_START_ENV[<service>]="KEY=val KEY2=val" for deploy.
#
# Liveness monitor invokes: bash start-pod.sh <service> <port>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=infra-env-helper.sh
source "$SCRIPT_DIR/infra-env-helper.sh"

POD=""
PROBE=""
DEPLOY=""
DEPLOY_ARGS=()
DEPLOY_ENV=()

if [[ $# -ge 1 && -n "${INFRA_POD_START[$1]+x}" ]]; then
  IFS='|' read -r POD PROBE DEPLOY rest <<<"${INFRA_POD_START[$1]}"
  if [[ -n "${rest:-}" ]]; then
    # shellcheck disable=SC2206
    DEPLOY_ARGS=($rest)
  fi
  if [[ -n "${INFRA_POD_START_ENV[$1]+x}" && -n "${INFRA_POD_START_ENV[$1]}" ]]; then
    # shellcheck disable=SC2206
    DEPLOY_ENV=(${INFRA_POD_START_ENV[$1]})
  fi
elif [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
  echo "Error: no INFRA_POD_START[$1] in the host profile (liveness passes <service> <port>)" >&2
  exit 1
elif [[ $# -ge 2 ]]; then
  POD="$1"
  PROBE="$2"
  if [[ $# -ge 3 ]]; then
    DEPLOY="$3"
    if [[ $# -gt 3 ]]; then
      DEPLOY_ARGS=("${@:4}")
    fi
  fi
else
  echo "Usage: $0 <pod> <probe-container> [deploy-script] [deploy-arg...]" >&2
  echo "   or: $0 <service>   # requires INFRA_POD_START[service] in the host profile" >&2
  exit 1
fi

if [[ -z "$POD" || -z "$PROBE" ]]; then
  echo "Error: pod and probe container are required" >&2
  exit 1
fi

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

if [[ -n "$DEPLOY" && -f "$DEPLOY" ]]; then
  if [[ ${#DEPLOY_ENV[@]} -gt 0 ]]; then
    exec env "${DEPLOY_ENV[@]}" bash "$DEPLOY" ${DEPLOY_ARGS[@]+"${DEPLOY_ARGS[@]}"}
  fi
  exec bash "$DEPLOY" ${DEPLOY_ARGS[@]+"${DEPLOY_ARGS[@]}"}
fi

echo "Error: pod $POD not found and no deploy script${DEPLOY:+ at $DEPLOY}" >&2
exit 1
