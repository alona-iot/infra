# Maintenance — Alona Infra

This document describes **regular maintenance tasks**.

---

## Weekly

- Check disk usage
```bash
df -h
```

- Check health
```bash
cat /var/lib/alona/health/last_ok
```

---

## Monthly

- Update OS packages (when physically present)
```bash
sudo apt update
sudo apt upgrade
sudo reboot
```

- Verify backups
```bash
ls -lh /var/lib/alona/backups
```

---

## Before Leaving the Site

- Ensure at least one recent backup exists
- Disk usage < 70%
- `last_ok` updated recently

---

## Upgrades

- Deploy new core releases manually
- Keep previous release for rollback
- Never auto-upgrade in the field

---

## Storage

- Prefer SSD over SD
- Replace SD cards proactively
