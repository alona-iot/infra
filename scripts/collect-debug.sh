#!/usr/bin/env bash
set -euo pipefail

# Collect an offline debug bundle for Alona Infra (mosquitto + core).
#
# Output:
#   /var/lib/alona/debug-bundles/alona-debug-<host>-<timestamp>.tar.gz
#
# Features:
# - --since filter for journald logs
# - Sanity checks: disk, permissions, DB lock hints, core health (optional)
# - Includes mosquitto persistence DB file IF PRESENT (safe-ish; no passwords, but can include topic payloads)
# - Redacts secrets from /etc/alona/core.env
# - NEVER includes /etc/mosquitto/passwd

BUNDLE_ROOT="/var/lib/alona/debug-bundles"
TS="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
WORKDIR="$(mktemp -d "/tmp/alona-debug.XXXXXX")"
OUT_TAR="${BUNDLE_ROOT}/alona-debug-${HOST}-${TS}.tar.gz"

SINCE="3 hours ago"
INCLUDE_MOSQ_PERSIST=0
HEALTH_URL="http://127.0.0.1:4000/health"
MAX_JOURNAL_LINES=600

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage:
  sudo ./scripts/collect-debug.sh [options]

Options:
  --since "<time>"           journald since time (default: "3 hours ago")
                             Examples: "2 hours ago", "yesterday", "2026-01-06 10:00"
  --include-mosq-persist     include mosquitto persistence DB if present (default: off)
                             Note: may contain retained payloads / queued msgs, but no passwords.
  --health-url <url>         core health endpoint to query (default: http://127.0.0.1:4000/health)
  --max-journal-lines <n>    cap journald output lines per unit (default: 600)
  -h, --help                 show help

Safety:
  - DOES NOT include /etc/mosquitto/passwd
  - Redacts secrets from /etc/alona/core.env
USAGE
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo) so we can read system logs/configs." >&2
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) SINCE="${2:-}"; shift 2;;
      --include-mosq-persist) INCLUDE_MOSQ_PERSIST=1; shift 1;;
      --health-url) HEALTH_URL="${2:-}"; shift 2;;
      --max-journal-lines) MAX_JOURNAL_LINES="${2:-}"; shift 2;;
      -h|--help) usage; exit 0;;
      *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 1;;
    esac
  done

  if [[ -z "$SINCE" ]]; then
    echo "ERROR: --since cannot be empty" >&2
    exit 1
  fi
}

mkdirs() {
  install -d -m 0755 "$BUNDLE_ROOT"
  install -d -m 0755 "$WORKDIR"
}

write_file() {
  local rel="$1"; shift
  local path="$WORKDIR/$rel"
  install -d -m 0755 "$(dirname "$path")"
  # shellcheck disable=SC2068
  "$@" >"$path" 2>&1 || true
}

copy_file_if_exists() {
  local src="$1"
  local rel="$2"
  if [[ -f "$src" ]]; then
    install -d -m 0755 "$(dirname "$WORKDIR/$rel")"
    cp -a "$src" "$WORKDIR/$rel"
  fi
}

copy_dir_if_exists() {
  local src="$1"
  local rel="$2"
  if [[ -d "$src" ]]; then
    install -d -m 0755 "$(dirname "$WORKDIR/$rel")"
    cp -a "$src" "$WORKDIR/$rel"
  fi
}

redact_env_file() {
  local src="$1"
  local rel="$2"
  [[ -f "$src" ]] || return 0
  install -d -m 0755 "$(dirname "$WORKDIR/$rel")"

  # Redact common secret-ish keys. Keep variable names for context.
  sed -E \
    -e 's/^(SECRET_KEY_BASE)=.*/\1=REDACTED/' \
    -e 's/^(MQTT_PASSWORD)=.*/\1=REDACTED/' \
    -e 's/^(DATABASE_URL)=.*/\1=REDACTED/' \
    -e 's/^(ERLANG_COOKIE)=.*/\1=REDACTED/' \
    -e 's/^(.*TOKEN.*)=.*/\1=REDACTED/' \
    -e 's/^(.*PASSWORD.*)=.*/\1=REDACTED/' \
    "$src" > "$WORKDIR/$rel"
}

