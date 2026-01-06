#!/usr/bin/env bash
set -euo pipefail

# Alona Infra - lightweight healthcheck
#
# Checks:
# - systemd services: mosquitto, core
# - disk free threshold
# - last successful backup age
# - optional: core health endpoint
#
# Output:
# - exits 0 if healthy, non-zero if unhealthy
# - writes a short status line to stdout for journald
# - updates /var/lib/alona/health/last_ok or last_fail

DISK_PATH="/var/lib/alona"
DISK_MAX_USED_PCT="${DISK_MAX_USED_PCT:-85}"          # fail if used% > this
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-48}"    # fail if last backup older than this
HEALTH_DIR="/var/lib/alona/health"
LAST_OK_FILE="$HEALTH_DIR/last_ok"
LAST_FAIL_FILE="$HEALTH_DIR/last_fail"
BACKUP_MARKER="/var/lib/alona/backups/LAST_SUCCESSFUL_ISO"

CORE_HEALTH_URL="${CORE_HEALTH_URL:-http://127.0.0.1:4000/health}"
CHECK_CORE_HTTP="${CHECK_CORE_HTTP:-0}"               # set to 1 to enable HTTP check
HTTP_TIMEOUT_SECS="${HTTP_TIMEOUT_SECS:-2}"

now_iso() { date -Iseconds; }

service_active() {
  local s="$1"
  systemctl is-active --quiet "$s"
}

disk_used_pct() {
  # returns integer percent used (without %), for DISK_PATH
  df -P "$DISK_PATH" | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

backup_age_hours() {
  # returns age in hours since LAST_SUCCESSFUL_ISO, or large number if missing/unparseable
  if [[ ! -f "$BACKUP_MARKER" ]]; then
    echo 999999
    return 0
  fi

  local iso
  iso="$(head -n1 "$BACKUP_MARKER" | tr -d '\r\n')"
  if [[ -z "$iso" ]]; then
    echo 999999
    return 0
  fi

  # Convert ISO to epoch (best-effort)
  local last_epoch
  if last_epoch="$(date -d "$iso" +%s 2>/dev/null)"; then
    :
  else
    echo 999999
    return 0
  fi

  local now_epoch
  now_epoch="$(date +%s)"
  local diff=$(( now_epoch - last_epoch ))
  if (( diff < 0 )); then diff=0; fi
  echo $(( diff / 3600 ))
}

check_core_http() {
  # best-effort; returns 0 if HTTP 2xx/3xx, else non-zero
  command -v curl >/dev/null 2>&1 || return 2
  curl -sS -m "$HTTP_TIMEOUT_SECS" -o /dev/null -w "%{http_code}" "$CORE_HEALTH_URL" | awk '
    { code=$1; exit !(code >= 200 && code < 400) }
  '
}

mark_ok() {
  install -d -m 0755 "$HEALTH_DIR"
  echo "$(now_iso) OK $*" > "$LAST_OK_FILE"
}

mark_fail() {
  install -d -m 0755 "$HEALTH_DIR"
  echo "$(now_iso) FAIL $*" > "$LAST_FAIL_FILE"
}

main() {
  local errors=()

  if service_active mosquitto; then
    :
  else
    errors+=("mosquitto=down")
  fi

  if service_active core; then
    :
  else
    errors+=("core=down")
  fi

  local used
  used="$(disk_used_pct 2>/dev/null || echo 999)"
  if [[ "$used" =~ ^[0-9]+$ ]]; then
    if (( used > DISK_MAX_USED_PCT )); then
      errors+=("disk_used=${used}%>$(printf "%s%%" "$DISK_MAX_USED_PCT")")
    fi
  else
    errors+=("disk_used=unknown")
  fi

  local age_h
  age_h="$(backup_age_hours)"
  if (( age_h > BACKUP_MAX_AGE_HOURS )); then
    errors+=("backup_age=${age_h}h>${BACKUP_MAX_AGE_HOURS}h")
  fi

  if [[ "$CHECK_CORE_HTTP" == "1" ]]; then
    if check_core_http; then
      :
    else
      errors+=("core_http=bad")
    fi
  fi

  if (( ${#errors[@]} == 0 )); then
    mark_ok "mosquitto=up core=up disk_used=${used}% backup_age=${age_h}h"
    echo "OK mosquitto=up core=up disk_used=${used}% backup_age=${age_h}h"
    exit 0
  else
    mark_fail "${errors[*]}"
    echo "FAIL ${errors[*]}"
    exit 1
  fi
}

main "$@"
