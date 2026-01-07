# Runbook — Alona Infra

This document is the **day-to-day operational guide** for Alona IoT running off-grid.

Everything here assumes:
- LAN-only access
- No cloud dependencies
- Systemd-managed services
- journald logging

---

## Services

- `mosquitto` — MQTT broker
- `alona-core` — Phoenix + ingestion + UI
- `alona-core-backup.timer` — daily backups
- `alona-health.timer` — 5-minute health checks

---

## Common Commands

### Service status
```bash
sudo systemctl status mosquitto alona-core --no-pager
```

### Restart services
```bash
sudo systemctl restart mosquitto
sudo systemctl restart alona-core
```

### Logs
```bash
journalctl -u alona-core -n 200 --no-pager
journalctl -u mosquitto -n 200 --no-pager
```

### Health status
```bash
cat /var/lib/alona/health/last_ok
cat /var/lib/alona/health/last_fail
```

---

## Backups

### Check last backup
```bash
ls -lh /var/lib/alona/backups
cat /var/lib/alona/backups/LAST_SUCCESSFUL_ISO
```

### Run backup manually
```bash
sudo systemctl start alona-core-backup.service
```

### Restore
```bash
sudo /usr/local/bin/alona-core-restore --from /var/lib/alona/backups/core-backup-<file>.tar.gz
```

⚠️ Restore stops `alona-core` and overwrites DB + `/etc/alona`.

---

## Debug bundle

```bash
sudo ./scripts/collect-debug.sh --since "24 hours ago"
```

Bundle created in:
```
/var/lib/alona/debug-bundles/
```

---

## Disk checks

```bash
df -h
journalctl --disk-usage
```

Keep disk usage < 85% on `/var/lib/alona`.

---

## MQTT smoke test

```bash
mosquitto_sub -h <pi-ip> -u alona-core -t alona/#
```

---

## Golden Rule

If something feels wrong:
1. Check health
2. Check disk
3. Check logs
4. Check backups
