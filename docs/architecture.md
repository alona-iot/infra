# Architecture — Alona IoT Infra

This document describes the **overall architecture** of Alona IoT,
with emphasis on **resilience, simplicity, and offline operation**.

---

## System Overview

Alona IoT is a **personal, off-grid IoT system** designed to run unattended
in a remote environment (mountains, limited power, unstable connectivity).

High-level goals:
- Survive long-term without maintenance
- Fail predictably
- Be recoverable offline
- Prefer simplicity over features

---

## High-Level Diagram (Logical)

```
[ ESP32 Nodes ]
      |
      |  Wi-Fi (LAN)
      v
[ MQTT Broker (Mosquitto) ]
      |
      |  localhost
      v
[ Core Service (Elixir/Phoenix) ]
      |
      v
[ SQLite Database ]
```

---

## Components

### ESP32 Sensor Nodes

- Publish telemetry via MQTT
- Stateless
- Reconnect automatically
- No local persistence assumed

Failure impact:
- Isolated per node
- Does not affect backend stability

---

### MQTT Broker (Mosquitto)

- Runs on Raspberry Pi
- LAN-only
- Username/password authentication
- ACL-based topic isolation

Responsibilities:
- Message fan-in
- Decouple sensors from backend
- Absorb temporary backend restarts

---

### Core Service

Single logical service responsible for:

- MQTT ingestion
- Data validation
- Persistence (SQLite)
- Web UI (Phoenix)
- Admin actions
- Background jobs (future)

Design decisions:
- Single writer to DB
- No external dependencies
- Restartable without coordination

Runs as:
- systemd service
- Dedicated user (`alona`)
- Journald logging

---

### Database (SQLite)

Chosen because:
- Zero operational overhead
- File-based
- Easy backup/restore
- Sufficient for single-writer workloads

Assumptions:
- One writer (core)
- Low write concurrency
- WAL mode enabled

Backups:
- Daily full copy
- WAL included
- Restore via systemd-safe procedure

---

## Networking Model

- LAN-only
- No internet exposure
- No cloud dependencies

Access patterns:
- ESP32 → MQTT (LAN)
- Browser → Core UI (LAN)
- SSH → Pi (LAN or VPN)

---

## Operational Model

### Startup Order

1. Network online
2. Mosquitto
3. Core service
4. Timers (backup, health)

systemd enforces dependencies.

---

### Logging

- All services log to journald
- Persistent storage enabled
- Disk usage capped

No log files, no logrotate.

---

### Monitoring

- Lightweight healthcheck
- systemd timer
- Journald output
- State files for quick inspection

No metrics stack, no dashboards.

---

### Backups

- Daily systemd timer
- SQLite + configs
- Local-first storage
- Retention-based cleanup

Backups are the primary safety mechanism.

---

## Failure Domains

| Failure | Impact | Recovery |
|-------|--------|----------|
| ESP32 node | Partial data loss | Auto-reconnect |
| Core crash | Temporary ingest stop | systemd restart |
| Mosquitto crash | No ingest | systemd restart |
| Disk full | System degradation | Manual cleanup |
| Disk failure | Total loss | Reinstall + restore |

---

## Non-Goals

Explicitly avoided:
- Multi-node clusters
- Cloud services
- Time-series databases
- Auto-scaling
- Internet exposure
- Complex monitoring stacks

These increase fragility without benefit in this context.

---

## Philosophy

> “If it breaks, it should break **small**, **locally**, and **recoverably**.”

This architecture optimizes for:
- Clarity
- Predictability
- Field recovery

Not for:
- Scale
- Multi-tenancy
- Enterprise compliance
