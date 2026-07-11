# k3s GitOps Cluster — Design

- **Date**: 2026-07-11
- **Status**: Approved (brainstorm validated section-by-section)
- **Repo**: `github.com/the-algovn/iac` (public — see Secrets)

## 1. Context & goals

Build a fully IaC-managed, GitOps-driven k3s cluster on the Raspberry Pi 5 `algovn`
(4-core Cortex-A76, 4GB RAM, 459GB NVMe, Ubuntu 25.10, LAN `192.168.102.202`).
k3s is installed but inactive with stale state; treat as a fresh install.

The cluster serves four purposes, in tension with the 4GB RAM budget:

1. Production-ish public services on `algovn.com` (real TLS, uptime expectations)
2. Homelab self-hosted services
3. Deployment target for personal apps (`gn3`, `just-an-counter`) — **later**, via a
   reusable CI/CD template delivered now
4. Learning platform for standard Kubernetes + GitOps patterns

**Success means**: cluster state is 100% reproducible from this repo plus one backed-up
key; a change merged to `main` reaches the cluster without manual steps; a new service
is one folder + one Application file; the whole platform fits in ~2.6GB leaving ≥1GB
for workloads.

## 2. Decision log

| Decision | Choice | Rationale / accepted trade-off |
|---|---|---|
| Topology | Single node now, multi-node soon | Inventory-driven Ansible makes joining a node a 1-line change |
| GitOps engine | **Argo CD** (slim install) | UI chosen for learning value, accepting ~0.7GB vs Flux's ~0.25GB; dex + notifications disabled, single replicas |
| Secrets | **Sealed Secrets** | Argo-native, no plugin maintenance; sealing key backup is mandatory (vs SOPS: better Argo fit, worse offline editing) |
| Exposure | **Cloudflare Tunnel** only | Works behind VNPT CGNAT, no open ports, home IP hidden; HTTP(S) services only |
| Domain | `algovn.com` | Verified on Cloudflare (leo/nova NS, already proxied) |
| Monitoring flavor | **VictoriaMetrics** stack | Prometheus-compatible at ~half the RAM; needed because Argo CD took the budget |
| Node provisioning | **Ansible** | Idempotent, inventory-driven; the "multi-node soon" enabler |
| PV data backups | **Descoped** (user decision) | GitOps rebuilds cluster state; only Loki history + uptime-kuma stats at risk. Revisit trigger: first stateful app |
| App CI/CD | Template + machinery now, apps later | argocd-image-updater deployed idle; workflow template in `templates/` |

## 3. Architecture

```
                 ┌─ GitHub ─────────────────────────────┐
                 │ the-algovn/iac    (source of truth)  │
                 │ Renovate PRs ─▶ CI gates ─▶ main     │
                 └───────────────┬──────────────────────┘
                        pull/sync│
Internet ─▶ Cloudflare edge     ▼
  (TLS)       │           ┌─ algovn (Pi 5, k3s) ──────────────┐
              │ tunnel    │ Argo CD ── manages ─▶ everything  │
              └─────────▶ │ cloudflared ▶ Traefik ▶ Services  │
               (outbound  │ VictoriaMetrics · Grafana · Loki  │
                only)     │ cert-manager · sealed-secrets     │
                          │ external-dns · image-updater      │
                          └───────────────────────────────────┘
```

Three layers, strictly ordered:

- **Layer 0 — nodes (Ansible)**: OS prep, hardening, zram swap, k3s install/join.
  Run from a workstation or the Pi itself; idempotent.
- **Layer 1 — bootstrap (one-time per cluster)**: install pinned Argo CD, apply the
  root Application. Never repeated except on rebuild.
- **Layer 2 — everything else (Argo CD)**: platform and workloads reconcile from git.
  Argo CD manages its own config from `platform/argocd/` after bootstrap.

### RAM budget (4GB node, ~3.8GB usable)

