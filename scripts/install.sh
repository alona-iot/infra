
#!/usr/bin/env bash
set -euo pipefail

# Alona IoT - Infra installer (Mosquitto + base dirs)
# - LAN-only MQTT with auth + ACL
# - No secrets committed; passwords are set interactively (or via env vars)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MOSQ_TEMPLATE_DIR="$REPO_ROOT/services/mosquitto"

usage() {
  cat <<'USAGE'
Usage:
  sudo ./scripts/install.sh --pi-ip <LAN_IP> [--core-user alona-core] [--nodes node-001,node-002] [--no-test]

Options:
  --pi-ip <LAN_IP>          LAN IP of the Raspberry Pi (used for smoke test and helpful output)
  --core-user <name>        MQTT username for backend (default: alona-core)
  --nodes <csv>             Comma-separated node usernames (default: none)
  --no-test                 Skip mosquitto_pub/sub smoke test
  -h, --help                Show this help

Environment variables (optional):
  CORE_PASSWORD             If set, will be used for core user without prompting
  NODE_PASSWORD             If set, will be used for all node users without prompting (not recommended long-term)

Notes:
  - This script configures Mosquitto to use:
      /etc/mosquitto/mosquitto.conf
      /etc/mosquitto/acl
      /etc/mosquitto/passwd  (generated locally)
  - It does NOT enable TLS; LAN-only baseline.
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
  if [[ "$missing" -eq 1 ]]; then
    exit 1
  fi
}

parse_args() {
  PI_IP=""
  CORE_USER="alona-core"
  NODES_CSV=""
  DO_TEST=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pi-ip)
        PI_IP="${2:-}"; shift 2;;
      --core-user)
        CORE_USER="${2:-}"; shift 2;;
      --nodes)
        NODES_CSV="${2:-}"; shift 2;;
      --no-test)
        DO_TEST=0; shift 1;;
      -h|--help)
        usage; exit 0;;
      *)
        echo "ERROR: Unknown argument: $1" >&2
        usage
        exit 1;;
    esac
  done

  if [[ -z "$PI_IP" ]]; then
    echo "ERROR: --pi-ip is required (LAN IP of the Raspberry Pi)." >&2
    usage
    exit 1
  fi
}

install_packages() {
  echo "==> Installing packages..."
  apt-get update -y
  apt-get install -y mosquitto mosquitto-clients
  systemctl enable mosquitto >/dev/null
}

setup_dirs() {
  echo "==> Creating Alona directories..."
  install -d -m 0755 /etc/alona
  install -d -m 0755 /var/lib/alona
  install -d -m 0755 /var/lib/alona/db
  install -d -m 0755 /var/lib/alona/backups
}

apply_mosquitto_config() {
  echo "==> Applying Mosquitto config + ACL..."
  install -d -m 0755 /etc/mosquitto

  # Backup existing config if present
  if [[ -f /etc/mosquitto/mosquitto.conf ]]; then
    cp -a /etc/mosquitto/mosquitto.conf "/etc/mosquitto/mosquitto.conf.bak.$(date +%Y%m%d%H%M%S)"
  fi
  if [[ -f /etc/mosquitto/acl ]]; then
    cp -a /etc/mosquitto/acl "/etc/mosquitto/acl.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cp -a "$MOSQ_TEMPLATE_DIR/mosquitto.conf" /etc/mosquitto/mosquitto.conf
  cp -a "$MOSQ_TEMPLATE_DIR/acl" /etc/mosquitto/acl

  chown root:root /etc/mosquitto/mosquitto.conf /etc/mosquitto/acl
  chmod 0644 /etc/mosquitto/mosquitto.conf /etc/mosquitto/acl
}

ensure_passwd_file() {
  echo "==> Ensuring Mosquitto password file exists..."
  if [[ ! -f /etc/mosquitto/passwd ]]; then
    install -m 0600 -o root -g root /dev/null /etc/mosquitto/passwd
  fi
}

set_user_password_interactive() {
  local user="$1"
  local pass_env="${2:-}"

  if [[ -n "$pass_env" ]]; then
    # Set/update password non-interactively
    printf "%s\n%s\n" "$pass_env" "$pass_env" | mosquitto_passwd -b /etc/mosquitto/passwd "$user" "$pass_env" >/dev/null 2>&1 || {
      # Fallback: some distros don’t like -b with piped input; use -b directly.
      mosquitto_passwd -b /etc/mosquitto/passwd "$user" "$pass_env"
    }
  else
    echo
    echo "Set password for MQTT user: $user"
    mosquitto_passwd /etc/mosquitto/passwd "$user"
  fi
}

