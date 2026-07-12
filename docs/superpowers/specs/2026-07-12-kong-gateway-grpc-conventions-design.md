# Kong Gateway + Internal gRPC Conventions — Design

**Date:** 2026-07-12
**Status:** Approved (brainstorm dialogue)
**Depends on:** `2026-07-11-k3s-gitops-cluster-design.md` (cluster live per README Status)

## 1. Goal

Replace Traefik with Kong OSS as the single gateway for the `algovn` cluster, giving every
public route centralized API-key/JWT auth, rate limiting, and Kong's plugin ecosystem —
and establish internal gRPC conventions (contracts, discovery, health, metrics) so future
services snap in without design work. No gRPC workloads are deployed by this project.

## 2. Decisions (from brainstorm Q&A)

| Question | Decision |
|---|---|
| Kong's jobs | API auth (keys/JWT), rate limiting/quotas, general routing + plugin platform. NOT gRPC north-south (internal only). |
| Traefik fate | Kong fully replaces the k3s built-in Traefik. |
| gRPC scope | Conventions + template only; no concrete services yet. |
| Auth model | Validate-only (key-auth now, jwt when an issuer exists). Kong stays DB-less; no Postgres, no OAuth2-provider role. |
| Deployment shape | Kong Ingress Controller (KIC) + Kong OSS DB-less via official Helm chart, GitOps/Argo like every platform component. Standard k8s Ingress objects remain the routing source of truth (keeps external-dns untouched). |

## 3. Target architecture

```
Internet ── CF edge ── algovn-k8s tunnel ─▶ kong-proxy ─▶ ClusterIP Services
LAN ─────────────── node IP :80/:443 (svclb) ─▶ kong-proxy ─▶ ClusterIP Services
Internal gRPC: pod ─▶ <svc>.<ns>.svc.cluster.local:9090 (h2c, never via Kong)
```

