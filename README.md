# the-algovn/iac

IaC + GitOps source of truth for the `algovn` k3s cluster — Raspberry Pi 5 control plane + a powerful x86 worker (i9, 32 GB RAM).

- **Architecture**: the-algovn/specs `ARCHITECTURE.md`
- **Layers**: `ansible/` (node) → `bootstrap/` (one-time Argo CD) → `clusters/` + `platform/` + `apps/` (GitOps, Argo-managed)
- **Runbooks**: docs/runbooks/
- **Rule**: no plaintext secrets, ever — SealedSecrets only. `scripts/validate.sh` before every push.

## Status
Cluster live. Acceptance: docs/runbooks/verify.md — all green on 2026-07-12 (Telegram alerting skipped by decision; Renovate installation pending).
Kong gateway + gRPC conventions live — 2026-07-12, conventions docs/grpc-conventions.md.
Shared Postgres live (CloudNativePG 1.30.0, PG 18) — 2026-07-12, runbook docs/runbooks/postgres.md.
Remote access (ssh + kubectl) via cloudflared host tunnels — 2026-07-13, see docs/runbooks/remote-access.md; Access gate pending.
AuthN/Z foundation live (Zitadel chart 9.34.0 @ id.algovn.com + OpenFGA 0.3.10, Kong jwt edge gate) — 2026-07-13, conventions docs/authnz-conventions.md. pg backups deliberately descoped (postgres.md warning stands); barman-cloud plugin installed but unconfigured.
api.algovn.com gateway live (api-control-plane + RabbitMQ events bus + demo-service tenant) — 2026-07-14, conventions docs/api-conventions.md, runbook docs/runbooks/api-control-plane.md.
