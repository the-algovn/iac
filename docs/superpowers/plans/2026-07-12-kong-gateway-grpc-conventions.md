# Kong Gateway + gRPC Conventions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kong OSS (DB-less, KIC) replaces Traefik as the single gateway with key-auth + rate limiting, and gRPC conventions (buf protos repo, service template, docs) are in place — per `docs/superpowers/specs/2026-07-12-kong-gateway-grpc-conventions-design.md`.

**Architecture:** Deploy Kong side-by-side with proxy as ClusterIP → prove routing with twin Ingresses via Host-header curls → flip the tunnel (one-line rollback) → make Kong canonical → remove Traefik and give Kong the node's 80/443. gRPC ships as conventions only: a buf-managed protos repo, a manifest template, and a conventions doc.

**Tech Stack:** Kong OSS 3.x via `kong/ingress` Helm chart (KIC + gateway, DB-less), cert-manager, Argo CD, sealed-secrets, VictoriaMetrics (VMPodScrape), buf.

## Global Constraints

- **Execution model**: author/commit/push from the Mac (`/Users/duclm27/iac`); run server commands via `ssh ducle@192.168.102.200 'bash -c "..."'` (remote login shell is not bash). Always `export KUBECONFIG=$HOME/.kube/config` on the Pi before kubectl/argocd.
- **Argo CLI**: always `--core` (`argocd app wait kong --core --timeout 300`). After each push: `argocd app get root --core --refresh` to skip the 3-min poll.
- **Pushes**: direct to main (admin bypass of branch protection) — this plan is an operational cutover needing fast rollback; CI still validates every push. `scripts/validate.sh` MUST pass before every push.
- **Never touch** the production tunnel `algovn` (id 15675449-…), the host `cloudflared.service`, or DNS records `algovn.com`, `portainer.`, `ssh.`, `the-button-api.`, `the-song-api.algovn.com`. The cluster tunnel is `algovn-k8s` (cb033e8e-8bae-42b0-b0f7-858d35daec9c).
- **Pinned versions**: discovery commands print the value to use — never write `latest` into git. Chart-value schemas MUST be verified with a local `helm template` render-check before committing (pattern that caught 3 drifts on 2026-07-12).
- **RAM discipline**: every container declares requests + limits. Kong proxy `100m/256Mi lim 512Mi`, controller `50m/128Mi lim 256Mi`. Abort criterion: if `free -h` available drops below 300Mi at any verify step, stop and consult the spec's pressure valves.
- **Secrets**: SealedSecrets only in git, `*-sealed.yaml` naming (gitleaks allowlist depends on it). Transient plaintext under `~/.secrets/` on the Pi, `shred -u` after.
- **arm64 only**; sync-wave slots: kong `-3` (Traefik's old slot).
- **`[NEEDS USER]`**: only Task 7 step 1 (merge decision if PR flow is chosen for the protos repo — otherwise none; Cloudflare/password-manager items do not appear in this plan).

---

### Task 1: Deploy Kong (DB-less, KIC, ClusterIP) with default wildcard TLS

**Files:**
- Create: `platform/kong/values.yaml`, `platform/kong/manifests/certificate.yaml`, `platform/kong/manifests/kustomization.yaml`
- Create: `clusters/algovn/platform/kong.yaml`

**Interfaces:**
- Consumes: ClusterIssuer `letsencrypt-dns` (existing), Argo root app pattern.
- Produces: namespace `kong`; proxy Service `kong-gateway-proxy` (ClusterIP, ports 80/443); IngressClass `kong`; secret `wildcard-algovn-tls` in ns `kong` as Kong's default cert. Later tasks depend on the exact Service name printed in step 4.

- [ ] **Step 1: Pin chart version**

```bash
helm repo add kong https://charts.konghq.com && helm repo update kong
helm search repo kong/ingress --versions | head -3
```

Expected like `kong/ingress  0.19.0  3.9.x` (example — substitute the printed chart version everywhere `0.19.0` appears below).

- [ ] **Step 2: Write manifests**

`platform/kong/manifests/certificate.yaml`:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-algovn
  namespace: kong
spec:
  secretName: wildcard-algovn-tls
  issuerRef: { name: letsencrypt-dns, kind: ClusterIssuer }
  dnsNames: ["algovn.com", "*.algovn.com"]
```

`platform/kong/manifests/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - certificate.yaml
```

`platform/kong/values.yaml`:
```yaml
controller:
  ingressController:
    ingressClass: kong
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits: { memory: 256Mi }
gateway:
  image:
    repository: kong
  replicaCount: 1
  proxy:
    type: ClusterIP        # flipped to LoadBalancer in Task 6 after Traefik is gone
  admin:
    enabled: false          # no external admin Service; the umbrella chart wires KIC's admin connection internally
  manager:
    enabled: false
  secretVolumes:
    - wildcard-algovn-tls
  env:
    database: "off"
    ssl_cert: /etc/secrets/wildcard-algovn-tls/tls.crt
    ssl_cert_key: /etc/secrets/wildcard-algovn-tls/tls.key
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { memory: 512Mi }
```

Note: `admin.enabled: false` disables the external admin Service only — verify in the render-check that the controller still gets its admin connection (the umbrella chart wires it internally). If the render shows the controller lacking admin access, set `gateway.admin.enabled: true` with `type: ClusterIP` instead and re-render.

`clusters/algovn/platform/kong.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kong
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  project: default
  sources:
    - repoURL: https://charts.konghq.com
      chart: ingress
      targetRevision: 0.19.0
      helm:
        releaseName: kong
        valueFiles:
          - $values/platform/kong/values.yaml
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      ref: values
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      path: platform/kong/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: kong
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
```

- [ ] **Step 3: Render-check the chart against these values (BEFORE committing)**

```bash
helm template kong kong/ingress --version 0.19.0 -n kong -f platform/kong/values.yaml > /tmp/kong-render.yaml
grep -E "kind: (Deployment|Service|IngressClass)" /tmp/kong-render.yaml | sort | uniq -c
grep -B3 -A1 "name: proxy" /tmp/kong-render.yaml | head -12   # confirm proxy Service name + ClusterIP
grep -E "ssl_cert|secretVolumes|wildcard" /tmp/kong-render.yaml | head -6
grep -A2 "ingressClass" /tmp/kong-render.yaml | head -6
```

Expected: exactly one proxy Service, `type: ClusterIP`; env `KONG_SSL_CERT=/etc/secrets/wildcard-algovn-tls/tls.crt`; IngressClass `kong`. **Record the proxy Service name** (expected `kong-gateway-proxy`) — used in Tasks 2/4/6. If any value key errored or is silently ignored, fix the values to the chart's actual schema before proceeding (check `helm show values kong/ingress --version 0.19.0`).

- [ ] **Step 4: Validate, push, deploy, verify**

```bash
scripts/validate.sh && git add platform/kong clusters/algovn/platform/kong.yaml && git commit -m "feat(platform): kong gateway (db-less, kic, clusterip)" && git push
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=$HOME/.kube/config; argocd app get root --core --refresh >/dev/null; sleep 8; argocd app wait kong --core --timeout 420 2>&1 | tail -3; kubectl -n kong get pods,svc,certificate"'
```

Expected: kong controller + gateway pods Running (gateway may restart once while the Certificate issues — the secret mount gates it); `certificate/wildcard-algovn` Ready; proxy Service ClusterIP with ports 80/443. Traefik still untouched and serving all public traffic.

- [ ] **Step 5: Prove Kong answers with the real wildcard cert**

```bash
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=$HOME/.kube/config; IP=$(kubectl -n kong get svc kong-gateway-proxy -o jsonpath={.spec.clusterIP}); curl -sv --resolve nosuch.algovn.com:443:$IP https://nosuch.algovn.com/ -o /dev/null 2>&1 | grep -E \"subject:|issuer:|HTTP\""'
```

Expected: `subject: CN=algovn.com`, `issuer: … Let's Encrypt`, and an HTTP 404 (Kong's no-route response) — real cert, no `-k`.

