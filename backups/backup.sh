#!/usr/bin/env bash
set -euo pipefail

# Alona Core backup (SQLite + /etc/alona)
# Output: /var/lib/alona/backups/core-backup-<host>-<timestamp>.tar.gz
#
# Includes:
# - /etc/alona (configs/secrets)
# - SQLite DB file + WAL/SHM if present
# - manifest with basic metadata
#
# Notes:
# - We do NOT stop the core service. SQLite in WAL mode can be safely backed up
#   by copying DB + WAL + SHM together (best-effort). If you later want stronger
#   guarantees, you can implement an app-level "backup checkpoint" endpoint.

BACKUP_DIR="/var/lib/alona/backups"
DB_DIR="/var/lib/alona/db"
DB_FILE="${DB_DIR}/alona.sqlite3"
ETC_ALONA="/etc/alona"

HOST="$(hostname -s 2>/dev/null || hostname)"
TS="$(date +%Y%m%d-%H%M%S)"
TMPDIR="$(mktemp -d "/tmp/alona-backup.XXXXXX")"
ARCHIVE="${BACKUP_DIR}/core-backup-${HOST}-${TS}.tar.gz"

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: run as root (sudo) so we can read /etc/alona and DB." >&2
    exit 1
  fi
}

mkdirs() {
  install -d -m 0755 "$BACKUP_DIR"
  chmod 0755 "$BACKUP_DIR"
}

copy_tree() {
  local src="$1"
  local dest="$2"
  if [[ -e "$src" ]]; then
    install -d -m 0755 "$(dirname "$dest")"
    cp -a "$src" "$dest"
  fi
}

write_manifest() {
  local mf="$TMPDIR/manifest.txt"
  {
    echo "alona_backup=core"
    echo "host=$HOST"
    echo "timestamp=$TS"
    echo "date_iso=$(date -Iseconds)"
    echo
    echo "[services]"
    systemctl is-active mosquitto 2>/dev/null || true
    systemctl is-active alona-core 2>/dev/null || true
    echo
    echo "[disk]"
    df -h /var/lib/alona 2>/dev/null || df -h /
    echo
    echo "[db]"
    if [[ -f "$DB_FILE" ]]; then
      ls -la "$DB_FILE"
    else
      echo "DB missing: $DB_FILE"
    fi
    echo
    echo "[symlinks]"
    echo -n "current="; readlink -f /opt/alona-core/current 2>/dev/null || true
    echo -n "previous="; readlink -f /opt/alona-core/previous 2>/dev/null || true
  } >"$mf"
}

main() {
  need_root
  mkdirs

  # Stage files into TMPDIR
  install -d -m 0755 "$TMPDIR/etc"
  install -d -m 0755 "$TMPDIR/db"

  # /etc/alona (critical)
  if [[ -d "$ETC_ALONA" ]]; then
    copy_tree "$ETC_ALONA" "$TMPDIR/etc/alona"
  else
    echo "WARN: $ETC_ALONA does not exist (skipping)." >&2
  fi

  # DB (critical)
  if [[ -f "$DB_FILE" ]]; then
    copy_tree "$DB_FILE" "$TMPDIR/db/alona.sqlite3"
    # Include WAL/SHM if present (best-effort)
    [[ -f "${DB_FILE}-wal" ]] && copy_tree "${DB_FILE}-wal" "$TMPDIR/db/alona.sqlite3-wal"
    [[ -f "${DB_FILE}-shm" ]] && copy_tree "${DB_FILE}-shm" "$TMPDIR/db/alona.sqlite3-shm"
  else
    echo "WARN: DB file not found: $DB_FILE (continuing; backup will still include /etc/alona)." >&2
  fi

  write_manifest

  # Create archive
  tar -czf "$ARCHIVE" -C "$TMPDIR" .
  chmod 0640 "$ARCHIVE"

  # Write/update "last backup" marker
  echo "$ARCHIVE" > "${BACKUP_DIR}/LAST_SUCCESSFUL"
  date -Iseconds > "${BACKUP_DIR}/LAST_SUCCESSFUL_ISO"

  echo "OK: backup created: $ARCHIVE"
}

main "$@"
