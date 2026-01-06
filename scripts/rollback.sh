#!/usr/bin/env bash
set -euo pipefail

# Roll back core.service to /opt/core/previous (if present).
#
# Example:
#   sudo ./scripts/rollback.sh

usage() {
  cat <<'USAGE'
Usage:
  sudo ./scripts/rollback.sh [--no-restart]

Rolls back:
  /opt/core/current -> /opt/core/previous

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

  if [[ ! -L /opt/core/previous ]]; then
    echo "ERROR: /opt/core/previous symlink not found. Nothing to roll back to." >&2
    exit 1
  fi

  local prev
  prev="$(readlink -f /opt/core/previous)"

  if [[ ! -d "$prev" ]]; then
    echo "ERROR: previous target does not exist: $prev" >&2
    exit 1
  fi

  echo "==> Rolling back: /opt/core/current -> $prev"
  ln -sfn "$prev" /opt/core/current

  if [[ "$RESTART" -eq 1 ]]; then
    echo "==> Restarting core.service"
    systemctl restart core
    systemctl --no-pager --full status core || true
    journalctl -u core -n 100 --no-pager || true
  else
    echo "==> Skipping restart (--no-restart)."
  fi

  echo "==> Rollback complete."
}

main "$@"