create_users() {
  echo "==> Creating/updating MQTT users..."
  # Core user
  if [[ -n "${CORE_PASSWORD:-}" ]]; then
    set_user_password_interactive "$CORE_USER" "$CORE_PASSWORD"
  else
    set_user_password_interactive "$CORE_USER" ""
  fi

  # Node users (optional)
  if [[ -n "$NODES_CSV" ]]; then
    IFS=',' read -r -a nodes <<<"$NODES_CSV"
    for n in "${nodes[@]}"; do
      n="$(echo "$n" | xargs)" # trim
      [[ -z "$n" ]] && continue
      if [[ -n "${NODE_PASSWORD:-}" ]]; then
        set_user_password_interactive "$n" "$NODE_PASSWORD"
      else
        set_user_password_interactive "$n" ""
      fi

      # NOTE: ACL template must contain matching 'user <node>' blocks.
      # We keep this script conservative: it does not auto-edit ACL.
      # You should add the node section to services/mosquitto/acl and re-run install.
    done
  fi

  chown root:root /etc/mosquitto/passwd
  chmod 0600 /etc/mosquitto/passwd
}

restart_and_check() {
  echo "==> Restarting Mosquitto..."
  systemctl restart mosquitto
  systemctl --no-pager --full status mosquitto || true

  echo "==> Quick log tail:"
  journalctl -u mosquitto -n 50 --no-pager || true
}

smoke_test() {
  local core_user="$1"
  local pi_ip="$2"

  if [[ "$DO_TEST" -eq 0 ]]; then
    echo "==> Skipping smoke test (--no-test)."
    return 0
  fi

  echo
  echo "==> Smoke test (requires core password)."
  echo "    We'll subscribe as '$core_user' and publish a test message as that user."
  echo "    If you prefer not to test now, re-run with --no-test."
  echo

  local core_pass=""
  if [[ -n "${CORE_PASSWORD:-}" ]]; then
    core_pass="$CORE_PASSWORD"
  else
    read -r -s -p "Enter password for MQTT user '$core_user' (for smoke test only): " core_pass
    echo
  fi

  local topic="alona/tele/install-test/$(hostname)/$(date +%s)"
  local msg="ok"

  # Start subscriber in background
  set +e
  mosquitto_sub -h "$pi_ip" -p 1883 -u "$core_user" -P "$core_pass" -t "$topic" -C 1 -W 5 >/tmp/alona_mosq_test.out 2>/tmp/alona_mosq_test.err &
  local sub_pid=$!
  set -e

  sleep 0.3

  mosquitto_pub -h "$pi_ip" -p 1883 -u "$core_user" -P "$core_pass" -t "$topic" -m "$msg"

  # Wait for subscriber to exit
  wait "$sub_pid" || true

  if grep -q "$msg" /tmp/alona_mosq_test.out; then
    echo "==> Smoke test: PASS (received '$msg' on $topic)"
  else
    echo "==> Smoke test: FAIL"
    echo "Subscriber output:"
    cat /tmp/alona_mosq_test.out || true
    echo "Subscriber errors:"
    cat /tmp/alona_mosq_test.err || true
    echo
    echo "Troubleshoot:"
    echo "  - Check: journalctl -u mosquitto -n 200 --no-pager"
    echo "  - Confirm Pi IP: $pi_ip"
    echo "  - Confirm ACL allows user '$core_user' to read/write expected topics"
    exit 1
  fi
}

main() {
  need_root
  parse_args "$@"
  require_files

  echo "==> Alona Infra install (Mosquitto baseline)"
  echo "    Pi IP:      $PI_IP"
  echo "    Core user:  $CORE_USER"
  echo "    Nodes:      ${NODES_CSV:-<none>}"
  echo

  install_packages
  setup_dirs
  apply_mosquitto_config
  ensure_passwd_file
  create_users
  restart_and_check
  smoke_test "$CORE_USER" "$PI_IP"

  echo
  echo "==> Done."
  echo "Next:"
  echo "  - Add per-node ACL blocks in services/mosquitto/acl for each node user."
  echo "  - Then re-run: sudo ./scripts/install.sh --pi-ip $PI_IP --core-user $CORE_USER --nodes $NODES_CSV"
}

main "$@"