---

### Task 2: Kong observability (prometheus plugin, scrape, logs, dashboard)

**Files:**
- Create: `platform/kong/manifests/prometheus-plugin.yaml`, `platform/kong/manifests/podscrape.yaml`
- Create: `platform/monitoring/manifests/kong-dashboard-cm.yaml`
- Modify: `platform/kong/manifests/kustomization.yaml`, `platform/monitoring/manifests/kustomization.yaml`

**Interfaces:**
- Consumes: Kong pods (Task 1), VM operator CRDs, Grafana dashboard sidecar (labels `grafana_dashboard: "1"`).
- Produces: metric `kong_http_requests_total` (or `kong_http_status` per Kong version) in VictoriaMetrics; Grafana dashboard "Kong (official)".

- [ ] **Step 1: Discover the status port name on the running pod**

```bash
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=$HOME/.kube/config; kubectl -n kong get pod -l app.kubernetes.io/component=app -o jsonpath=\"{.items[0].spec.containers[*].ports}\" | tr , \"\n\" | grep -A2 -B2 status"'
```

Expected: a containerPort (default `8100`) named `status` (or `cmetrics`). Use the printed name in `podscrape.yaml` below.

- [ ] **Step 2: Write plugin + scrape manifests**

`platform/kong/manifests/prometheus-plugin.yaml`:
```yaml
apiVersion: configuration.konghq.com/v1
kind: KongClusterPlugin
metadata:
  name: prometheus
  annotations:
    kubernetes.io/ingress.class: kong
  labels:
    global: "true"
plugin: prometheus
config:
  status_code_metrics: true
  latency_metrics: true
  bandwidth_metrics: true
  upstream_health_metrics: true
```