journal_tail() {
  local unit="$1"
  local rel="$2"
  # Use --since and cap output
  write_file "$rel" bash -lc \
    "journalctl -u '$unit' --since '$SINCE' --no-pager | tail -n '$MAX_JOURNAL_LINES'"
}

collect_system_info() {
  write_file "system/uname.txt" uname -a
  write_file "system/os-release.txt" cat /etc/os-release
  write_file "system/date.txt" date -Iseconds
  write_file "system/uptime.txt" uptime
  write_file "system/last-boot.txt" who -b

  write_file "system/df.txt" df -h
  write_file "system/df_inodes.txt" df -ih
  write_file "system/lsblk.txt" lsblk -a
  write_file "system/mount.txt" mount
  write_file "system/free.txt" free -h

  write_file "system/ps_top_mem.txt" bash -lc "ps aux --sort=-%mem | head -n 60"
  write_file "system/ps_top_cpu.txt" bash -lc "ps aux --sort=-%cpu | head -n 60"

  write_file "system/dmesg_tail.txt" bash -lc "dmesg -T | tail -n 250"
}

collect_network_info() {
  write_file "network/ip_addr.txt" ip addr
  write_file "network/ip_route.txt" ip route
  write_file "network/resolv.conf.txt" cat /etc/resolv.conf
  write_file "network/listeners.txt" bash -lc "ss -lntup || true"
}

collect_services_info() {
  write_file "services/systemctl_status_mosquitto.txt" systemctl --no-pager --full status mosquitto
  write_file "services/systemctl_status_core.txt" systemctl --no-pager --full status core

  write_file "services/is_enabled.txt" bash -lc "systemctl is-enabled mosquitto core 2>&1 || true"
  write_file "services/is_active.txt"  bash -lc "systemctl is-active mosquitto core 2>&1 || true"

  copy_file_if_exists "/etc/systemd/system/core.service" "services/core.service"
  copy_dir_if_exists  "/etc/systemd/system/core.service.d" "services/core.service.d"
}

collect_logs() {
  # Unit logs since SINCE
  journal_tail "mosquitto" "logs/journal_mosquitto_since.txt"
  journal_tail "core"      "logs/journal_core_since.txt"

  # Errors since SINCE
  write_file "logs/journal_errors_since.txt" bash -lc \
    "journalctl -p err --since '$SINCE' --no-pager | tail -n '$MAX_JOURNAL_LINES'"

  # Boot journal summary (handy after power loss)
  write_file "logs/journal_boot_summary.txt" bash -lc \
    "journalctl -b --no-pager | tail -n 300"
}

collect_configs() {
  copy_file_if_exists "/etc/mosquitto/mosquitto.conf" "config/mosquitto/mosquitto.conf"
  copy_file_if_exists "/etc/mosquitto/acl"            "config/mosquitto/acl"

  # DO NOT include passwd file
  write_file "config/mosquitto/passwd_note.txt" bash -lc \
    "echo 'NOT INCLUDED: /etc/mosquitto/passwd (contains password hashes)'; ls -l /etc/mosquitto/passwd 2>/dev/null || true"

  redact_env_file "/etc/alona/core.env" "config/alona/core.env.redacted"

  write_file "config/alona/etc_alona_ls.txt" bash -lc "ls -la /etc/alona || true"
}

collect_runtime_layout() {
  write_file "runtime/opt_core.txt" bash -lc \
    "ls -la /opt/core; echo; echo 'current ->'; readlink -f /opt/core/current 2>/dev/null || true; echo; echo 'previous ->'; readlink -f /opt/core/previous 2>/dev/null || true"

  write_file "runtime/var_lib_alona.txt" bash -lc \
    "ls -la /var/lib/alona; echo; ls -la /var/lib/alona/db 2>/dev/null || true; echo; ls -la /var/lib/alona/backups 2>/dev/null || true"

  write_file "runtime/db_stat.txt" bash -lc "stat /var/lib/alona/db/alona.sqlite3 2>/dev/null || true"

  # WAL/SHM presence hints
  write_file "runtime/db_aux_files.txt" bash -lc \
    "ls -la /var/lib/alona/db 2>/dev/null | grep -E 'sqlite3-(wal|shm)$|\\.wal$|\\.shm$' || true"
}

