# Provisioning Raspberry Pi OS for Alona Infra

Target: **Raspberry Pi OS Lite (Bookworm)** on a Raspberry Pi running off-grid.

## Goals

- Stable host baseline
- Predictable **LAN-only** networking
- Good offline logs (persistent journald)
- Safe storage defaults (avoid filling disk)
- Ready to run `scripts/install.sh` and then deploy core releases

---

## 0) Flash the OS

1. Flash **Raspberry Pi OS Lite (Bookworm)** to an SD card (or SSD if supported).
2. In Raspberry Pi Imager (recommended), set:
   - Hostname (e.g. `alona-pi`)
   - Enable SSH
   - Create a user (avoid default passwords)
   - Configure Wi-Fi (only if you won’t use Ethernet)
   - Locale + timezone: `Europe/Athens`

Boot the Pi.

---

## 1) First login

SSH in:

```bash
ssh <user>@<pi-ip>
```

Update and reboot:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

---

## 2) Install baseline tools

After reboot:

```bash
sudo apt update
sudo apt install -y \
  git curl ca-certificates \
  tmux vim \
  htop \
  jq \
  lsof \
  rsync
```

---

## 3) Timezone and hostname

Set timezone:

```bash
sudo timedatectl set-timezone Europe/Athens
timedatectl
```

Set hostname (skip if already set):

```bash
sudo hostnamectl set-hostname alona-pi
hostnamectl
```

(Optional) Ensure `/etc/hosts` has a `127.0.1.1` entry for the hostname:

```bash
grep -n "127.0.1.1" /etc/hosts || echo -e "127.0.1.1\talona-pi" | sudo tee -a /etc/hosts
```

---

## 4) SSH hardening (minimal)

If you use SSH keys, disable password authentication.

Edit:

```bash
sudo nano /etc/ssh/sshd_config
```

Recommended settings:

- `PasswordAuthentication no`
- `PermitRootLogin no`
- `PubkeyAuthentication yes`

Apply:

```bash
sudo systemctl restart ssh
```

---

## 5) Persistent journald logs (offline-friendly)

Enable persistent journal storage:

```bash
sudo mkdir -p /var/log/journal
sudo systemctl restart systemd-journald
```

Limit disk usage (recommended for SD cards):

```bash
sudo nano /etc/systemd/journald.conf
```

Suggested values:

- `SystemMaxUse=200M`
- `RuntimeMaxUse=100M`

Restart journald:

```bash
sudo systemctl restart systemd-journald
```

Verify:

```bash
journalctl --disk-usage
```

---

## 6) Networking note (LAN-only)

Recommended:

- Prefer **Ethernet** from Pi to router/AP if possible.
- If Wi-Fi is required, keep the Pi close to the AP.

Policy:

- No internet port forwarding
- Remote access later only via VPN if needed (optional)

---

## 7) Storage & reliability notes

- Prefer high-endurance SD or (better) SSD.
- Keep free disk space > ~15% to avoid weird failures.
- Off-grid power loss is expected: backups + fast recovery matter more than perfect shutdown.

---

## 8) Get the infra repo on the Pi

Example:

```bash
mkdir -p ~/alona
cd ~/alona
git clone <YOUR_INFRA_REPO_URL> infra
cd infra
```

---

## 9) Run infra install

From repo root:

```bash
sudo ./scripts/install.sh --pi-ip <PI_LAN_IP> --nodes node-001,node-002
```

---

## 10) Verify

```bash
./scripts/status.sh
sudo systemctl status mosquitto core --no-pager
sudo systemctl list-timers --all | grep core-backup || true
```

---

## 11) Deploy a release

```bash
sudo ./scripts/deploy.sh --tar /path/to/core-<ver>.tar.gz --version <ver>
```

Check:

```bash
sudo systemctl status core --no-pager
sudo journalctl -u core -n 200 --no-pager
```
