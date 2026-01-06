# Monitoring (Lightweight)

This monitoring setup is intentionally simple and offline-friendly.

## What it does

A systemd timer runs a healthcheck script every 5 minutes and logs the result to journald.

Health checks:
- `mosquitto` service active
- `core` service active
- disk usage under a threshold (default: 85% used)
- last successful backup age under a threshold (default: 48 hours)
- optional HTTP check to `core` health endpoint (disabled by default)

## Files

- `monitoring/healthcheck.sh` → installed to `/usr/local/bin/alona-healthcheck`
- `services/monitoring/systemd/alona-health.service`
- `services/monitoring/systemd/alona-health.timer`

## Install on Pi

```bash
sudo install -m 0755 monitoring/healthcheck.sh /usr/local/bin/alona-healthcheck
sudo cp services/monitoring/systemd/alona-health.service /etc/systemd/system/alona-health.service
sudo cp services/monitoring/systemd/alona-health.timer /etc/systemd/system/alona-health.timer
sudo systemctl daemon-reload
sudo systemctl enable --now alona-health.timer
```

## View status / logs

```bash
sudo systemctl list-timers --all | grep alona-health || true
sudo systemctl status alona-health.service --no-pager
sudo journalctl -u alona-health.service --since "2 hours ago" --no-pager
```

## Health state files

- `/var/lib/alona/health/last_ok`
- `/var/lib/alona/health/last_fail`

These are useful for quick checks and for `collect-debug.sh`.