`platform/kong/manifests/podscrape.yaml` (port name from step 1):
```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMPodScrape
metadata:
  name: kong
  namespace: monitoring
spec:
  namespaceSelector: { matchNames: [kong] }
  selector:
    matchLabels: { app.kubernetes.io/component: app }
  podMetricsEndpoints:
    - port: status
      path: /metrics
```

Append both to `platform/kong/manifests/kustomization.yaml` resources:
```yaml
  - prometheus-plugin.yaml
  - podscrape.yaml
```

- [ ] **Step 3: Fetch the official Kong dashboard into the monitoring config**

```bash
curl -sL "https://grafana.com/api/dashboards/7424/revisions/latest/download" -o /tmp/kong-dashboard.json
python3 -c "import json;json.load(open('/tmp/kong-dashboard.json'))" && echo json-ok
```

`platform/monitoring/manifests/kong-dashboard-cm.yaml` — wrap the JSON (paste the file content under `kong.json: |`, indented; generate with the command below rather than hand-editing):
```bash
ssh_placeholder=""  # (runs on the Mac)
{
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: kong-dashboard\n  namespace: monitoring\n  labels:\n    grafana_dashboard: "1"\ndata:\n  kong.json: |\n'
  sed 's/^/    /' /tmp/kong-dashboard.json
} > platform/monitoring/manifests/kong-dashboard-cm.yaml
```

Append `- kong-dashboard-cm.yaml` to `platform/monitoring/manifests/kustomization.yaml` resources.

- [ ] **Step 4: Validate, push, verify metrics + logs + dashboard**

```bash
scripts/validate.sh && git add platform/kong/manifests platform/monitoring/manifests && git commit -m "feat(kong): prometheus plugin, vm scrape, grafana dashboard" && git push
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=$HOME/.kube/config; argocd app get root --core --refresh >/dev/null; sleep 8; argocd app wait kong monitoring-config --core --timeout 300 >/dev/null 2>&1; sleep 90; VMIP=$(kubectl -n monitoring get svc vmsingle-vm -o jsonpath={.spec.clusterIP}); curl -s \"http://$VMIP:8429/api/v1/query?query=count({job=~\\\".*kong.*\\\"})\" | head -c 300"'
```

Expected: a non-empty result (>0 series with a kong job label). Then confirm logs: Grafana → Explore → Loki `{namespace="kong"}` returns lines (or the curl equivalent against the loki ClusterIP used in the 2026-07-11 plan Task 13 §4). Dashboard "Kong (official)" appears in Grafana.

---

### Task 3: Twin Ingresses + full Kong routing proof (no public traffic moved)

**Files:**
- Create: `platform/monitoring/manifests/grafana-ingress-kong.yaml`, `apps/homepage/ingress-kong.yaml`, `apps/uptime-kuma/ingress-kong.yaml`, `platform/argocd/ingress-kong.yaml`
- Modify: the four adjacent `kustomization.yaml` files (add the twin)

**Interfaces:**
- Consumes: IngressClass `kong` (Task 1), proxy Service name (Task 1 step 3).
- Produces: Kong routes for all four hosts, verified before the tunnel flip (Task 4).

- [ ] **Step 1: Write the four twins**