sanity_checks() {
  # Disk threshold hints
  write_file "sanity/disk_thresholds.txt" bash -lc '
set -e
echo "Disk usage (human):"
df -h / /var/lib/alona 2>/dev/null || df -h /
echo
echo "Disk usage (percent):"
df -P / /var/lib/alona 2>/dev/null || df -P /
echo
echo "If usage > 85%, expect issues (DB locks, crashes, failed backups)."
'

  # Permissions check
  write_file "sanity/permissions.txt" bash -lc '
set -e
echo "/var/lib/alona ownership:"
ls -ld /var/lib/alona /var/lib/alona/db /var/lib/alona/backups 2>/dev/null || true
echo
echo "DB file ownership:"
ls -l /var/lib/alona/db/alona.sqlite3 2>/dev/null || true
'

  # DB lock hints (best-effort)
  write_file "sanity/db_lock_hints.txt" bash -lc '
set -e
DB="/var/lib/alona/db/alona.sqlite3"
if [[ -f "$DB" ]]; then
  echo "DB exists: $DB"
  echo
  echo "Open file handles to DB (lsof):"
  if command -v lsof >/dev/null 2>&1; then
    lsof "$DB" || true
  else
    echo "lsof not installed."
  fi
  echo
  echo "Potential locks (fuser):"
  if command -v fuser >/dev/null 2>&1; then
    fuser -v "$DB" || true
  else
    echo "fuser not installed."
  fi
else
  echo "DB missing: $DB"
fi
'

  # Core health check (optional)
  write_file "sanity/core_health.txt" bash -lc "
set -e
echo 'Health URL: $HEALTH_URL'
if command -v curl >/dev/null 2>&1; then
  curl -sS -m 3 '$HEALTH_URL' || true
else
  echo 'curl not installed.'
fi
"
}

collect_mqtt_snapshot() {
  write_file "mqtt/listeners.txt" bash -lc "ss -lntup | grep -E ':(1883|8883)' || true"
  write_file "mqtt/note.txt" bash -lc "echo 'Auth-protected MQTT. For deeper tests, run mosquitto_sub/pub with credentials.'"
}

collect_mosquitto_persistence_if_enabled() {
  [[ "$INCLUDE_MOSQ_PERSIST" -eq 1 ]] || return 0

  # Common locations; distro-dependent
  local candidates=(
    "/var/lib/mosquitto/mosquitto.db"
    "/var/lib/mosquitto/mosquitto.db.new"
    "/var/lib/mosquitto/mosquitto.db~"
  )

  local found=0
  for p in "${candidates[@]}"; do
    if [[ -f "$p" ]]; then
      found=1
      copy_file_if_exists "$p" "mosquitto-persist/$(basename "$p")"
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    write_file "mosquitto-persist/note.txt" bash -lc \
      "echo 'No mosquitto persistence DB found in common locations. Check persistence_location in mosquitto.conf.'"
  else
    write_file "mosquitto-persist/note.txt" bash -lc \
      "echo 'Included mosquitto persistence DB file(s). Note: may contain retained payloads / queued messages (no passwords).'"
  fi
}

package_bundle() {
  echo "==> Creating debug bundle: $OUT_TAR"
  tar -czf "$OUT_TAR" -C "$WORKDIR" .
  chmod 0644 "$OUT_TAR"
  echo "==> Bundle ready: $OUT_TAR"
}

main() {
  need_root
  parse_args "$@"
  mkdirs

  echo "==> Collecting system info..."
  collect_system_info

  echo "==> Collecting network info..."
  collect_network_info

  echo "==> Collecting service info..."
  collect_services_info

  echo "==> Collecting logs (since: $SINCE)..."
  collect_logs

  echo "==> Collecting configs (with redaction)..."
  collect_configs

  echo "==> Collecting runtime layout..."
  collect_runtime_layout

  echo "==> Running sanity checks..."
  sanity_checks

  echo "==> Collecting MQTT snapshot..."
  collect_mqtt_snapshot

  echo "==> Collecting mosquitto persistence (optional)..."
  collect_mosquitto_persistence_if_enabled

  package_bundle
}

main "$@"
