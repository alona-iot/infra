#!/usr/bin/env bash
set -euo pipefail

# Deploy a Core release tarball to the Pi (versioned) and switch /opt/alona-core/current.
#
# Example:
#   sudo ./scripts/deploy.sh --tar /tmp/core-0.1.0.tar.gz --version 0.1.0
#
# Notes:
# - Keeps the previous 'current' target as "previous" symlink for rollback convenience.
# - Does NOT delete old releases (use a cleanup script later).
# - Validates that bin/core exists after extraction.

usage() {
  cat <<'USAGE'
Usage:
  sudo ./scripts/deploy.sh --tar <path-to-tarball> --version <version> [--no-restart]

Options:
  --tar <path>        Path to release tarball (.tar.gz or .tgz)
  --version <ver>     Release version label (e.g. 0.1.0, 2026-01-06_1)
  --no-restart        Do not restart alona-core.service (just install & switch symlink)
  -h, --help          Show help

Deploy layout:
  /opt/alona-core/releases/<version>/
  /opt/alona-core/current  -> /opt/alona-core/releases/<version>
  /opt/alona-core/previous -> previous target (if any)
USAGE
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

parse_args() {
  TARBALL=""
  VERSION=""
  RESTART=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tar)
        TARBALL="${2:-}"; shift 2;;
      --version)
        VERSION="${2:-}"; shift 2;;
      --no-restart)
        RESTART=0; shift 1;;
      -h|--help)
        usage; exit 0;;
      *)
        echo "ERROR: Unknown argument: $1" >&2
        usage
        exit 1;;
    esac
  done

  if [[ -z "$TARBALL" || -z "$VERSION" ]]; then
    echo "ERROR: --tar and --version are required." >&2
    usage
    exit 1
  fi

  if [[ ! -f "$TARBALL" ]]; then
    echo "ERROR: Tarball not found: $TARBALL" >&2
    exit 1
  fi
}

safe_mkdirs() {
  install -d -m 0755 /opt/alona-core
  install -d -m 0755 /opt/alona-core/releases
  chown -R root:root /opt/alona-core
}

extract_release() {
  local dest="/opt/alona-core/releases/$VERSION"

  if [[ -e "$dest" ]]; then
    echo "ERROR: Destination already exists: $dest" >&2
    echo "Refusing to overwrite. Use a new --version or remove it manually." >&2
    exit 1
  fi

  install -d -m 0755 "$dest"

  echo "==> Extracting $TARBALL -> $dest"
  tar -xzf "$TARBALL" -C "$dest"

  # Some tarballs include a top-level folder. If so, detect and flatten.
  if [[ ! -x "$dest/bin/core" ]]; then
    local top
    top="$(find "$dest" -maxdepth 2 -type f -path "*/bin/core" | head -n1 || true)"
    if [[ -n "$top" ]]; then
      local topdir
      topdir="$(dirname "$(dirname "$top")")"
      echo "==> Detected nested release directory: $topdir"
      echo "==> Flattening into $dest"
      shopt -s dotglob
      mv "$topdir"/* "$dest"/
      shopt -u dotglob
    fi
  fi

  if [[ ! -x "$dest/bin/core" ]]; then
    echo "ERROR: Release validation failed: $dest/bin/core not found/executable." >&2
    echo "Check your release packaging." >&2
    exit 1
  fi

  # Ownership: keep binaries root-owned, runtime writes go to /var/lib/alona
  chown -R root:root "$dest"
  chmod -R a-w "$dest" || true
  chmod +x "$dest/bin/core" || true

  echo "==> Release extracted and validated."
}

switch_symlink() {
  local new="/opt/alona-core/releases/$VERSION"
  local current="/opt/alona-core/current"
  local previous="/opt/alona-core/previous"

  echo "==> Switching symlink: $current -> $new"

  if [[ -L "$current" ]]; then
    local old
    old="$(readlink -f "$current" || true)"
    if [[ -n "$old" ]]; then
      ln -sfn "$old" "$previous"
      echo "==> Saved previous -> $old"
    fi
  fi

  ln -sfn "$new" "$current"
  echo "==> Current now points to: $(readlink -f "$current")"
}

restart_core() {
  if [[ "$RESTART" -eq 0 ]]; then
    echo "==> Skipping restart (--no-restart)."
    return 0
  fi

  echo "==> Restarting alona-core.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart alona-core

  echo "==> alona-core.service status:"
  systemctl --no-pager --full status alona-core || true

  echo "==> alona-core.service log tail:"
  journalctl -u alona-core -n 100 --no-pager || true
}

main() {
  need_root
  parse_args "$@"
  safe_mkdirs
  extract_release
  switch_symlink
  restart_core

  echo
  echo "==> Deploy complete: version=$VERSION"
}

main "$@"
