
#!/usr/bin/env bash
set -euo pipefail

echo "==> Alona Infra status"
echo

echo "-- Services"
systemctl is-active --quiet mosquitto && echo "mosquitto: active" || echo "mosquitto: NOT active"
systemctl is-active --quiet core && echo "core:      active" || echo "core:      NOT active"
echo

echo "-- Symlinks"
if [[ -L /opt/core/current ]]; then
  echo "current:  $(readlink -f /opt/core/current)"
else
  echo "current:  (missing)"
fi

if [[ -L /opt/core/previous ]]; then
  echo "previous: $(readlink -f /opt/core/previous)"
else
  echo "previous: (missing)"
fi
echo

echo "-- Data"
if [[ -f /var/lib/alona/db/alona.sqlite3 ]]; then
  echo "db:       /var/lib/alona/db/alona.sqlite3 (exists)"
else
  echo "db:       /var/lib/alona/db/alona.sqlite3 (missing)"
fi
df -h /var/lib/alona 2>/dev/null || df -h /
echo

echo "-- Useful logs"
echo "  journalctl -u mosquitto -n 200 --no-pager"
echo "  journalctl -u core      -n 200 --no-pager"
