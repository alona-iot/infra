#!/usr/bin/env bash
set -euo pipefail

# Alona IoT - Infra installer (Mosquitto + Core scaffolding)
# - LAN-only MQTT with auth + ACL
# - Core (Phoenix + MQTT ingest) runs as a systemd service: core.service
#
# Run from repo root:
#   sudo ./scripts/install.sh --pi-ip 192.168.1.50 --nodes node-001,node-002

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MOSQ_TEMPLATE_DIR="$REPO_ROOT/services/mosquitto"
CORE_TEMPLATE_DIR="$REPO_ROOT/services/core"

usage() {
  cat <<'USAGE'
Usage:
  sudo ./scripts/install.sh --pi-ip <LAN_IP> [options]

Required:
  --pi-ip <LAN_IP>              LAN IP of the Raspberry Pi (for smoke test & output)

Options:
  --core-mqtt-user <name>       MQTT username for backend (default: alona-core)
  --nodes <csv>                 Comma-separated node MQTT usernames (default: none)
  --no-test                     Skip mosquitto_pub/sub smoke test
  --skip-core                   Do not install core.service or /etc/alona/core.env
  --skip-mosquitto              Do not install/configure mosquitto (core-only scaffolding)
  -h, --help                    Show help

Environment variables (optional):
  CORE_MQTT_PASSWORD            If set, will be used for core MQTT user without prompting
  NODE_MQTT_PASSWORD            If set, used for all node MQTT users without prompting (not recommended long-term)

Notes:
  - This script DOES NOT commit secrets. It sets passwords on the Pi in /etc/mosquitto/passwd.
  - ACL is NOT auto-generated per node. If you add node users, ensure services/mosquitto/acl contains blocks for them.
USAGE
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Please run as root (use sudo)." >&2
    exit 1
  fi
}

require_files() {
  local missing=0

  # mosquitto templates
  for f in \
    "$MOSQ_TEMPLATE_DIR/mosquitto.conf" \
    "$MOSQ_TEMPLATE_DIR/acl" \
    "$MOSQ_TEMPLATE_DIR/passwd.example"
  do
    if [[ ! -f "$f" ]]; then
      echo "ERROR: Missing required file: $f" >&2
      missing=1
    fi
  done

  # core templates
  for f in \
    "$CORE_TEMPLATE_DIR/systemd/core.service" \
    "$CORE_TEMPLATE_DIR/env/core.env.example"
  do
    if [[ ! -f "$f" ]]; then
      echo "ERROR: Missing required file: $f" >&2
      missing=1
    fi
  done

  [[ "$missing" -eq 0 ]] || exit 1
}

parse_args() {
  PI_IP=""
  CORE_MQTT_USER="alona-core"
  NODES_CSV=""
  DO_TEST=1
  INSTALL_CORE=1
  INSTALL_MOSQ=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pi-ip)
        PI_IP="${2:-}"; shift 2;;
      --core-mqtt-user)
        CORE_MQTT_USER="${2:-}"; shift 2;;
      --nodes)
        NODES_CSV="${2:-}"; shift 2;;
      --no-test)
        DO_TEST=0; shift 1;;
      --skip-core)
        INSTALL_CORE=0; shift 1;;
      --skip-mosquitto)
        INSTALL_MOSQ=0; shift 1;;
      -h|--help)
        usage; exit 0;;
      *)
        echo "ERROR: Unknown argument: $1" >&2
        usage
        exit 1;;
    esac
  done

  if [[ -z "$PI_IP" ]]; then
    echo "ERROR: --pi-ip is required." >&2
    usage
    exit 1
  fi

  if [[ "$INSTALL_CORE" -eq 0 && "$INSTALL_MOSQ" -eq 0 ]]; then
    echo "ERROR: Nothing to do (both --skip-core and --skip-mosquitto were set)." >&2
    exit 1
  fi
}

apt_install() {
  echo "==> Installing packages..."
  apt-get update -y

  if [[ "$INSTALL_MOSQ" -eq 1 ]]; then
    apt-get install -y mosquitto mosquitto-clients
    systemctl enable mosquitto >/dev/null
  fi

  # (Core release dependencies are assumed to be bundled in the release.
  #  This script only installs service scaffolding.)
}

