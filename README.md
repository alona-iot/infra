# Alona IoT — Infra (Raspberry Pi Operations)

This repository contains deployment and operational setup for running Alona IoT on a Raspberry Pi in an off-grid environment.

It provides a boring, resilient runtime: MQTT broker configuration, service definitions, database setup, backups, and maintenance procedures — designed to run unattended for long periods.

## Responsibilities

This repository is responsible for:

- Provisioning / host setup for a Raspberry Pi (OS baseline, users, directories, permissions).
- MQTT broker installation & configuration (Mosquitto), including security (users/ACL) and retained-message hygiene.
- Alona core service runtime setup (systemd units, environment files, restart policies).
- Database setup (SQLite by default) including filesystem layout, permissions, and backup/restore.
- Operational scripts for deploy/update, status, logs, health checks, and collecting debug bundles.
- Backup strategy (local-first, optional offsite), retention policy, and disaster recovery procedures.
- Maintenance procedures (safe updates, storage health, log rotation, troubleshooting).

**Out of scope:**

- Application logic, sensor firmware, and domain features (those live in their respective repos).
- "Cloud product" features. This is a personal system optimized for resilience and clarity.

## Design Principles

- **Resilience over features**: the system must keep running with minimal intervention.
- **Fault isolation**: one failing component (node, broker client, DB write) should not cascade.
- **Recoverability**: backup/restore is first-class; recovery steps are documented and tested.
- **Simple operations**: avoid heavy orchestration; prefer systemd, plain files, and readable scripts.
- **Local-first**: must work without internet. Remote access is optional, not required.
- **Least moving parts**: minimize dependencies and keep configurations explicit and versioned.
- **Observability that works offline**: logs and basic health checks available locally.

## Architecture Overview

At a high level:

- ESP32 nodes publish sensor telemetry via MQTT.
- Mosquitto runs locally on the Raspberry Pi as the broker.
- Alona core backend (Elixir/OTP/Phoenix release) subscribes to MQTT, processes messages, and stores data.
- SQLite stores state and history (local filesystem).
- Backups run on a schedule and are stored locally (and optionally replicated offsite when available).

**Key runtime directories (convention):**

- `/etc/alona/` — configuration (env files, broker ACL, etc.)
- `/var/lib/alona/` — persistent data (SQLite DB, backups, runtime state)
- `/var/log/alona/` — logs if using file logs (otherwise use journald)

## Quickstart (Happy Path)

High-level steps to go from a clean Raspberry Pi OS install to a running system:

1. Provision the Pi (base packages, user, directories).
2. Install and configure Mosquitto (users + ACL).
3. Install Alona core release and configure environment.
4. Enable and start services.
5. Verify end-to-end: publish a test MQTT message and confirm ingestion.

See:

- `provisioning/pi-os-setup.md`
- `services/mosquitto/`
- `services/core/`
- `docs/runbook.md`

## Repository Layout

- `docs/` — architecture, runbooks, maintenance, disaster recovery
- `provisioning/` — Raspberry Pi OS setup and hardening
- `services/` — systemd units and configuration templates
- `scripts/` — install/deploy/update/status/debug helpers
- `backups/` — backup/restore scripts and retention policy
- `monitoring/` — local health checks, log rotation, watchdog helpers

## Deployment and Updates

This repo supports predictable, rollback-friendly updates.

**Typical workflow:**

1. Build/publish a new core release artifact (in the core repo).
2. On the Pi, run an update script that:
   - downloads/unpacks the release to a versioned path
   - updates a stable symlink (e.g. `/opt/alona-core/current`)
   - restarts the service via systemd
   - keeps the previous release for quick rollback

See `scripts/deploy.sh` and `scripts/update.sh` (to be added).

## Operations (Day 2)

Common operator actions (examples; actual commands live in `docs/runbook.md`):

- Check service status (broker + alona-core)
- View logs (journald)
- Restart a single component without affecting others
- Verify disk usage and backup health
- Validate MQTT connectivity and retained messages behavior

## Backups and Restore

Backups are local-first and designed for power/network instability:

- Scheduled backups of the SQLite database and essential config.
- Retention policy to avoid filling the SD card.
- Restore procedure that can be executed offline.

See:

- `backups/backup.sh`
- `backups/restore.sh`
- `docs/disaster-recovery.md`

## Failure and Recovery

This repo documents how to recover from common failures:

- Power loss / unclean shutdown
- SD card corruption symptoms
- Mosquitto misconfiguration or auth issues
- alona-core service crash loops
- Database locked/corrupt scenarios
- Running out of disk space

See `docs/runbook.md` and `docs/disaster-recovery.md`.

## Security Model

- MQTT broker uses authenticated clients and topic ACLs.
- Default stance is local network only; remote access is optional and explicit.
- Secrets are stored on the Pi (e.g. `/etc/alona/`) and not committed to git.
- This repo contains templates/examples, not real secrets.

## Related Repositories

- `alona-iot/core` — Elixir/OTP/Phoenix backend (MQTT ingestion, storage, APIs/UI if any)
- `alona-iot/nodes` — ESP32 firmware / sensor nodes
- `alona-iot/infra` — this repository (deployment + operations)

(Adjust names/paths to match your actual org/repo naming.)

## Status and Roadmap (Infra)

Initial milestones:

- Mosquitto config + ACL + user management
- systemd units for broker + alona-core
- Local backup/restore with retention
- Minimal health check script + "collect debug bundle"
- Documented runbook and disaster recovery drill
