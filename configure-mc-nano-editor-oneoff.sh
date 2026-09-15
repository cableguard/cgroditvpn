#!/usr/bin/env bash
# Point Midnight Commander F4 at nano (not the built-in mcedit).
# Usage: ./configure-mc-nano-editor-oneoff.sh [username]
#        sudo ./configure-mc-nano-editor-oneoff.sh dedalo46
#
# MC reads ~/.config/mc/ini — EDITOR alone is not enough; you need both:
#   use_internal_edit=false
#   editor=/usr/bin/nano
#
# Quit mc before running this, or MC may overwrite ini on exit (auto_save_setup).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/infra-env-helper.sh" ]]; then
  # shellcheck source=infra-env-helper.sh
  source "$SCRIPT_DIR/infra-env-helper.sh"
fi

TARGET_USER="${1:-${SUDO_USER:-${INFRA_USER:-$USER}}}"
if [[ "$TARGET_USER" == root ]]; then
  echo "Specify a login user, not root: $0 dedalo46" >&2
  exit 1
fi

if ! command -v nano >/dev/null 2>&1; then
  echo "nano not installed (e.g. sudo dnf install -y nano mc)" >&2
  exit 1
fi

NANO_BIN="$(command -v nano)"
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
  echo "No home directory for user: $TARGET_USER" >&2
  exit 1
fi

MC_DIR="$HOME_DIR/.config/mc"
INI="$MC_DIR/ini"

run_as_user() {
  if [[ "$(id -un)" == "$TARGET_USER" ]]; then
    "$@"
  else
    sudo -u "$TARGET_USER" -- "$@"
  fi
}

if [[ ! -f "$INI" ]]; then
  echo "Creating $INI (run mc once)..."
  run_as_user mkdir -p "$MC_DIR"
  run_as_user env TERM="${TERM:-xterm}" mc -c </dev/null 2>/dev/null || true
fi

if [[ ! -f "$INI" ]]; then
  echo "Missing $INI — install mc and run: mc -c" >&2
  exit 1
fi

if [[ ! -w "$INI" ]]; then
  if [[ "${EUID}" -ne 0 ]]; then
    echo "$INI is not writable; re-run with sudo." >&2
    exit 1
  fi
  chown "$TARGET_USER:$TARGET_USER" "$INI"
  chmod u+w "$INI"
fi

set_ini_key() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  if grep -q "^${key}=" "$INI"; then
    sed "s|^${key}=.*|${key}=${value}|" "$INI" >"$tmp"
  else
    cp "$INI" "$tmp"
    awk -v key="$key" -v val="$value" '
      /^\[Midnight-Commander\]/ { print; print key "=" val; next }
      { print }
    ' "$INI" >"$tmp"
  fi
  mv "$tmp" "$INI"
}

set_ini_key use_internal_edit false
set_ini_key editor "$NANO_BIN"
chown "$TARGET_USER:$TARGET_USER" "$INI" 2>/dev/null || true

echo "Configured MC for $TARGET_USER:"
grep -E '^editor=|^use_internal_edit=' "$INI"
echo "Restart mc and press F4 on a file — expect nano at $NANO_BIN."
