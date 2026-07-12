# the-algovn/iac

IaC + GitOps source of truth for the `algovn` k3s cluster (Raspberry Pi 5).

- **Spec**: docs/superpowers/specs/2026-07-11-k3s-gitops-cluster-design.md
- **Layers**: `ansible/` (node) → `bootstrap/` (one-time Argo CD) → `clusters/` + `platform/` + `apps/` (GitOps, Argo-managed)
- **Runbooks**: docs/runbooks/
- **Rule**: no plaintext secrets, ever — SealedSecrets only. `scripts/validate.sh` before every push.

## Status
Cluster live. Acceptance: docs/runbooks/verify.md — all green on 2026-07-12 (Telegram alerting skipped by decision; Renovate installation pending).
Kong gateway + gRPC conventions live — 2026-07-12, spec docs/superpowers/specs/2026-07-12-kong-gateway-grpc-conventions-design.md.
Shared Postgres live (CloudNativePG 1.30.0, PG 18) — 2026-07-12, runbook docs/runbooks/postgres.md.
