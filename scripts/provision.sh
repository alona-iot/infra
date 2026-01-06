
---

## `scripts/provision.sh`

> Usage: `sudo ./scripts/provision.sh --hostname alona-pi`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Provision Raspberry Pi OS baseline for Alona
# - packages
# - timezone
# - journald persistence + size limits
# - optional hostname
# - basic directories used by infra

usage() {
  cat <<'USAGE'
Usage:
  sudo ./scripts/provision.sh [--hostname <name>] [--timezone Europe/Athens] [--journald-max 200M]

Options:
  --hostname <name>         Set system hostname (optional)
  --timezone <tz>           Timezone (default: Europe/Athens)
  --journald-max <size>     journald persistent max size (default: 200M)
  -h, --help                Show help

Notes:
- This script is safe to re-run (idempotent-ish).
- It does not configure Wi-Fi or static IP.
USAGE
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Run as root (sudo)." >&2
    exit 1
  fi
}

HOSTNAME=""
TIMEZONE="Europe/Athens"
JOURNALD_MAX="200M"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hostname) HOSTNAME="${2:-}"; shift 2;;
      --timezone) TIMEZONE="${2:-}"; shift 2;;
      --journald-max) JOURNALD_MAX="${2:-}"; shift 2;;
      -h|--help) usage; exit 0;;
      *) echo "Unknown arg: $1" >&2; usage; exit 1;;
    esac
  done
}

install_packages() {
  echo "==> Updating packages..."
  apt-get update -y
  apt-get full-upgrade -y

  echo "==> Installing baseline tools..."
  apt-get install -y \
    git curl ca-certificates \
    tmux vim \
    htop \
    jq \
    lsof \
    rsync
}

set_timezone() {
  echo "==> Setting timezone: $TIMEZONE"
  timedatectl set-timezone "$TIMEZONE"
}

set_hostname() {
  if [[ -z "$HOSTNAME" ]]; then
    echo "==> Hostname unchanged."
    return 0
  fi

  echo "==> Setting hostname: $HOSTNAME"
  hostnamectl set-hostname "$HOSTNAME"
  # /etc/hosts update (best-effort)
  if grep -qE '127\.0\.1\.1' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1\s+.*/127.0.1.1\t$HOSTNAME/" /etc/hosts || true
  else
    echo -e "127.0.1.1\t$HOSTNAME" >> /etc/hosts
  fi
}

enable_journald_persistent() {
  echo "==> Enabling persistent journald logs..."
  mkdir -p /var/log/journal
  systemctl restart systemd-journald

  echo "==> Configuring journald size limit: $JOURNALD_MAX"
  local conf="/etc/systemd/journald.conf"
  if [[ ! -f "$conf" ]]; then
    touch "$conf"
  fi

  # Set or replace SystemMaxUse=
  if grep -q '^SystemMaxUse=' "$conf"; then
    sed -i "s/^SystemMaxUse=.*/SystemMaxUse=$JOURNALD_MAX/" "$conf"
  else
    echo "SystemMaxUse=$JOURNALD_MAX" >> "$conf"
  fi

  # Keep runtime logs bounded too
  if grep -q '^RuntimeMaxUse=' "$conf"; then
    sed -i "s/^RuntimeMaxUse=.*/RuntimeMaxUse=100M/" "$conf"
  else
    echo "RuntimeMaxUse=100M" >> "$conf"
  fi

  systemctl restart systemd-journald
}

create_base_dirs() {
  echo "==> Creating base directories..."
  mkdir -p /etc/alona /var/lib/alona
  chmod 0755 /etc/alona /var/lib/alona
}

final_notes() {
  echo
  echo "==> Provisioning complete."
  echo "Next:"
  echo "  - Reboot recommended after full-upgrade:"
  echo "      sudo reboot"
  echo "  - Then run infra install from repo root:"
  echo "      sudo ./scripts/install.sh --pi-ip <PI_LAN_IP> --nodes node-001,node-002"
}

main() {
  need_root
  parse_args "$@"
  install_packages
  set_timezone
  set_hostname
  enable_journald_persistent
  create_base_dirs
  final_notes
}

main "$@"
