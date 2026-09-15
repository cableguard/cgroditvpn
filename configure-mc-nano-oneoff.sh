#!/usr/bin/env bash
# Use nano (not mcedit) when editing files from Midnight Commander (F4).
#
# MC 4.8.x: disable internal edit in ~/.config/mc/ini and export EDITOR with a
# full path before starting mc. Quit mc before running this script so
# auto_save_setup does not overwrite the ini on exit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/infra-env-helper.sh" ]]; then
  # shellcheck source=infra-env-helper.sh
  source "$SCRIPT_DIR/infra-env-helper.sh"
fi
INFRA_USER="${INFRA_USER:-$(id -un)}"
INFRA_HOME="${INFRA_HOME:-/home/${INFRA_USER}}"

NANO_BIN="$(command -v nano || true)"
if [[ -z "$NANO_BIN" ]]; then
  echo "nano not found; install with: sudo dnf install -y nano" >&2
  exit 1
fi

MC_INI="${INFRA_HOME}/.config/mc/ini"
BASHRC="${INFRA_HOME}/.bashrc"

mkdir -p "$(dirname "$MC_INI")"

if [[ ! -f "$MC_INI" ]]; then
  mc -c >/dev/null 2>&1 || true
fi

if [[ ! -f "$MC_INI" ]]; then
  cat >"$MC_INI" <<EOF
[Midnight-Commander]
editor=${NANO_BIN}
use_internal_edit=false

[External editor or viewer parameters]
${NANO_BIN}=+%lineno %filename
EOF
else
  if grep -q '^use_internal_edit=' "$MC_INI"; then
    sed -i 's/^use_internal_edit=.*/use_internal_edit=false/' "$MC_INI"
  else
    sed -i "/^\[Midnight-Commander\]/a use_internal_edit=false" "$MC_INI"
  fi
  if grep -q '^editor=' "$MC_INI"; then
    sed -i "s|^editor=.*|editor=${NANO_BIN}|" "$MC_INI"
  else
    sed -i "/^\[Midnight-Commander\]/a editor=${NANO_BIN}" "$MC_INI"
  fi
  if ! grep -q '^\[External editor or viewer parameters\]' "$MC_INI"; then
    printf '\n[External editor or viewer parameters]\n%s=+%%lineno %%filename\n' "$NANO_BIN" >>"$MC_INI"
  fi
fi

if [[ -f "$BASHRC" ]]; then
  if grep -q '^export EDITOR=' "$BASHRC"; then
    sed -i "s|^export EDITOR=.*|export EDITOR=${NANO_BIN}|" "$BASHRC"
  else
    printf '\nexport EDITOR=%s\n' "$NANO_BIN" >>"$BASHRC"
  fi
  if grep -q '^export VISUAL=' "$BASHRC"; then
    sed -i "s|^export VISUAL=.*|export VISUAL=${NANO_BIN}|" "$BASHRC"
  else
    printf 'export VISUAL=%s\n' "$NANO_BIN" >>"$BASHRC"
  fi
else
  printf 'export EDITOR=%s\nexport VISUAL=%s\n' "$NANO_BIN" "$NANO_BIN" >"$BASHRC"
fi

if [[ "$(id -un)" == root && -n "${INFRA_USER:-}" ]]; then
  chown "${INFRA_USER}:${INFRA_USER}" "$MC_INI" "$BASHRC" 2>/dev/null || true
  chmod u+w "$MC_INI" 2>/dev/null || true
fi

echo "Configured ${MC_INI}:"
grep -E '^editor=|^use_internal_edit=' "$MC_INI" || true
echo ""
echo "Configured ${BASHRC}:"
grep -E '^export (EDITOR|VISUAL)=' "$BASHRC" || true
echo ""
echo "Next steps:"
echo "  1. Quit mc completely (all instances)."
echo "  2. source ${BASHRC}"
echo "  3. mc   then F4 on a file — should open nano."
echo ""
echo "If F4 still uses mcedit, in mc: Options → Configuration → uncheck"
echo "  \"Use internal edit\", OK, then quit mc once to save."
