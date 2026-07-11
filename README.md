# the-algovn/iac

IaC + GitOps source of truth for the `algovn` k3s cluster (Raspberry Pi 5).

- **Spec**: docs/superpowers/specs/2026-07-11-k3s-gitops-cluster-design.md
- **Layers**: `ansible/` (node) → `bootstrap/` (one-time Argo CD) → `clusters/` + `platform/` + `apps/` (GitOps, Argo-managed)
- **Runbooks**: docs/runbooks/
- **Rule**: no plaintext secrets, ever — SealedSecrets only. `scripts/validate.sh` before every push.