Each twin is the existing Ingress with two changes: `metadata.name` gets `-kong` suffix, `ingressClassName: kong`. Example — `apps/homepage/ingress-kong.yaml` (repeat the pattern for grafana → `vm-grafana:80`, uptime-kuma → `uptime-kuma:80`, argocd → `argocd-server:80`, preserving each original's host and backend exactly):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: homepage-kong
  namespace: homepage
spec:
  ingressClassName: kong
  rules:
    - host: homepage.algovn.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: homepage
                port: { number: 80 }
  tls:
    - hosts: [homepage.algovn.com]
```

Add each twin filename to its directory's `kustomization.yaml` resources list.

- [ ] **Step 2: Validate, push, verify every host through Kong's ClusterIP**

```bash
scripts/validate.sh && git add platform/monitoring/manifests apps/homepage apps/uptime-kuma platform/argocd && git commit -m "feat(kong): twin ingresses for cutover" && git push
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=$HOME/.kube/config; argocd app get root --core --refresh >/dev/null; sleep 8; argocd app wait monitoring-config homepage uptime-kuma argocd --core --timeout 300 >/dev/null 2>&1; IP=$(kubectl -n kong get svc kong-gateway-proxy -o jsonpath={.spec.clusterIP}); for h in homepage.algovn.com grafana.algovn.com uptime.algovn.com argocd.algovn.com; do printf \"%s -> \" $h; curl -s -o /dev/null -w \"%{http_code}\n\" -H \"Host: $h\" http://$IP/; done"'
```

Expected: `homepage → 200`, `grafana → 302` (Grafana login redirect), `uptime → 200 or 302`, `argocd → 200`. Any 404 = KIC didn't admit that twin — check `kubectl -n kong logs deploy -l app.kubernetes.io/component=controller --tail 20` before proceeding. external-dns logs must show no changes (same host→target pairs).

---

### Task 4: Tunnel flip — public traffic through Kong

**Files:**
- Modify: `platform/cloudflared/configmap.yaml` (one line)

**Interfaces:**
- Consumes: verified Kong routes (Task 3).
- Produces: all public traffic via Kong. Rollback: `git revert` of this single commit.

- [ ] **Step 1: Flip the target**

In `platform/cloudflared/configmap.yaml` change:
```yaml
        service: http://traefik.kube-system.svc.cluster.local:80
```
to:
```yaml
        service: http://kong-gateway-proxy.kong.svc.cluster.local:80
```

- [ ] **Step 2: Validate, push, wait for cloudflared restart**

```bash
scripts/validate.sh && git add platform/cloudflared/configmap.yaml && git commit -m "feat(cutover): route tunnel to kong" && git push
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=$HOME/.kube/config; argocd app get root --core --refresh >/dev/null; sleep 8; argocd app wait cloudflared --core --timeout 300 >/dev/null 2>&1; kubectl -n cloudflared rollout restart deploy/cloudflared; kubectl -n cloudflared rollout status deploy/cloudflared --timeout=180s"'
```

Note: cloudflared does not watch its ConfigMap — the explicit rollout restart is required.

- [ ] **Step 3: Verify all four public hosts + Access**

```bash
for h in homepage.algovn.com uptime.algovn.com; do printf "%s -> " $h; curl -s -o /dev/null -w "%{http_code}\n" --max-time 30 https://$h/; done
for h in argocd.algovn.com grafana.algovn.com; do printf "%s -> " $h; curl -s -o /dev/null -w "%{http_code}\n" --max-time 30 https://$h/; done
```

Expected: homepage `200`, uptime `200` (or `302`), argocd and grafana `302` (Cloudflare Access challenge — Access sits at the edge and is unaffected by the backend swap). If anything fails: `git revert HEAD && git push`, restart cloudflared, re-verify — then debug Kong offline via Task 3's ClusterIP method.

---

### Task 5: Make Kong canonical — flip originals, drop twins

**Files:**
- Modify: `platform/monitoring/manifests/grafana-ingress.yaml`, `apps/homepage/ingress.yaml`, `apps/uptime-kuma/ingress.yaml`, `platform/argocd/ingress.yaml` (ingressClassName only)
- Delete: the four `*-kong.yaml` twins; Modify: the four `kustomization.yaml` files (remove twin entries)

**Interfaces:**
- Consumes: public traffic already on Kong (Task 4).
- Produces: canonical Ingresses owned by Kong; tree free of twins.

- [ ] **Step 1: Flip + delete in one commit**

In each of the four original Ingresses: `ingressClassName: traefik` → `kong`. `git rm` the four twins; remove their kustomization entries.

- [ ] **Step 2: Validate, push, verify no regression**

```bash
scripts/validate.sh && git add -u && git commit -m "feat(cutover): kong canonical ingress class, drop twins" && git push
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=$HOME/.kube/config; argocd app get root --core --refresh >/dev/null; sleep 8; argocd app wait monitoring-config homepage uptime-kuma argocd --core --timeout 300 >/dev/null 2>&1"'
curl -s -o /dev/null -w "homepage: %{http_code}\n" https://homepage.algovn.com/
curl -s -o /dev/null -w "argocd:   %{http_code}\n" https://argocd.algovn.com/
```

Expected: `200` and `302` — same as Task 4 step 3. Uptime-kuma's three monitors stay green (check https://uptime.algovn.com after login, or skip — the homepage/uptime monitors ARE the public-path check).

---

### Task 6: Remove Traefik; Kong takes node 80/443

**Files:**
- Modify: `ansible/roles/k3s_server/templates/config.yaml.j2` (add disable), `platform/kong/values.yaml` (proxy type)
- Delete: `platform/traefik/` (3 files), `clusters/algovn/platform/traefik-config.yaml`
- Modify: `docs/runbooks/verify.md`, `docs/runbooks/rebuild.md`, `docs/runbooks/add-app.md` (traefik→kong references)

**Interfaces:**
- Consumes: Kong serving all traffic (Task 5).
- Produces: single-proxy cluster; LAN 80/443 owned by `svclb-kong-gateway-proxy`; runbooks truthful again.

- [ ] **Step 1: Disable Traefik in k3s config**

`ansible/roles/k3s_server/templates/config.yaml.j2` — add at the end:
```yaml
disable:
  - traefik
```

- [ ] **Step 2: Remove Traefik from git; flip Kong proxy to LoadBalancer**

```bash
git rm -r platform/traefik clusters/algovn/platform/traefik-config.yaml
```

In `platform/kong/values.yaml`: `proxy.type: ClusterIP` → `LoadBalancer`.

- [ ] **Step 3: Update runbooks**

- `docs/runbooks/verify.md` item 5: same LAN curl, expectation now "404 from Kong, valid cert". Add item: "no traefik/svclb-traefik pods exist; svclb-kong owns 80/443".
- `docs/runbooks/rebuild.md`: note Traefik is disabled in k3s config; Kong is the gateway (Argo installs it; default cert = Certificate in ns kong).
- `docs/runbooks/add-app.md`: Ingresses use `ingressClassName: kong`; protection via `konghq.com/plugins` annotations (see `docs/runbooks/kong.md`, Task 7).

- [ ] **Step 4: Push (Argo prunes Traefik config), then apply the node change**

```bash
scripts/validate.sh && git add -A && git commit -m "feat(cutover): remove traefik, kong owns node 80/443" && git push
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=$HOME/.kube/config; argocd app get root --core --refresh >/dev/null; sleep 8; cd ~/iac && git pull -q && cd ansible && ansible-playbook site.yml --tags k3s 2>&1 | tail -4"'
```

Expected: playbook `failed=0` (k3s restarts with traefik disabled — brief API blip is normal). The k3s Traefik HelmChart is removed by the disable flag; Argo prunes `traefik-config`.

- [ ] **Step 5: Verify end state**

```bash
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=$HOME/.kube/config; kubectl get pods -A | grep -iE \"traefik\" || echo no-traefik-pods; kubectl -n kong get svc kong-gateway-proxy -o jsonpath=\"{.spec.type} {.status.loadBalancer.ingress[0].ip}\"; echo; kubectl get pods -A --no-headers | grep -Ev \"Running|Completed\" || echo all-pods-ok; free -h | sed -n 2p"'
curl -s --resolve x.algovn.com:443:192.168.102.200 https://x.algovn.com -o /dev/null -w "LAN TLS: %{http_code}\n"
curl -s -o /dev/null -w "public: %{http_code}\n" https://homepage.algovn.com/
```

Expected: no traefik pods; proxy Service `LoadBalancer 192.168.102.200`; all pods Running; LAN TLS `404` (Kong, valid cert — no `-k`); public homepage `200`; available RAM ≥ 300Mi (abort criterion otherwise).

---

### Task 7: Auth + rate-limit proof, and the Kong runbook

**Files:**
- Create: `docs/runbooks/kong.md`
- Transient (kubectl only, never committed): demo KongPlugins, KongConsumer, credential Secret, Ingress

**Interfaces:**
- Consumes: Kong canonical (Task 6), homepage Service as a harmless demo backend.
- Produces: spec §7.3 evidence (401/200/429); documented patterns for protecting real routes.

- [ ] **Step 1: Create the throwaway protected route (direct kubectl — this is a test rig, not config)**

Write the block below to a local file `rig.sh` and run `ssh ducle@192.168.102.200 'bash -s' < rig.sh` (heredocs typed directly may break in the local fish shell):

```bash
export KUBECONFIG=$HOME/.kube/config
kubectl -n homepage apply -f - <<'EOF'
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata: { name: demo-key-auth, namespace: homepage }
plugin: key-auth
---
apiVersion: configuration.konghq.com/v1
kind: KongPlugin
metadata: { name: demo-rate-limit, namespace: homepage }
plugin: rate-limiting
config: { minute: 5, policy: local }
---
apiVersion: v1
kind: Secret
metadata:
  name: demo-apikey
  namespace: homepage
  labels: { konghq.com/credential: key-auth }
stringData: { key: demo-secret-key-12345 }
---
apiVersion: configuration.konghq.com/v1
kind: KongConsumer
metadata:
  name: demo-consumer
  namespace: homepage
  annotations: { kubernetes.io/ingress.class: kong }
username: demo
credentials: [demo-apikey]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-protected
  namespace: homepage
  annotations: { konghq.com/plugins: "demo-key-auth, demo-rate-limit" }
spec:
  ingressClassName: kong
  rules:
    - host: demo-auth.algovn.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: homepage, port: { number: 80 } } }
