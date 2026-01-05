# Alona IoT — Infrastructure

Deployment and operational setup for **Alona IoT** running on a Raspberry Pi.

This repository contains everything needed to keep the system running reliably in an off-grid environment, including:

- MQTT broker configuration
- database setup
- service definitions
- backup and maintenance scripts

The focus is on simplicity, recoverability, and minimal manual intervention.

## Responsibilities

- Local deployment on Raspberry Pi
- Service orchestration (systemd and/or containers)
- Configuration management
- Backup and restore procedures

## Design Principles

- Fail and recover automatically
- Keep the number of moving parts low

## Related Repositories

- `core` — application services
- `docs` — architecture and failure scenarios
