#!/usr/bin/env bash
# Periodic host health checks for long-term uptime (disk, inodes, time sync,
# failed units, swap, journal size). Use: init | enable-permanent | status | report
#
# Run log policy: no compression and no archive files (.1, .gz). When runs.log
# exceeds HUP_LOG_MAX_BYTES, old data is discarded in place (see HUP_LOG_TRIM_MODE).
set -euo pipefail

UNIT_BASENAME="host-uptime-prep"
STATE_DIR="/var/lib/${UNIT_BASENAME}"
LOG_DIR="/var/log/${UNIT_BASENAME}"
RUN_LOG="${LOG_DIR}/runs.log"
SERVICE_PATH="/etc/systemd/system/${UNIT_BASENAME}.service"
TIMER_PATH="/etc/systemd/system/${UNIT_BASENAME}.timer"

SCRIPT_REALPATH="$(readlink -f "${BASH_SOURCE[0]}")"

usage() {
  cat <<'EOF'
host-uptime-prep — periodic host sanity checks for long-running Linux servers

Usage: host-uptime-prep.sh <command>
   or: host-uptime-prep.sh help

What it does
  Installs a systemd timer that runs an hourly oneshot service. Each run records
  a JSON line to /var/log/host-uptime-prep/runs.log with:
    • root filesystem and inode use on /
    • MemAvailable, swap presence, rough NTP/time-sync status
    • count of failed systemd units, journal disk usage string
  Each line is tagged ok, warn, or crit based on thresholds (see Environment).
  Logs are never compressed or rotated to side files; when runs.log exceeds
  HUP_LOG_MAX_BYTES, old content is discarded in place (see HUP_LOG_TRIM_MODE).

Supported Linux distributions
  Intended for recent glibc-based distributions that use systemd as PID 1, with
  typical GNU userland (coreutils stat, df, awk, sed). Examples that match this
  profile: Debian 10+, Ubuntu 18.04+, Fedora, CentOS Stream / RHEL 8+, AlmaLinux,
  Rocky Linux, Arch Linux, openSUSE Leap 15+ / Tumbleweed.
  Not supported: non-Linux; Linux without systemd; minimal images that omit
  timedatectl/journalctl or replace coreutils with incompatible tools.

Commands
  help, -h, --help   Show this message.
  init               Install systemd units and log dirs (requires root).
  enable-permanent   Enable and start the periodic timer (requires root).
  status             Show whether timer, time sync, and last run look healthy.
  report             Summarize check results from the last 24 hours.
  run                Run checks once and append to the log (used by systemd).

Environment
  HUP_DISK_WARN_PCT   Root FS warn threshold (default: 85)
  HUP_DISK_CRIT_PCT   Root FS critical threshold (default: 92)
  HUP_INODE_WARN_PCT  Root inode warn threshold (default: 85)
  HUP_MEM_WARN_KB     MemAvailable below this => warn (default: 256000)
  HUP_LOG_MAX_BYTES   When runs.log exceeds this size, trim (default: 52428800)
  HUP_LOG_TRIM_MODE   partial = drop oldest bytes in place (default);
                      truncate or delete = empty the log when over the limit
EOF
  printf 'This script: %s\n' "${SCRIPT_REALPATH}"
}

need_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    echo "Error: this command must be run as root (sudo)." >&2
    exit 1
  fi
}

ensure_dirs() {
  need_root
  install -d -m 0755 -o root -g root "$STATE_DIR"
  install -d -m 0755 -o root -g root "$LOG_DIR"
  touch "$RUN_LOG"
  chmod 0644 "$RUN_LOG"
}

write_systemd_units() {
  need_root
  cat >"$SERVICE_PATH" <<EOF
[Unit]
Description=Host uptime prep periodic checks
Documentation=file://${SCRIPT_REALPATH}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${SCRIPT_REALPATH} run
Nice=10
IOSchedulingClass=best-effort
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_PATH"

  cat >"$TIMER_PATH" <<EOF
[Unit]
Description=Timer for ${UNIT_BASENAME} checks
Documentation=file://${SCRIPT_REALPATH}

[Timer]
OnBootSec=12min
OnUnitActiveSec=1h
Persistent=true
AccuracySec=5min

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$TIMER_PATH"
}

cmd_init() {
  need_root
  ensure_dirs
  write_systemd_units
  systemctl daemon-reload
  echo "Installed:"
  echo "  $SERVICE_PATH"
  echo "  $TIMER_PATH"
  echo "  $LOG_DIR"
  echo "Run: sudo $SCRIPT_REALPATH enable-permanent"
}

cmd_enable_permanent() {
  need_root
  if [[ ! -f "$TIMER_PATH" ]]; then
    echo "Timer unit missing. Run: sudo $SCRIPT_REALPATH init" >&2
    exit 1
  fi
  systemctl daemon-reload
  systemctl enable --now "${UNIT_BASENAME}.timer"
  systemctl start "${UNIT_BASENAME}.service" || true
  echo "Enabled and started ${UNIT_BASENAME}.timer"
  systemctl status "${UNIT_BASENAME}.timer" --no-pager -l || true
}