EOF
```

- [ ] **Step 2: Verify 401 → 200 → 429 (via ClusterIP; no need to wait for public DNS)**

```bash
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=$HOME/.kube/config; IP=$(kubectl -n kong get svc kong-gateway-proxy -o jsonpath={.spec.clusterIP}); sleep 10; printf \"no key:   \"; curl -s -o /dev/null -w \"%{http_code}\n\" -H \"Host: demo-auth.algovn.com\" http://$IP/; printf \"with key: \"; curl -s -o /dev/null -w \"%{http_code}\n\" -H \"Host: demo-auth.algovn.com\" -H \"apikey: demo-secret-key-12345\" http://$IP/; for i in 1 2 3 4 5 6; do curl -s -o /dev/null -w \"burst $i: %{http_code}\n\" -H \"Host: demo-auth.algovn.com\" -H \"apikey: demo-secret-key-12345\" http://$IP/; done"'
```

Expected: `no key: 401`; `with key: 200`; bursts end in `429` by request 6 (5/minute limit; the earlier with-key request counts toward it).

- [ ] **Step 3: Tear down the rig**

```bash
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=$HOME/.kube/config; kubectl -n homepage delete ingress demo-protected; kubectl -n homepage delete kongconsumer demo-consumer; kubectl -n homepage delete kongplugin demo-key-auth demo-rate-limit; kubectl -n homepage delete secret demo-apikey"'
```

Expected: all deleted; `demo-auth.algovn.com` DNS (if external-dns created it) prunes within ~2 min.

- [ ] **Step 4: Write `docs/runbooks/kong.md`**

```markdown
# Kong gateway

