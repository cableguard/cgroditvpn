#!/usr/bin/env bash
# Compatibility wrapper — use setup-host-oneoff.sh (reads ~/infra-app).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/setup-host-oneoff.sh" "$@"