ensure_system_user() {
  echo "==> Ensuring system user 'alona' exists..."
  if id -u alona >/dev/null 2>&1; then
    echo "    user 'alona' already exists."
  else
    useradd --system --create-home --home-dir /var/lib/alona --shell /usr/sbin/nologin alona
    echo "    created user 'alona'."
  fi
}

setup_dirs() {
  echo "==> Creating directories..."
  install -d -m 0755 /etc/alona
  install -d -m 0755 /var/lib/alona
  install -d -m 0755 /var/lib/alona/db
  install -d -m 0755 /var/lib/alona/backups
  install -d -m 0755 /opt/core

  chown -R alona:alona /var/lib/alona
}

backup_if_exists() {
  local path="$1"
  if [[ -f "$path" ]]; then
    cp -a "$path" "${path}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

apply_mosquitto_config() {
  [[ "$INSTALL_MOSQ" -eq 1 ]] || return 0

  echo "==> Applying Mosquitto config + ACL..."
  install -d -m 0755 /etc/mosquitto

  backup_if_exists /etc/mosquitto/mosquitto.conf
  backup_if_exists /etc/mosquitto/acl

  cp -a "$MOSQ_TEMPLATE_DIR/mosquitto.conf" /etc/mosquitto/mosquitto.conf
  cp -a "$MOSQ_TEMPLATE_DIR/acl" /etc/mosquitto/acl

  chown root:root /etc/mosquitto/mosquitto.conf /etc/mosquitto/acl
  chmod 0644 /etc/mosquitto/mosquitto.conf /etc/mosquitto/acl
}

ensure_passwd_file() {
  [[ "$INSTALL_MOSQ" -eq 1 ]] || return 0

  echo "==> Ensuring /etc/mosquitto/passwd exists..."
  if [[ ! -f /etc/mosquitto/passwd ]]; then
    install -m 0600 -o root -g root /dev/null /etc/mosquitto/passwd
  else
    chmod 0600 /etc/mosquitto/passwd
    chown root:root /etc/mosquitto/passwd
  fi
}

set_mqtt_password() {
  local user="$1"
  local pass="${2:-}"

  if [[ -n "$pass" ]]; then
    mosquitto_passwd -b /etc/mosquitto/passwd "$user" "$pass"
  else
    echo
    echo "Set password for MQTT user: $user"
    mosquitto_passwd /etc/mosquitto/passwd "$user"
  fi
}

create_mqtt_users() {
  [[ "$INSTALL_MOSQ" -eq 1 ]] || return 0

  echo "==> Creating/updating MQTT users..."

  # Core MQTT user
  if [[ -n "${CORE_MQTT_PASSWORD:-}" ]]; then
    set_mqtt_password "$CORE_MQTT_USER" "$CORE_MQTT_PASSWORD"
  else
    set_mqtt_password "$CORE_MQTT_USER" ""
  fi

  # Node users (optional)
  if [[ -n "$NODES_CSV" ]]; then
    IFS=',' read -r -a nodes <<<"$NODES_CSV"
    for n in "${nodes[@]}"; do
      n="$(echo "$n" | xargs)" # trim
      [[ -z "$n" ]] && continue

      if [[ -n "${NODE_MQTT_PASSWORD:-}" ]]; then
        set_mqtt_password "$n" "$NODE_MQTT_PASSWORD"
      else
        set_mqtt_password "$n" ""
      fi
    done
  fi

  chmod 0600 /etc/mosquitto/passwd
  chown root:root /etc/mosquitto/passwd

  echo
  echo "NOTE: If you added node users, ensure services/mosquitto/acl includes matching 'user <node>' blocks."
}

restart_mosquitto() {
  [[ "$INSTALL_MOSQ" -eq 1 ]] || return 0

  echo "==> Restarting Mosquitto..."
  systemctl restart mosquitto
  systemctl --no-pager --full status mosquitto || true

  echo "==> Mosquitto log tail:"
  journalctl -u mosquitto -n 50 --no-pager || true
}

install_core_scaffolding() {
  [[ "$INSTALL_CORE" -eq 1 ]] || return 0

  echo "==> Installing core.service + /etc/alona/core.env (template)..."

  # Env file: only create if missing, never overwrite silently
  if [[ -f /etc/alona/core.env ]]; then
    echo "    /etc/alona/core.env already exists (not overwriting)."
  else
    cp -a "$CORE_TEMPLATE_DIR/env/core.env.example" /etc/alona/core.env
    chown root:root /etc/alona/core.env
    chmod 0600 /etc/alona/core.env
    echo "    created /etc/alona/core.env from template."
  fi

  # systemd unit
  cp -a "$CORE_TEMPLATE_DIR/systemd/core.service" /etc/systemd/system/core.service
  chown root:root /etc/systemd/system/core.service
  chmod 0644 /etc/systemd/system/core.service

  systemctl daemon-reload
  systemctl enable core >/dev/null || true

  echo "==> core.service installed (enabled)."
  echo "    Note: core will fail to start until /opt/core/current contains a valid Elixir release."
}

smoke_test() {
  [[ "$INSTALL_MOSQ" -eq 1 ]] || return 0

  if [[ "$DO_TEST" -eq 0 ]]; then
    echo "==> Skipping MQTT smoke test (--no-test)."
    return 0
  fi

  echo
  echo "==> MQTT smoke test (subscribe + publish as '$CORE_MQTT_USER')"

  local core_pass=""
  if [[ -n "${CORE_MQTT_PASSWORD:-}" ]]; then
    core_pass="$CORE_MQTT_PASSWORD"
  else
    read -r -s -p "Enter password for MQTT user '$CORE_MQTT_USER' (for smoke test only): " core_pass
    echo
  fi

  local topic="alona/tele/install-test/$(hostname)/$(date +%s)"
  local msg="ok"

  set +e
  mosquitto_sub -h "$PI_IP" -p 1883 -u "$CORE_MQTT_USER" -P "$core_pass" -t "$topic" -C 1 -W 5 \
    >/tmp/alona_mosq_test.out 2>/tmp/alona_mosq_test.err &
  local sub_pid=$!
  set -e

  sleep 0.3
  mosquitto_pub -h "$PI_IP" -p 1883 -u "$CORE_MQTT_USER" -P "$core_pass" -t "$topic" -m "$msg"
  wait "$sub_pid" || true

  if grep -q "$msg" /tmp/alona_mosq_test.out; then
    echo "==> Smoke test: PASS (received '$msg')"
  else
    echo "==> Smoke test: FAIL"
    echo "Subscriber output:"; cat /tmp/alona_mosq_test.out || true
    echo "Subscriber errors:"; cat /tmp/alona_mosq_test.err || true
    echo
    echo "Troubleshoot:"
    echo "  - journalctl -u mosquitto -n 200 --no-pager"
    echo "  - verify PI IP: $PI_IP"
    echo "  - verify ACL for user '$CORE_MQTT_USER'"
    exit 1
  fi
}

final_notes() {
  echo
  echo "==> Install complete."
  echo
  if [[ "$INSTALL_CORE" -eq 1 ]]; then
    echo "Core scaffolding:"
    echo "  - systemd unit: /etc/systemd/system/core.service"
    echo "  - env file:     /etc/alona/core.env (edit secrets like SECRET_KEY_BASE, MQTT_PASSWORD)"
    echo "  - release path: /opt/core/current (deploy a release here next)"
    echo
    echo "When you have a release in /opt/core/current:"
    echo "  sudo systemctl start core"
    echo "  sudo systemctl status core --no-pager"
  fi
  if [[ "$INSTALL_MOSQ" -eq 1 ]]; then
    echo
    echo "Mosquitto:"
    echo "  - config: /etc/mosquitto/mosquitto.conf"
    echo "  - acl:    /etc/mosquitto/acl"
    echo "  - passwd: /etc/mosquitto/passwd"
  fi
}

main() {
  need_root
  parse_args "$@"
  require_files

  echo "==> Alona Infra install"
  echo "    Pi IP:            $PI_IP"
  echo "    Install mosquitto: $INSTALL_MOSQ"
  echo "    Install core:      $INSTALL_CORE"
  echo "    Core MQTT user:    $CORE_MQTT_USER"
  echo "    Nodes:             ${NODES_CSV:-<none>}"
  echo

  apt_install
  ensure_system_user
  setup_dirs

  apply_mosquitto_config
  ensure_passwd_file
  create_mqtt_users
  restart_mosquitto
  smoke_test

  install_core_scaffolding
  final_notes
}

main "$@"
