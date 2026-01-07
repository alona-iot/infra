#!/usr/bin/env bash
set -euo pipefail

# Alona Infra - unified installer
# Components:
# - Mosquitto (MQTT broker)
# - Core systemd service scaffolding
# - Backups (SQLite + /etc/alona)
# - Monitoring (healthcheck + timer)
#
# Run from repo root:
#   sudo ./scripts/install.sh --pi-ip <LAN_IP> [--nodes node-001,node-002]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MOSQ_TEMPLATE_DIR="$REPO_ROOT/services/mosquitto"
CORE_TEMPLATE_DIR="$REPO_ROOT/services/core"
BACKUP_TEMPLATE_DIR="$REPO_ROOT/services/backup/systemd"
BACKUP_SCRIPTS_DIR="$REPO_ROOT/backups"
MONITORING_SCRIPTS_DIR="$REPO_ROOT/monitoring"
MONITORING_SYSTEMD_DIR="$REPO_ROOT/services/monitoring/systemd"

usage() {
  cat <<'USAGE'
Usage:
  sudo ./scripts/install.sh --pi-ip <LAN_IP> [options]

Required:
  --pi-ip <LAN_IP>              LAN IP of the Raspberry Pi

Options:
  --core-mqtt-user <name>       MQTT username for backend (default: alona-core)
  --nodes <csv>                 Comma-separated node MQTT usernames
  --skip-mosquitto              Skip Mosquitto install/config
  --skip-core                   Skip core service scaffolding
  --skip-backups                Skip backups install
  --skip-monitoring             Skip monitoring install
  --no-test                     Skip MQTT smoke test
  -h, --help                    Show help

Environment variables:
  CORE_MQTT_PASSWORD            Core MQTT password (non-interactive)
  NODE_MQTT_PASSWORD            Node MQTT password (non-interactive)
USAGE
}

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }
}

require_files() {
  local missing=0
  for f in     "$MOSQ_TEMPLATE_DIR/mosquitto.conf"     "$MOSQ_TEMPLATE_DIR/acl"     "$CORE_TEMPLATE_DIR/systemd/alona-core.service"     "$CORE_TEMPLATE_DIR/env/alona-core.env.example"     "$BACKUP_SCRIPTS_DIR/backup.sh"     "$BACKUP_SCRIPTS_DIR/retention.sh"     "$BACKUP_SCRIPTS_DIR/restore.sh"     "$BACKUP_TEMPLATE_DIR/alona-core-backup.service"     "$BACKUP_TEMPLATE_DIR/alona-core-backup.timer"     "$MONITORING_SCRIPTS_DIR/healthcheck.sh"     "$MONITORING_SYSTEMD_DIR/alona-health.service"     "$MONITORING_SYSTEMD_DIR/alona-health.timer"
  do
    [[ -f "$f" ]] || { echo "Missing file: $f"; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || exit 1
}

parse_args() {
  PI_IP=""
  CORE_MQTT_USER="alona-core"
  NODES_CSV=""
  INSTALL_MOSQ=1
  INSTALL_CORE=1
  INSTALL_BACKUPS=1
  INSTALL_MONITORING=1
  DO_TEST=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pi-ip) PI_IP="$2"; shift 2;;
      --core-mqtt-user) CORE_MQTT_USER="$2"; shift 2;;
      --nodes) NODES_CSV="$2"; shift 2;;
      --skip-mosquitto) INSTALL_MOSQ=0; shift;;
      --skip-core) INSTALL_CORE=0; shift;;
      --skip-backups) INSTALL_BACKUPS=0; shift;;
      --skip-monitoring) INSTALL_MONITORING=0; shift;;
      --no-test) DO_TEST=0; shift;;
      -h|--help) usage; exit 0;;
      *) echo "Unknown arg: $1"; usage; exit 1;;
    esac
  done

  [[ -n "$PI_IP" ]] || { echo "--pi-ip is required"; exit 1; }
}

install_packages() {
  apt-get update -y
  apt-get install -y mosquitto mosquitto-clients curl lsof rsync || true
}

ensure_user_dirs() {
  id alona >/dev/null 2>&1 || useradd --system --home /var/lib/alona --shell /usr/sbin/nologin alona
  mkdir -p /etc/alona /var/lib/alona/db /var/lib/alona/backups /var/lib/alona/health /opt/alona-core/releases
  chown -R alona:alona /var/lib/alona
}

install_mosquitto() {
  [[ "$INSTALL_MOSQ" -eq 1 ]] || return 0
  cp "$MOSQ_TEMPLATE_DIR/mosquitto.conf" /etc/mosquitto/mosquitto.conf
  cp "$MOSQ_TEMPLATE_DIR/acl" /etc/mosquitto/acl
  install -m 600 /dev/null /etc/mosquitto/passwd || true

  if [[ -n "${CORE_MQTT_PASSWORD:-}" ]]; then
    mosquitto_passwd -b /etc/mosquitto/passwd "$CORE_MQTT_USER" "$CORE_MQTT_PASSWORD"
  else
    mosquitto_passwd /etc/mosquitto/passwd "$CORE_MQTT_USER"
  fi

  systemctl enable mosquitto
  systemctl restart mosquitto
}

install_core() {
  [[ "$INSTALL_CORE" -eq 1 ]] || return 0
  cp "$CORE_TEMPLATE_DIR/systemd/alona-core.service" /etc/systemd/system/alona-core.service
  [[ -f /etc/alona/core.env ]] || cp "$CORE_TEMPLATE_DIR/env/alona-core.env.example" /etc/alona/core.env
  chmod 600 /etc/alona/core.env
  systemctl daemon-reload
  systemctl enable alona-core
}

install_backups() {
  [[ "$INSTALL_BACKUPS" -eq 1 ]] || return 0
  install -m 755 "$BACKUP_SCRIPTS_DIR/backup.sh" /usr/local/bin/alona-core-backup
  install -m 755 "$BACKUP_SCRIPTS_DIR/retention.sh" /usr/local/bin/alona-core-retention
  install -m 755 "$BACKUP_SCRIPTS_DIR/restore.sh" /usr/local/bin/alona-core-restore
  cp "$BACKUP_TEMPLATE_DIR/alona-core-backup.service" /etc/systemd/system/
  cp "$BACKUP_TEMPLATE_DIR/alona-core-backup.timer" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now alona-core-backup.timer
}

install_monitoring() {
  [[ "$INSTALL_MONITORING" -eq 1 ]] || return 0
  install -m 755 "$MONITORING_SCRIPTS_DIR/healthcheck.sh" /usr/local/bin/alona-healthcheck
  cp "$MONITORING_SYSTEMD_DIR/alona-health.service" /etc/systemd/system/
  cp "$MONITORING_SYSTEMD_DIR/alona-health.timer" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now alona-health.timer
}

main() {
  need_root
  parse_args "$@"
  require_files
  install_packages
  ensure_user_dirs
  install_mosquitto
  install_core
  install_backups
  install_monitoring
  echo "Install complete."
}

main "$@"
