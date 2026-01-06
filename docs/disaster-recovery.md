# Disaster Recovery — Alona Infra

This document covers **failure scenarios** and how to recover in the field.

---

## Power Loss / Sudden Reboot

Expected in off-grid systems.

### What should happen
- Pi reboots
- systemd restarts all services
- No manual action required

### If services do not come up
```bash
sudo systemctl status mosquitto core --no-pager
journalctl -b -p err --no-pager
```

---

## Disk Full

Symptoms:
- core crashes
- backups fail
- healthcheck FAILs

Fix:
```bash
df -h
rm -f /var/lib/alona/backups/core-backup-*.tar.gz
journalctl --vacuum-size=100M
```

---

## Database Locked / Corrupt

Symptoms:
- core errors mentioning SQLite
- ingestion stops

Steps:
1. Stop core:
```bash
sudo systemctl stop core
```

2. Restore latest backup:
```bash
sudo /usr/local/bin/alona-core-restore --from /var/lib/alona/backups/core-backup-<latest>.tar.gz
```

3. Start core:
```bash
sudo systemctl start core
```

---

## Mosquitto Failure

```bash
sudo systemctl restart mosquitto
journalctl -u mosquitto -n 200 --no-pager
```

Check:
- `/etc/mosquitto/mosquitto.conf`
- `/etc/mosquitto/acl`
- `/etc/mosquitto/passwd` permissions

---

## SD Card / Disk Failure

Worst case.

Recovery:
1. Re-flash OS
2. Provision Pi
3. Install infra
4. Restore latest backup

This is why backups matter.

---

## Philosophy

You should always be able to recover **offline** with:
- SSH access
- Infra repo
- Latest backup
