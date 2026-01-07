# System Hardening (Alona Infra)

This document describes **minimal, practical hardening** for an off-grid Raspberry Pi
running Alona Infra.

The goal is **reduce risk without adding operational complexity**.
This is not enterprise hardening.

---

## Principles

- Prefer **boring defaults** over clever security
- Avoid anything that can lock you out in the field
- Assume:
  - LAN-only access
  - No exposed internet services
  - Physical access risk exists (mountain/off-grid)

---

## 1) Users & Privileges

### Dedicated service user

Alona services run as a **dedicated system user**:

- User: `alona`
- Home: `/var/lib/alona`
- Shell: `/usr/sbin/nologin`

Verify:

```bash
id alona
```

No services should run as `root` unless strictly required (e.g. systemd oneshot scripts).

---

## 2) SSH Hardening (Safe Mode)

Recommended if you use SSH keys.

Edit:

```bash
sudo nano /etc/ssh/sshd_config
```

Set or verify:

```text
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

Restart SSH:

```bash
sudo systemctl restart ssh
```

⚠️ Do this **only after** verifying key-based login works.

---

## 3) Network Exposure

### LAN-only policy

- No port forwarding from router to Pi
- No public IP exposure
- Access UI only from local LAN or via VPN (optional)

Verify listening ports:

```bash
ss -lntup
```

Expected:

- Mosquitto: `:1883` (LAN)
- Core UI: `:4000` (LAN)
- SSH: `:22` (LAN)

---

## 4) Firewall (Optional)

A firewall is **optional** in a trusted LAN.
If you want one, keep it simple.

### UFW (minimal)

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 1883/tcp
sudo ufw allow 4000/tcp
sudo ufw enable
```

Check:

```bash
sudo ufw status
```

⚠️ Do not enable firewall remotely unless you are sure SSH is allowed.

---

## 5) Filesystem & Permissions

Critical paths:

- `/etc/alona` → **root-owned**, secrets inside
- `/var/lib/alona` → owned by `alona`
- `/opt/alona-core` → root-owned, read-only releases

Verify:

```bash
ls -ld /etc/alona /var/lib/alona /opt/alona-core
```

---

## 6) Journald Limits (Disk Protection)

Ensure logs don’t fill the disk:

```bash
sudo nano /etc/systemd/journald.conf
```

Recommended:

```text
SystemMaxUse=200M
RuntimeMaxUse=100M
```

Restart:

```bash
sudo systemctl restart systemd-journald
```

---

## 7) Disk Health

- Keep >15% free disk space
- Avoid cheap SD cards
- Prefer SSD if possible

Check:

```bash
df -h
```

---

## 8) Automatic Updates (Not Recommended)

For off-grid systems:

- ❌ Avoid unattended upgrades
- ✔️ Update manually when physically present

Reason:

- Updates can fail
- Reboots can happen unexpectedly
- Debugging remotely may be impossible

---

## 9) Backups Are Your Real Security

Security priority order:

1. **Backups**
2. Ability to **restore**
3. Everything else

Verify backups:

```bash
ls -lh /var/lib/alona/backups
cat /var/lib/alona/backups/LAST_SUCCESSFUL_ISO
```

---

## 10) Physical Security Notes

- Assume SD/SSD can be removed
- Do not store irreplaceable secrets on the device
- Backups should occasionally be copied off-device

---

## 11) What We Intentionally Do NOT Do

- Full disk encryption (risk of lockout)
- SELinux / AppArmor tuning
- IDS/IPS
- Complex firewall rules
- Auto security updates

These add more operational risk than benefit in an off-grid context.

---

## Summary

This hardening approach is:

- Minimal
- Reversible
- Field-friendly

If the system reboots unattended and comes back up cleanly,
**it is hardened enough**.