| Component | Budget |
|---|---|
| k3s server (sqlite datastore) | ~0.6GB |
| Argo CD (slim: no dex, no notifications, single replicas) + image-updater | ~0.75GB |
| VictoriaMetrics + vmagent + vmalert + Alertmanager + Grafana | ~0.5GB |
| Loki (single-binary) + Alloy | ~0.4GB |
| Traefik, cloudflared, cert-manager, external-dns, sealed-secrets | ~0.4GB |
| **Platform total** | **~2.6GB** |
| **Free for workloads** | **~1.1GB** |

Every component declares resource requests/limits. zram swap (Ansible-configured) is
the pressure valve. Budget relaxes when a second node joins.

## 4. Repository layout

```
iac/
├── ansible/                  # Layer 0
│   ├── inventory.yml         # nodes + roles (server/agent) + per-node vars
│   ├── site.yml
│   └── roles/                # base, zram, k3s-server, k3s-agent
├── bootstrap/                # Layer 1: pinned Argo CD install + root Application
├── clusters/
│   └── algovn/               # Layer 2 entrypoint (app-of-apps)
│       ├── platform/         # one Application per platform component (sync-waved)
│       └── apps/             # one Application per workload
├── platform/                 # component config: helm values, kustomize, manifests
│   ├── argocd/  ├── cloudflared/  ├── cert-manager/  ├── external-dns/
│   ├── sealed-secrets/  ├── traefik/  ├── monitoring/  ├── logging/
│   └── image-updater/
├── apps/                     # workload manifests
│   ├── homepage/
│   └── uptime-kuma/
├── templates/                # reusable app CI/CD (GitHub Actions workflow + docs)
├── docs/
│   ├── runbooks/             # bootstrap, rebuild, add-node, add-app, verify
│   └── superpowers/specs/    # this document
└── .github/workflows/        # repo CI: validate, lint, secret-scan
```

Adding a workload = folder in `apps/` + Application file in `clusters/algovn/apps/`.
Adding a cluster = new folder under `clusters/`.

## 5. Node provisioning (Layer 0)

Ansible playbook, inventory-driven. Roles: `base` (packages, unattended-upgrades,
sysctl), `zram`, `k3s-server` (config file from git: keep Traefik and servicelb —
servicelb exposes Traefik on the node IP for LAN-fallback access per §7; sqlite
datastore), `k3s-agent` (join via server URL + token). Adding a
node = one inventory line + `ansible-playbook site.yml`. HA control plane (etcd
migration) is documented as a future path, not built now.

## 6. GitOps structure (Layer 2)

- **Root app-of-apps** at `clusters/algovn/` spawns per-component Applications.
- **Sync waves** order platform bring-up: sealed-secrets → cert-manager →
  traefik config → cloudflared + external-dns → monitoring → logging →
  argocd (self) → image-updater → apps.
- **Sync policy**: automated + self-heal + prune on everything. Drift is reverted and
  visible in the UI; sync history is the audit log.
- Argo CD web UI at `argocd.algovn.com` behind Cloudflare Access.

## 7. Networking & exposure

- Single path for all name-based traffic, public and admin:
  `<service>.algovn.com → CF edge (TLS) → tunnel → Traefik → Ingress → Service`.
- **cloudflared** Deployment, locally-managed tunnel: config file in git, credentials
  as a SealedSecret. Outbound-only; no router changes.
- **external-dns** (Cloudflare provider, API token sealed) watches Ingresses and
  manages per-hostname CNAMEs to `<tunnel-id>.cfargotunnel.com`. Publishing a service
  is purely declarative.
- **Cloudflare Access** (free tier) in front of admin hostnames (`argocd.`,
  `grafana.`): SSO challenge at the edge. Configured manually once, captured as a
  runbook with screenshots-level detail (deliberately not Terraformed — 2 hostnames).
- **cert-manager** issues a wildcard `*.algovn.com` via DNS-01 for Traefik's default
  cert: real TLS on LAN/fallback access (internet outage ≠ locked out; point local
  DNS at the Pi). Public-path TLS terminates at Cloudflare.

## 8. Secrets (public repo — zero tolerance)

- **Sealed Secrets** controller; only `SealedSecret` CRs are committed. Plaintext
  Secrets never touch git.
- **Root of trust**: the sealing private key. Exported once post-install to the
  user's password manager. Rebuild = restore key → all sealed secrets decrypt.
