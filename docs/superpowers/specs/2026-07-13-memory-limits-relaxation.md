# Memory-limit relaxation (post-w1) — Micro-design

**Date:** 2026-07-13 · **Status:** Approved (user: "we have plenty of ram")
**Context:** Limits were sized for the single 4GB Pi (k3s spec §3). With `w1`
(30Gi allocatable, 15% used) in the cluster, the busiest components get 2×
headroom. **Limits only — requests unchanged** (no scheduling-pressure change;
a fat-limit pod landing on the Pi remains the known trade-off, accepted).

| Component | File | Limit before → after |
|---|---|---|
| vmsingle | platform/monitoring/values.yaml | 2Gi → 4Gi |
| vmagent | platform/monitoring/values.yaml | 512Mi → 1Gi |
| grafana | platform/monitoring/values.yaml | 256Mi → 512Mi |
| kong gateway | platform/kong/values.yaml | 512Mi → 1Gi |
| postgres `pg` | platform/postgres/manifests/cluster.yaml | 1Gi → 2Gi (rolling restart) |
| zitadel | platform/zitadel/values.yaml | 512Mi → 1Gi (+ GOMEMLIMIT 450MiB → 900MiB) |
| argocd application-controller | platform/argocd/patches/slim.yaml | 512Mi → 1536Mi (OOM incident — CrashLoopBackOff x16 at 20-app scale) |
| loki | platform/logging/loki-values.yaml | 512Mi → 1Gi |

Out of scope: everything idle-and-far-from-limit (argocd stack except the application-controller — OOM incident, see table; cert-manager,
controllers, openfga, alloy, login pod); nodeSelector policy. Verify: apps
Synced/Healthy, pods restart clean, Pi stays ≥250Mi available.