Kong OSS, DB-less, Kong Ingress Controller. App `kong` (wave -3), config `platform/kong/`.
Default TLS: Certificate `wildcard-algovn` in ns kong → secret `wildcard-algovn-tls`.
Admin API is cluster-internal; Kong Manager disabled. Rate limiting: policy `local` only
(single node — revisit if a second node joins).

## Protect a route (key-auth + rate limit)
1. KongPlugin (namespace of the app):
   `plugin: key-auth` — and/or `plugin: rate-limiting` with `config: {minute: N, policy: local}`.
2. Consumer + key (key sealed for git!):
   kubectl create secret generic <app>-apikey -n <ns> --from-literal=key=<KEY> --dry-run=client -o yaml \
     | scripts/seal.sh > <dir>/<app>-apikey-sealed.yaml
   Add label `konghq.com/credential: key-auth` under the SealedSecret `spec.template.metadata.labels`.
   KongConsumer with `credentials: [<app>-apikey]` (annotation `kubernetes.io/ingress.class: kong`).
3. Bind on the Ingress: annotation `konghq.com/plugins: "<plugin-names>"`.
4. Verify: curl without key → 401; with `apikey: <KEY>` header → 200.

## JWT validation (when an issuer exists)
`plugin: jwt` KongPlugin + KongConsumer with a jwt credential secret holding the issuer's
public key. Not deployed — pattern only.

## Debug
- Routes not admitted: `kubectl -n kong logs deploy -l app.kubernetes.io/component=controller --tail 50`
- What Kong sees: `kubectl -n kong port-forward svc/kong-gateway-admin 8001:8001` is NOT exposed;
  use controller logs + `kubectl get ingresses,kongplugins,kongconsumers -A` instead.