- Day-one secrets: Cloudflare API token (external-dns, cert-manager), tunnel
  credentials, Grafana admin, Argo CD admin (bcrypt hash).
- **Guardrails**: gitleaks in CI and as pre-commit hook; `.gitignore` patterns for
  common secret filenames; runbook for sealing a new secret.

## 9. Observability

- **Metrics**: VictoriaMetrics single-node + vmagent scraping k3s, Traefik, Argo CD,
  node-exporter, kube-state-metrics. 15d retention on local-path PV.
- **Dashboards**: Grafana, provisioned from git (node health, Argo sync status,
  Traefik traffic, namespace resources). At `grafana.algovn.com` behind CF Access.
- **Logs**: Loki single-binary (filesystem storage, 7-day retention) + Alloy
  DaemonSet shipping container + systemd-journal logs. Queried in Grafana.
- **Alerts**: vmalert + Alertmanager. Short list: node down, disk pressure,
  crashloop, cert expiring, Argo app degraded/out-of-sync. One receiver —
  default Telegram bot (token sealed); swapping channel = one receiver block.

## 10. CI/CD

- **Repo CI** (GitHub Actions, free on public repo), required to merge:
  kubeconform schema validation of rendered manifests, `helm template` lint,
  `kustomize build` check, gitleaks scan. `main` is what the cluster runs, so CI is
  the immune system.
- **Renovate** GitHub App: PRs for Helm charts, images, Argo CD, Ansible collections.
  Patch/minor grouped weekly; majors individual with changelogs. Merge = deploy.
- **App template** in `templates/`: reusable GitHub Actions workflow — buildx
  linux/arm64 → GHCR, SemVer + SHA tags — plus an annotated example Application for
  **argocd-image-updater** (deployed now, idle, git write-back strategy). Onboarding
  an app later: copy workflow, add Application, done. No new platform work.

## 11. Seed workloads (prove the pattern with public images)

- **homepage**: service dashboard, auto-discovers via Ingress annotations.
- **uptime-kuma**: uptime checks against the public endpoints (also serves as
  continuous post-deploy verification).

Each exercises the full path: `apps/` folder → Ingress → auto-DNS → tunnel → TLS →
scraped → logged. Combined budget ~150MB.

## 12. Failure recovery

**Rebuild runbook** (`docs/runbooks/rebuild.md`), target under one hour:

1. Flash Ubuntu, set hostname/IP
2. `ansible-playbook site.yml`
3. Apply `bootstrap/` (Argo CD + root app)
4. Restore sealing key from password manager
5. Wait for sync waves to converge; run verify runbook

Out of band: CF Access re-check (manual runbook). Lost on rebuild (accepted): Loki
history, uptime-kuma stats, metrics history.

## 13. Deferred — with re-entry triggers

| Item | Trigger to revisit |
|---|---|
| PV data backups (restic → Cloudflare R2) | Before first stateful app (database) ships |
| Longhorn / distributed storage | At 2-3 nodes |
| HA control plane (etcd) | When a second *server* node is wanted |
| Terraform for Cloudflare Access/DNS zone | If Access policies grow past a handful |
| Onboarding gn3 / just-an-counter | When user decides; template is ready |

## 14. Verification

- **Every PR**: CI gates (kubeconform, helm lint, kustomize build, gitleaks).
- **Post-bootstrap / post-change** (`docs/runbooks/verify.md`): all Applications
  Healthy + Synced; `curl -I https://homepage.algovn.com` from outside succeeds with
  CF TLS; Grafana shows node + Argo dashboards with live data; Loki returns logs for
  a platform pod; test alert reaches Telegram; **drift test** — hand-edit a
  deployment replica count, confirm Argo reverts it within one reconcile cycle.
- **Continuous**: uptime-kuma monitors the public endpoints.

## 15. Out of scope

- Backups of persistent volume data (see Deferred)
- Deploying gn3 / just-an-counter themselves (template only)
- Multi-cluster, HA, distributed storage
- Non-HTTP protocols through the tunnel (TCP passthrough via `cloudflared access`
  exists but is not designed for here)