- `platform/kong/` (values + CRD manifests) + `clusters/algovn/platform/kong.yaml`
  Application, sync-wave **-3** (Traefik's old slot). Chart pinned at plan time.
- Existing Ingresses (grafana, homepage, uptime-kuma, argocd) change only
  `ingressClassName: traefik` → `kong`. external-dns/tunnel DNS automation unchanged.
- **Default TLS**: new cert-manager `Certificate` in the `kong` namespace (ClusterIssuer
  `letsencrypt-dns`, same SANs `algovn.com`/`*.algovn.com`) wired as Kong's default
  certificate. LAN clients keep the real wildcard cert. The kube-system Certificate and
  Traefik TLSStore are removed with Traefik.
- Kong admin API stays cluster-internal (KIC-only access); Kong Manager UI disabled.

## 4. Cutover sequence (public path gapless; rollback = one revert at any step)

1. Deploy Kong with proxy Service as **ClusterIP**. Traefik untouched; both proxies run.
2. Add **kong-class twin Ingresses** (`<name>-kong`, same host/backend) for the four
   hosts. Both controllers now route their own class; external-dns sees identical
   host→target pairs (no DNS change). Verify Kong serves every host correctly via its
   ClusterIP with `Host:` headers — before any public traffic moves.
3. Flip cloudflared ConfigMap target `traefik.kube-system` → `kong-proxy.kong`.
   Public traffic now flows through Kong, which already routes all hosts (no gap).
   Verify all four public hosts + CF Access challenge. Rollback: revert this line.
4. Flip the original four Ingresses to `ingressClassName: kong`, then delete the twins
   (Kong tolerates the transient duplicate routes; canonical names are preserved).
5. Once green: Ansible `k3s_server` config adds `disable: [traefik]` (k3s restart);
   delete `platform/traefik/` + its Application from git (Argo prunes); switch Kong proxy
   Service to LoadBalancer to claim node 80/443 via svclb (brief LAN-only gap; the tunnel
   path is unaffected). Update runbooks + verify.md references (traefik → kong).

## 5. Kong configuration conventions

- **Plugins bind via annotation** `konghq.com/plugins: <names>` on the Ingress/Service they
  guard — routing and protection live in the same file.
- **Auth**: `key-auth` KongPlugin per protected route; `KongConsumer` CRDs per client;
  API keys as SealedSecrets labeled `konghq.com/credential: key-auth`. `jwt` plugin
  config documented, deployed only when a token issuer exists.
- **Rate limiting**: `rate-limiting` plugin, `policy: local` (single node; no Redis/DB).
- **Observability**: `prometheus` KongClusterPlugin + VMServiceScrape (same pattern as
  argocd/cert-manager scrapes); access logs reach Loki via existing Alloy pod collection;
  Kong Grafana dashboard added to dashboard provisioning.
- **Resources**: proxy `requests cpu 100m / mem 256Mi, limit 512Mi`; controller
  `requests cpu 50m / mem 128Mi, limit 256Mi`. Net vs. freed Traefik ≈ **+200–250Mi**
  (headroom after: ~450–500Mi). Pressure valves if needed: disable VM defaultDashboards,
  trim vmsingle limits.

## 6. Internal gRPC conventions (docs + template only)

- **Contracts**: dedicated repo `the-algovn/protos`, managed with **buf**;
  CI gates `buf lint` + `buf breaking` (against main); generated Go committed/published
  from the same repo as a Go module (`gen/go/...`) — services `go get` contracts.
- **Service shape**: container port **9090, named `grpc`**; plaintext h2c in-cluster
  (accepted risk while single-node; mTLS/mesh is a multi-node trigger, see §8).
- **Discovery/LB**: headless Service; grpc-go DNS resolver + `round_robin` service config.
  Single replica today; multi-replica needs no client change.
- **Health**: implement `grpc_health_v1`; use k8s-native gRPC liveness/readiness probes.
- **Client discipline**: every call carries a deadline; retries only via service config on
  idempotent methods; documented keepalive parameters both sides.
- **Metrics**: Prometheus server/client interceptors, `/metrics` on port 9091 (named
  `metrics`) + VMServiceScrape per service. Tracing deferred — no backend fits the RAM.
- **Template**: `templates/grpc-service/` manifest skeleton (Deployment with gRPC probes,
  headless Service, VMServiceScrape) + a gRPC section in `templates/README.md`.
  Future note only: Kong can proxy gRPC/gRPC-Web if a service ever goes public.

## 7. Verification criteria

1. All four public hosts serve through Kong (tunnel target flipped): homepage 200,
   uptime 302/200, argocd + grafana 302 CF-Access challenge.
2. LAN: `curl --resolve x.algovn.com:443:<node-ip>` → Kong 404 with valid LE wildcard cert.
3. A protected demo route returns 401 without key, 200 with key; rate limit returns 429
   past threshold (throwaway Ingress + KongPlugin, removed after, mirroring the Task 10
   e2e pattern).
4. `kubectl get pods -A` has no traefik/svclb-traefik pods; kong-proxy owns node 80/443.
5. Kong metrics visible in VictoriaMetrics; access logs queryable in Loki.
6. All Argo apps Synced/Healthy; `free -h` available ≥ 400Mi.
7. `templates/grpc-service/` passes `scripts/validate.sh` (kustomize + kubeconform).

## 8. Explicitly deferred (with triggers)

| Deferred | Trigger to revisit |
|---|---|
| Service mesh / internal mTLS | Second node joins, or compliance need |
| Kong + Postgres / OAuth2-provider | A real need for Kong-issued tokens (prefer dedicated IdP even then) |
| Gateway API resources | KIC deprecates Ingress path, or multi-gateway need |
| Tracing backend (Tempo/Jaeger) | RAM budget grows (bigger node) + a debugging need metrics/logs can't cover |
| gRPC public exposure / transcoding | First external gRPC consumer |
| Schema registry beyond buf | Cross-org proto consumers |
