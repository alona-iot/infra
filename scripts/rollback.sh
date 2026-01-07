#!/usr/bin/env bash
set -euo pipefail

# Roll back alona-core.service to /opt/alona-core/previous (if present).
#
# Example:
#   sudo ./scripts/rollback.sh

usage() {
  cat <<'USAGE'
Usage:
  sudo ./scripts/rollback.sh [--no-restart]

Rolls back:
  /opt/alona-core/current -> /opt/alona-core/previous

USAGE
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

parse_args() {
  RESTART=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-restart) RESTART=0; shift 1;;
      -h|--help) usage; exit 0;;
      *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 1;;
    esac
  done
}

main() {
  need_root
  parse_args "$@"

  if [[ ! -L /opt/alona-core/previous ]]; then
    echo "ERROR: /opt/alona-core/previous symlink not found. Nothing to roll back to." >&2
    exit 1
  fi

  local prev
  prev="$(readlink -f /opt/alona-core/previous)"

  if [[ ! -d "$prev" ]]; then
    echo "ERROR: previous target does not exist: $prev" >&2
    exit 1
  fi

  echo "==> Rolling back: /opt/alona-core/current -> $prev"
  ln -sfn "$prev" /opt/alona-core/current

  if [[ "$RESTART" -eq 1 ]]; then
    echo "==> Restarting alona-core.service"
    systemctl restart alona-core
    systemctl --no-pager --full status alona-core || true
    journalctl -u alona-core -n 100 --no-pager || true
  else
    echo "==> Skipping restart (--no-restart)."
  fi

  echo "==> Rollback complete."
}

main "$@"
