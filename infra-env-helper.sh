#!/usr/bin/env bash
# Load host-local config from sibling ~/infra-app (same pattern as hermes-agents-app).
# Scripts source this file from the infra checkout; machine-specific values live outside git.
#
# Override: INFRA_APP_DIR, INFRA_REPO, INFRA_USER, INFRA_HOME

if [[ -n "${INFRA_ENV_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

_INFRA_LOADER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_REPO="${INFRA_REPO:-$_INFRA_LOADER_DIR}"

if [[ -z "${INFRA_APP_DIR:-}" ]]; then
  INFRA_APP_DIR="$(cd "${INFRA_REPO}/.." && pwd)/infra-app"
fi

_INFRA_HOST_ENV="${INFRA_APP_DIR}/infra-env-helper.sh"

if [[ ! -f "$_INFRA_HOST_ENV" ]]; then
  cat >&2 <<EOF
Error: missing host profile: ${_INFRA_HOST_ENV}

This git checkout has no machine config. Create it once:

  ${INFRA_REPO}/bootstrap-infra-app.sh
  # or a named template: ${INFRA_REPO}/bootstrap-infra-app.sh example
  # or interactive:      ${INFRA_REPO}/bootstrap-infra-app.sh custom

Then edit ${_INFRA_HOST_ENV} and run:
  ${INFRA_REPO}/bootstrap-app-dir-layout.sh
  sudo ${INFRA_REPO}/setup-host-oneoff.sh

See: ${INFRA_REPO}/infra-env-helper.md
EOF
  return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source "$_INFRA_HOST_ENV"
