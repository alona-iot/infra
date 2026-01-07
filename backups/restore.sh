#!/usr/bin/env bash
set -euo pipefail

# Restore a backup bundle created by backups/backup.sh
#
# Usage:
#   sudo ./backups/restore.sh --from /var/lib/alona/backups/core-backup-<...>.tar.gz
#
# What it does:
# - stops alona-core.service
# - restores /etc/alona (overwrites; keeps a timestamped backup)
# - restores SQLite DB into /var/lib/alona/db/alona.sqlite3
# - restarts alona-core.service

DB_DIR="/var/lib/alona/db"
DB_FILE="${DB_DIR}/alona.sqlite3"
ETC_ALONA="/etc/alona"

usage() {
  cat <<'USAGE'
Usage:
  sudo ./backups/restore.sh --from <backup.tar.gz> [--no-restart]

Options:
  --from <file>     path to backup tar.gz
  --no-restart      do not restart core after restore
USAGE
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: run as root (sudo)." >&2
    exit 1
  fi
}

main() {
  need_root

  local src=""
  local restart=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) src="${2:-}"; shift 2;;
      --no-restart) restart=0; shift 1;;
      -h|--help) usage; exit 0;;
      *) echo "Unknown arg: $1" >&2; usage; exit 1;;
    esac
  done

  [[ -n "$src" ]] || { echo "ERROR: --from is required" >&2; usage; exit 1; }
  [[ -f "$src" ]] || { echo "ERROR: backup not found: $src" >&2; exit 1; }

  echo "==> Stopping alona-core.service"
  systemctl stop alona-core || true

  local tmp
  tmp="$(mktemp -d /tmp/alona-restore.XXXXXX)"
  trap 'rm -rf "$tmp"' EXIT

  echo "==> Extracting backup: $src"
  tar -xzf "$src" -C "$tmp"

  # Backup existing /etc/alona
  if [[ -d "$ETC_ALONA" ]]; then
    local etc_bak="/etc/alona.bak.$(date +%Y%m%d-%H%M%S)"
    echo "==> Backing up existing /etc/alona -> $etc_bak"
    cp -a "$ETC_ALONA" "$etc_bak"
  fi

  # Restore /etc/alona
  if [[ -d "$tmp/etc/alona" ]]; then
    echo "==> Restoring /etc/alona"
    rm -rf "$ETC_ALONA"
    cp -a "$tmp/etc/alona" "$ETC_ALONA"
    chown -R root:root "$ETC_ALONA"
    chmod 0755 "$ETC_ALONA"
    # keep env locked down if present
    [[ -f "$ETC_ALONA/core.env" ]] && chmod 0600 "$ETC_ALONA/core.env" || true
  else
    echo "WARN: backup does not contain etc/alona (skipping)." >&2
  fi

  # Restore DB
  install -d -m 0755 "$DB_DIR"
  if [[ -f "$tmp/db/alona.sqlite3" ]]; then
    echo "==> Restoring DB -> $DB_FILE"
    cp -a "$tmp/db/alona.sqlite3" "$DB_FILE"
    # Best-effort restore WAL/SHM if included
    [[ -f "$tmp/db/alona.sqlite3-wal" ]] && cp -a "$tmp/db/alona.sqlite3-wal" "${DB_FILE}-wal" || true
    [[ -f "$tmp/db/alona.sqlite3-shm" ]] && cp -a "$tmp/db/alona.sqlite3-shm" "${DB_FILE}-shm" || true

    chown -R alona:alona "$DB_DIR"
  else
    echo "WARN: backup does not contain db/alona.sqlite3 (skipping DB restore)." >&2
  fi

  if [[ "$restart" -eq 1 ]]; then
    echo "==> Starting alona-core.service"
    systemctl start alona-core || true
    systemctl --no-pager --full status alona-core || true
    journalctl -u alona-core -n 80 --no-pager || true
  else
    echo "==> Restore complete (alona-core not restarted due to --no-restart)."
  fi
}

main "$@"
