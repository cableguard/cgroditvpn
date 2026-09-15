#!/usr/bin/env bash
# Rootless Podman boot/autostart helpers (source only).
#
# unless-stopped only survives reboot when:
#   1. loginctl enable-linger INFRA_USER
#   2. systemctl --user enable podman-restart.service (as INFRA_USER)

infra_run_as_user() {
  local user="${1:?}"
  shift
  if [[ "$(id -un)" == "$user" ]]; then
    "$@"
    return $?
  fi
  if ! command -v runuser >/dev/null 2>&1; then
    echo "Error: runuser required to run commands as $user" >&2
    return 1
  fi
  local uid
  uid="$(id -u "$user")"
  runuser -u "$user" -- env \
    XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
    HOME="${INFRA_HOME:-/home/${user}}" \
    "$@"
}

infra_enable_podman_linger() {
  local user="${1:-${INFRA_USER:-}}"
  [[ -n "$user" ]] || return 1
  if loginctl enable-linger "$user" 2>/dev/null; then
    echo "Enabled systemd linger for $user"
    return 0
  fi
  echo "Warning: failed to enable linger for $user" >&2
  return 1
}

# Lengthen podman-restart oneshot timeouts. Starting many rootless pods at once
# often exceeds the default and leaves stacks half-up (SIGKILL mid-start).
infra_install_podman_restart_timeout_dropin() {
  local user="${1:-${INFRA_USER:-}}"
  local home dropin_dir dropin
  [[ -n "$user" ]] || return 1
  home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" ]] || home="/home/$user"
  dropin_dir="${home}/.config/systemd/user/podman-restart.service.d"
  dropin="${dropin_dir}/infra-timeout.conf"

  mkdir -p "$dropin_dir"
  cat >"$dropin" <<'EOF'
[Service]
# Boot can start many rootless containers; default oneshot timeout is too short.
TimeoutStartSec=15min
TimeoutStopSec=5min
EOF
  chown -R "$user:$user" "${home}/.config/systemd" 2>/dev/null || true
  echo "Installed $dropin (TimeoutStartSec=15min)"
}

infra_enable_podman_restart_service() {
  local user="${1:-${INFRA_USER:-}}"
  local uid
  [[ -n "$user" ]] || return 1
  uid="$(id -u "$user" 2>/dev/null)" || return 1

  if ! infra_run_as_user "$user" systemctl --user list-unit-files podman-restart.service \
    &>/dev/null; then
    echo "Warning: podman-restart.service not found for $user (Podman too old or not installed?)" >&2
    return 1
  fi

  infra_install_podman_restart_timeout_dropin "$user" || true
  infra_run_as_user "$user" systemctl --user daemon-reload 2>/dev/null || true
  if infra_run_as_user "$user" systemctl --user list-unit-files podman.socket &>/dev/null; then
    infra_run_as_user "$user" systemctl --user enable --now podman.socket 2>/dev/null || true
  fi
  # Clear a previous failed boot attempt so the unit is ready for the next reboot.
  infra_run_as_user "$user" systemctl --user reset-failed podman-restart.service 2>/dev/null || true
  if infra_run_as_user "$user" systemctl --user enable podman-restart.service; then
    echo "Enabled podman-restart.service for $user (applies unless-stopped on boot)"
    return 0
  fi
  echo "Warning: failed to enable podman-restart.service for $user" >&2
  return 1
}

# Linger + podman-restart; call after setting container restart policies.
infra_enable_podman_boot_autostart() {
  local user="${1:-${INFRA_USER:-}}"
  infra_enable_podman_linger "$user" || true
  infra_enable_podman_restart_service "$user" || true
}