- Metrics: Grafana "Kong (official)" dashboard; logs: Loki `{namespace="kong"}`.
```

- [ ] **Step 5: Validate, push**

```bash
scripts/validate.sh && git add docs/runbooks/kong.md && git commit -m "docs: kong runbook (auth + rate-limit patterns)" && git push
```

---

### Task 8: gRPC conventions — doc, service template, validate.sh fix

**Files:**
- Create: `docs/grpc-conventions.md`, `templates/grpc-service/{deployment.yaml,service.yaml,vmservicescrape.yaml,kustomization.yaml}`
- Modify: `templates/README.md` (gRPC section), `scripts/validate.sh` (actionlint scope — currently lints ALL `templates/*.yaml` as workflows; k8s manifests there would fail)

**Interfaces:**
- Consumes: nothing running — pure convention artifacts.
- Produces: copy-me template passing validate.sh; conventions doc referenced by templates/README.md.

- [ ] **Step 1: Fix validate.sh actionlint scope**

In `scripts/validate.sh`, replace:
```bash
if [ -d templates ]; then
  find templates -name '*.yaml' -print0 | xargs -0 -r actionlint
fi
```
with:
```bash
if [ -d templates ]; then
  find templates -maxdepth 1 -name 'github-actions-*.yaml' -print0 | xargs -0 -r actionlint
fi
```

- [ ] **Step 2: Write the template manifests**

`templates/grpc-service/deployment.yaml`:
```yaml
# Copy-me template: internal gRPC service. Replace NAME/NAMESPACE/IMAGE.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: NAME
  namespace: NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels: { app: NAME }
  template:
    metadata:
      labels: { app: NAME }
    spec:
      containers:
        - name: NAME
          image: ghcr.io/the-algovn/IMAGE:vX.Y.Z
          ports:
            - { containerPort: 9090, name: grpc }
            - { containerPort: 9091, name: metrics }
          readinessProbe:
            grpc: { port: 9090 }
            initialDelaySeconds: 5
          livenessProbe:
            grpc: { port: 9090 }
            initialDelaySeconds: 10
          resources:
            requests: { cpu: 25m, memory: 64Mi }
            limits: { memory: 128Mi }
```

`templates/grpc-service/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: NAME
  namespace: NAMESPACE
spec:
  clusterIP: None          # headless: enables grpc-go dns:/// round_robin later
  selector: { app: NAME }
  ports:
    - { port: 9090, targetPort: 9090, name: grpc }
    - { port: 9091, targetPort: 9091, name: metrics }
```

`templates/grpc-service/vmservicescrape.yaml`:
```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: NAME
  namespace: monitoring
spec:
  namespaceSelector: { matchNames: [NAMESPACE] }
  selector:
    matchLabels: { app: NAME }
  endpoints:
    - port: metrics
```

`templates/grpc-service/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - vmservicescrape.yaml
```

- [ ] **Step 3: Write `docs/grpc-conventions.md`**

```markdown
# Internal gRPC conventions

Scope: east-west only — gRPC never traverses Kong. Plaintext h2c inside the cluster
(single-node accepted risk; mTLS/mesh is a multi-node trigger, spec §8).

## Contracts
- All protos in `the-algovn/protos`, managed with buf. CI gates `buf lint` and
  `buf breaking --against '.git#branch=main'`.
- Generated Go is committed in that repo under `gen/go/` and consumed as a Go module:
  `go get github.com/the-algovn/protos/gen/go@latest`. Services never run protoc locally.
- Package naming: `algovn.<service>.v1`; breaking change ⇒ new `v2` package, never mutate `v1`.

## Service shape (see templates/grpc-service/)
- Port 9090 named `grpc`; Prometheus metrics on 9091 named `metrics`.
- Headless Service (clusterIP: None). Clients dial
  `dns:///NAME.NAMESPACE.svc.cluster.local:9090` with
  `grpc.WithDefaultServiceConfig('{"loadBalancingConfig":[{"round_robin":{}}]}')`
  — no client change needed when replicas > 1.
- Implement `grpc_health_v1.Health`; k8s-native gRPC probes (no sidecar binary).
- Enable server reflection in all environments (single-tenant cluster; aids grpcurl debugging).

## Client discipline
- Every outbound call sets a deadline (default 5s; long ops explicit).
- Retries ONLY via service config on idempotent methods (maxAttempts 3, exponential backoff);
  never hand-rolled retry loops.
- Keepalive: client `Time: 30s, Timeout: 10s, PermitWithoutStream: false`;
  server `MinTime: 15s` enforcement to match.

## Observability
- go-grpc-middleware v2 Prometheus interceptors (server + client), `/metrics` on 9091,
  VMServiceScrape per service (template included). Tracing deferred (spec §8).

## Exposure
- A gRPC service never gets an Ingress. If one ever needs to be public: Kong proxies
  gRPC/gRPC-Web — design that when it happens (spec §8 trigger).
```

- [ ] **Step 4: Add the gRPC section to `templates/README.md`**

Append:
```markdown

# Onboarding an internal gRPC service

1. Contracts first: add `algovn.<name>.v1` protos to `the-algovn/protos`, PR through its
   buf lint/breaking CI, tag; `go get github.com/the-algovn/protos/gen/go@<tag>`.
2. Copy `templates/grpc-service/` → `apps/<name>/`, replace NAME/NAMESPACE/IMAGE,
   add `clusters/algovn/apps/<name>.yaml` Application (same as any app).
3. Conventions (ports, health, deadlines, metrics): docs/grpc-conventions.md.
4. No Ingress, no DNS, no Kong — internal callers dial the headless service directly.
```

- [ ] **Step 5: Validate (kustomize now builds the template; actionlint scope narrowed), push**

```bash
scripts/validate.sh && git add scripts/validate.sh templates docs/grpc-conventions.md && git commit -m "feat(grpc): conventions doc + service template; scope actionlint to workflows" && git push
```

Expected: validate PASS — `ok: ./templates/grpc-service` appears in the kustomize section, actionlint still lints `github-actions-build-push.yaml`.

---

### Task 9: protos repo bootstrap (buf)

**Files (new repo `the-algovn/protos`):**
- Create: `buf.yaml`, `buf.gen.yaml`, `.github/workflows/ci.yaml`, `README.md`, `algovn/demo/v1/demo.proto`, `gen/go/` (generated), `go.mod` under `gen/go`

**Interfaces:**
- Consumes: nothing from the cluster.
- Produces: `github.com/the-algovn/protos/gen/go` Go module with a compiling demo package; CI gating lint + breaking.

- [ ] **Step 1: Create the repo**

```bash
cd /private/tmp/claude-503 2>/dev/null || cd /tmp
gh repo create the-algovn/protos --public --clone -d "gRPC contracts (buf-managed) for the algovn cluster"
cd protos
```

- [ ] **Step 2: Write buf config + demo proto**

`buf.yaml`:
```yaml
version: v2
modules:
  - path: .
lint:
  use: [STANDARD]
breaking:
  use: [FILE]
```

`buf.gen.yaml`:
```yaml
version: v2
plugins:
  - remote: buf.build/protocolbuffers/go
    out: gen/go
    opt: paths=source_relative
  - remote: buf.build/grpc/go
    out: gen/go
    opt: paths=source_relative
```

`algovn/demo/v1/demo.proto`:
```proto
syntax = "proto3";

package algovn.demo.v1;

option go_package = "github.com/the-algovn/protos/gen/go/algovn/demo/v1;demov1";

service DemoService {
  rpc Ping(PingRequest) returns (PingResponse);
}

message PingRequest {
  string message = 1;
}

message PingResponse {
  string message = 1;
}
```

`README.md`:
```markdown
# the-algovn/protos

gRPC contracts for the algovn cluster. buf-managed: `buf lint` + `buf breaking` gate CI.
Generated Go is committed under `gen/go` — consume with
`go get github.com/the-algovn/protos/gen/go@latest`.
Conventions: iac repo `docs/grpc-conventions.md`. Never mutate a released `vN` package.
```

- [ ] **Step 3: Install buf, generate, init the Go module**

```bash
brew install buf 2>/dev/null || brew upgrade buf; buf --version
buf lint && buf generate
cd gen/go && go mod init github.com/the-algovn/protos/gen/go && go mod tidy && go build ./... && cd ../..
```

Expected: lint clean; `gen/go/algovn/demo/v1/{demo.pb.go,demo_grpc.pb.go}` exist; `go build` succeeds.

- [ ] **Step 4: CI workflow**

`.github/workflows/ci.yaml`:
```yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]
jobs:
  buf:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: bufbuild/buf-action@v1
        with:
          lint: true
          breaking: ${{ github.event_name == 'pull_request' }}
          format: false
          push: false
```

- [ ] **Step 5: Commit, push, verify CI**

```bash
git add -A && git commit -m "feat: buf-managed protos repo with demo/v1 + generated go" && git push -u origin main
gh run watch --repo the-algovn/protos --exit-status $(gh run list --repo the-algovn/protos -L1 --json databaseId -q '.[0].databaseId')
```

Expected: CI concludes green (lint job; breaking skipped on push).

---

### Task 10: Acceptance vs spec §7 + close-out

**Files:**
- Modify: none new (evidence run); memory update happens outside the repo.

- [ ] **Step 1: Run every spec §7 criterion and record output**

1. Four public hosts through Kong (Task 4 §3 curls) → 200/200/302/302.
2. LAN TLS via node IP → Kong 404, LE cert (Task 6 §5 curl).
3. Auth/rate-limit evidence → recorded in Task 7 §2 output (401/200/429).
4. `kubectl get pods -A | grep -i traefik` → empty; svclb-kong owns 80/443.
5. Kong metrics query (Task 2 §4) returns series; Loki `{namespace="kong"}` returns lines.
6. `argocd app list --core` → all Synced/Healthy; `free -h` available ≥ 300Mi (spec target 400Mi — record actual; if 300–400Mi, apply spec pressure valve: set `defaultDashboards.enabled: false` in `platform/monitoring/values.yaml`, push, re-measure).
7. `scripts/validate.sh` → PASS including `ok: ./templates/grpc-service`.

- [ ] **Step 2: Fix-forward any failures, then update README Status**

Append to `README.md` Status section: `Kong gateway + gRPC conventions live — <date>, spec docs/superpowers/specs/2026-07-12-kong-gateway-grpc-conventions-design.md.` Push (this doc-only change may go via PR at operator discretion).

---

## Spec coverage map (self-review)

| Spec section | Tasks |
|---|---|
| §2 decisions (KIC, DB-less, validate-only) | 1 (values), 7 (auth patterns) |
| §3 architecture, default TLS, admin internal | 1 |
| §4 cutover steps 1–5 | 1 (deploy), 3 (twins), 4 (tunnel), 5 (canonical), 6 (traefik removal + LB) |
| §5 plugins/auth/rate-limit/observability/resources | 2 (observability), 7 (auth+RL proof + runbook), 1 (resources) |
| §6 gRPC conventions, template, protos/buf | 8 (doc+template+validate.sh), 9 (protos repo) |
| §7 verification | each task's verify steps; 10 (full acceptance) |
| §8 deferred | recorded in docs (7 §4 jwt note, 8 §3 exposure/tracing notes) — nothing built |