root_fs_use_pct() {
  df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

root_inode_use_pct() {
  df -Pi / | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

mem_available_kb() {
  awk '/^MemAvailable:/ {print $2}' /proc/meminfo
}

ntp_sync_ok() {
  if command -v timedatectl >/dev/null 2>&1; then
    local v
    v="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    if [[ "$v" == "yes" ]]; then
      echo yes
      return
    fi
  fi
  if command -v chronyc >/dev/null 2>&1 && {
    systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null
  }; then
    if chronyc tracking >/dev/null 2>&1; then
      echo yes
      return
    fi
  fi
  if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    echo maybe
    return
  fi
  echo no
}

failed_units_count() {
  systemctl --failed --no-legend 2>/dev/null | wc -l | tr -d ' '
}

swap_total_kb() {
  awk '/^SwapTotal:/ {print $2}' /proc/meminfo
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# Drops log data when too large. Never writes compressed or archived copies.
trim_run_log_if_needed() {
  local f="$RUN_LOG"
  local max="${HUP_LOG_MAX_BYTES:-52428800}"
  local mode="${HUP_LOG_TRIM_MODE:-partial}"
  [[ -f "$f" ]] || return 0
  local sz
  sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  [[ "$sz" -gt "$max" ]] || return 0

  if [[ "$mode" == "truncate" ]] || [[ "$mode" == "delete" ]]; then
    : >"$f"
    return 0
  fi

  local tmp target_bytes
  tmp="$(mktemp -p "${LOG_DIR}" ".trim.XXXXXX")"
  target_bytes=$((max * 50 / 100))
  [[ "$target_bytes" -lt 65536 ]] && target_bytes=65536

  tail -c "$target_bytes" "$f" | sed -n '/^[0-9][0-9]* /,$p' >"$tmp"
  local nsz
  nsz="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
  if [[ "$nsz" -eq 0 ]] || [[ "$nsz" -gt "$max" ]]; then
    rm -f "$tmp"
    : >"$f"
    return 0
  fi
  cat "$tmp" >"$f"
  rm -f "$tmp"
}

cmd_run() {
  local disk_warn="${HUP_DISK_WARN_PCT:-85}"
  local disk_crit="${HUP_DISK_CRIT_PCT:-92}"
  local inode_warn="${HUP_INODE_WARN_PCT:-85}"
  local mem_warn_kb="${HUP_MEM_WARN_KB:-256000}"

  local root_pct inode_pct mem_kb ntp failed swap_kb level notes
  root_pct="$(root_fs_use_pct)"
  inode_pct="$(root_inode_use_pct)"
  mem_kb="$(mem_available_kb)"
  ntp="$(ntp_sync_ok)"
  failed="$(failed_units_count)"
  swap_kb="$(swap_total_kb)"

  notes=()
  level=ok

  if [[ "${root_pct:-0}" -ge "$disk_crit" ]]; then
    level=crit
    notes+=("root filesystem >= ${disk_crit}%")
  elif [[ "${root_pct:-0}" -ge "$disk_warn" ]]; then
    [[ "$level" == ok ]] && level=warn
    notes+=("root filesystem >= ${disk_warn}%")
  fi

  if [[ "${inode_pct:-0}" -ge "$inode_warn" ]]; then
    [[ "$level" == ok ]] && level=warn
    [[ "${inode_pct:-0}" -ge 95 ]] && level=crit
    notes+=("root inode usage high (${inode_pct}%)")
  fi

  if [[ "${mem_kb:-0}" -lt "$mem_warn_kb" ]]; then
    [[ "$level" == ok ]] && level=warn
    notes+=("MemAvailable low (${mem_kb} kB)")
  fi

  if [[ "$ntp" == "no" ]]; then
    [[ "$level" == ok ]] && level=warn
    notes+=("time sync not confirmed (NTPSynchronized/chrony/timesyncd)")
  fi

  if [[ "${failed:-0}" -gt 0 ]]; then
    level=crit
    notes+=("systemd failed units: ${failed}")
  fi

  if [[ "${swap_kb:-0}" -eq 0 ]]; then
    [[ "$level" == ok ]] && level=warn
    notes+=("no swap configured")
  fi

  local epoch journal_du
  epoch="$(date +%s)"
  journal_du=""
  if command -v journalctl >/dev/null 2>&1; then
    journal_du="$(journalctl --disk-usage 2>/dev/null | head -1 | tr -d '\n' || true)"
  fi

  local notes_json="[]"
  if ((${#notes[@]} > 0)); then
    notes_json="["
    local i first=1
    for i in "${notes[@]}"; do
      [[ $first -eq 1 ]] || notes_json+=","
      first=0
      notes_json+="\"$(json_escape "$i")\""
    done
    notes_json+="]"
  fi

  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local line
  line="${epoch} {\"ts\":\"${ts}\",\"level\":\"${level}\",\"root_fs_pct\":${root_pct},\"inode_pct\":${inode_pct},\"mem_avail_kb\":${mem_kb},\"ntp\":\"${ntp}\",\"failed_units\":${failed},\"swap_total_kb\":${swap_kb},\"journal_disk\":\"$(json_escape "${journal_du:-}")\",\"notes\":${notes_json}}"

  mkdir -p "$LOG_DIR" 2>/dev/null || true
  if [[ -w "$LOG_DIR" ]] || [[ "${EUID:-0}" -eq 0 ]]; then
    [[ -f "$RUN_LOG" ]] || : >"$RUN_LOG"
    trim_run_log_if_needed
    echo "$line" >>"$RUN_LOG"
  else
    echo "$line"
    exit 0
  fi
}

timer_enabled_active() {
  if systemctl is-enabled "${UNIT_BASENAME}.timer" &>/dev/null; then
    echo enabled
  else
    echo disabled
  fi
  if systemctl is-active "${UNIT_BASENAME}.timer" &>/dev/null; then
    echo active
  else
    echo inactive
  fi
}

cmd_status() {
  echo "== ${UNIT_BASENAME} =="
  if [[ -f "$TIMER_PATH" ]]; then
    echo "Units installed: yes ($TIMER_PATH)"
  else
    echo "Units installed: no (run: sudo $SCRIPT_REALPATH init)"
  fi

  local en ac
  readarray -t _ta < <(timer_enabled_active)
  en="${_ta[0]:-unknown}"
  ac="${_ta[1]:-unknown}"
  echo "Timer enabled: $en"
  echo "Timer active:  $ac"

  if [[ -f "$RUN_LOG" ]]; then
    local last epoch_now delta
    last="$(tail -1 "$RUN_LOG" 2>/dev/null || true)"
    if [[ -n "$last" ]]; then
      local lepoch
      lepoch="${last%% *}"
      epoch_now="$(date +%s)"
      delta=$((epoch_now - lepoch))
      echo "Last run log entry: ${delta}s ago ($(date -u -d "@$lepoch" 2>/dev/null || date -u -r "$lepoch" 2>/dev/null || echo "@$lepoch"))"
      echo "Last summary: ${last#* }"
    else
      echo "Last run log: (empty)"
    fi
  else
    echo "Run log missing: $RUN_LOG (init not run or no checks yet)"
  fi

  echo ""
  echo "== Quick host signals =="
  echo "Root FS use:     $(root_fs_use_pct)%"
  echo "Root inode use:  $(root_inode_use_pct)%"
  echo "MemAvailable:    $(mem_available_kb) kB"
  echo "NTP-ish status:  $(ntp_sync_ok)"
  echo "Failed units:    $(failed_units_count)"
  echo "SwapTotal:       $(swap_total_kb) kB"
  if command -v journalctl >/dev/null 2>&1; then
    echo "Journal disk:    $(journalctl --disk-usage 2>/dev/null | head -1 || echo n/a)"
  fi
}

report_cutoff_epoch() {
  echo $(($(date +%s) - 86400))
}

cmd_report() {
  local cutoff
  cutoff="$(report_cutoff_epoch)"
  if [[ ! -f "$RUN_LOG" ]]; then
    echo "No run log at $RUN_LOG"
    exit 0
  fi

  local tmp
  tmp="$(mktemp)"
  awk -v c="$cutoff" '$1 >= c {print}' "$RUN_LOG" >"$tmp"

  local n
  n="$(wc -l <"$tmp" | tr -d ' ')"
  echo "Entries in last 24h: $n"
  if [[ "$n" -eq 0 ]]; then
    rm -f "$tmp"
    exit 0
  fi

  local okc wac cric
  okc="$(grep -c '"level":"ok"' "$tmp" || true)"
  wac="$(grep -c '"level":"warn"' "$tmp" || true)"
  cric="$(grep -c '"level":"crit"' "$tmp" || true)"
  echo "  ok:   $okc"
  echo "  warn: $wac"
  echo "  crit: $cric"
  echo ""
  echo "Non-ok lines:"
  grep -E '"level":"(warn|crit)"' "$tmp" || echo "  (none)"
  echo ""
  echo "Last 10 lines (chronological):"
  tail -10 "$tmp"
  rm -f "$tmp"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    init) cmd_init ;;
    enable-permanent) cmd_enable_permanent ;;
    status) cmd_status ;;
    report) cmd_report ;;
    run) cmd_run ;;
    -h|--help|help) usage ;;
    "")
      usage
      exit 1
      ;;
    *)
      printf 'Unknown command: %q\n\n' "$cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
