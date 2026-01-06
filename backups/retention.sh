#!/usr/bin/env bash
set -euo pipefail

# Retention policy for backups in /var/lib/alona/backups
# Default: keep last 14 backups (simple & safe).
# You can upgrade later to daily/weekly tiers if needed.

BACKUP_DIR="/var/lib/alona/backups"
KEEP="${KEEP:-14}"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: run as root (sudo)." >&2
    exit 1
  fi
}

main() {
  need_root

  if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "Backup dir missing: $BACKUP_DIR"
    exit 0
  fi

  mapfile -t files < <(ls -1t "$BACKUP_DIR"/core-backup-*.tar.gz 2>/dev/null || true)
  local count="${#files[@]}"

  if [[ "$count" -le "$KEEP" ]]; then
    echo "OK: $count backups <= KEEP=$KEEP, nothing to delete."
    exit 0
  fi

  echo "Retention: keeping $KEEP of $count backups. Deleting $((count-KEEP)) old backups..."
  for f in "${files[@]:$KEEP}"; do
    rm -f "$f"
    echo "deleted: $f"
  done
}

main "$@"
