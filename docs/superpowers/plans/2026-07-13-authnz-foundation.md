# AuthN/Z Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the platform's authN/Z foundation — Zitadel (OIDC IdP, login v2) at `id.algovn.com` + OpenFGA (fine-grained permissions, gRPC-internal) on the existing CNPG Postgres, with Kong edge JWT validation and first-class database backups to Cloudflare R2.

**Architecture:** Two new GitOps platform components (`platform/zitadel/`, `platform/openfga/`) using official Helm charts via multi-source Argo Applications (kong.yaml pattern). Their databases live in the existing CNPG cluster `pg` (postgres.md runbook pattern). Kong OSS `jwt` plugin gates user-facing routes using Zitadel's public key as a plain committed Secret; rotation is deliberate via Zitadel web keys. Backups fire the deferred k3s-spec trigger: CNPG Barman Cloud plugin → R2, nightly + WAL archiving.

**Tech Stack:** Zitadel chart **9.34.0** (app v4.13.0, repo `https://charts.zitadel.com`) · OpenFGA chart **0.3.10** (app v1.18.1, repo `https://openfga.github.io/helm-charts`) · plugin-barman-cloud **v0.13.0** · CNPG operator 1.30.0 + PG 18.4 (existing) · Kong OSS `jwt` plugin (existing gateway).

**Spec:** `docs/superpowers/specs/2026-07-13-authnz-foundation-design.md`

## Global Constraints

- **No plaintext secrets in git — ever.** SealedSecrets only. Sealing runs over ssh on the Pi (Mac has no kubectl/kubeseal) — the exact pipeline is in `docs/runbooks/postgres.md` §"Add an app database". Public-key material (JWT verification keys) is NOT secret → plain committed Secret.
- **`scripts/validate.sh` must pass before every push.** `main` is what the cluster runs; a push deploys.
- **kubectl/argocd from the Mac:** `ssh pi 'kubectl ...'` / `ssh pi 'argocd app <cmd> <app> --core'`. kubectl on the Pi prints a k3s-config permission warning on **stderr** — keep stderr separate, never `2>&1 | head`.
- **Commits:** small, focused, one logical change; stage listed files explicitly (never `git add -A`). No Co-Authored-By / "Generated with" lines. `docs/superpowers/` is gitignored — plan/spec updates need `git add -f`.
- **Nodes:** Pi `192.168.102.200` (arm64) + w1 `192.168.102.201` (amd64, hosts Postgres). All images must be multi-arch (the pinned charts' images are). Kong's svclb listens on both node IPs.
- **Hostname:** `id.algovn.com`. Namespaces: `zitadel`, `openfga`. DNS/TLS are automatic (external-dns + CF tunnel + wildcard cert) once an Ingress exists.
- **Execution parameters** (obtained during tasks, referenced as `<PLACEHOLDER>`): `<R2_ACCOUNT_ID>` (Cloudflare dash → R2 → account ID), passwords/keys generated per task. Never substitute these into committed files unless the value is public.

---

### Task 1: Barman Cloud plugin (platform component)

The CNPG in-tree backup path doesn't support PG 18; backups require the Barman Cloud CNPG-I plugin (runs in `cnpg-system`, needs cert-manager — present).

**Files:**
- Create: `platform/barman-cloud/kustomization.yaml`
- Create: `clusters/algovn/platform/barman-cloud.yaml`

**Interfaces:**
- Produces: plugin `barman-cloud.cloudnative-pg.io` usable by Cluster/Backup CRs (Task 2); CRD `ObjectStore` (group `barmancloud.cnpg.io/v1`).

- [ ] **Step 1: Write the component**

`platform/barman-cloud/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.13.0/manifest.yaml
```

`clusters/algovn/platform/barman-cloud.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: barman-cloud
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  source:
    repoURL: https://github.com/the-algovn/iac.git
    targetRevision: main
    path: platform/barman-cloud
  destination:
    server: https://kubernetes.default.svc
    namespace: cnpg-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ServerSideApply=true]
```

- [ ] **Step 2: Validate**

Run: `scripts/validate.sh`
Expected: `PASS` (the remote-URL kustomization builds; kubeconform may skip unknown CRDs via `-ignore-missing-schemas` — fine).

- [ ] **Step 3: Commit and push**

```bash
git add platform/barman-cloud/kustomization.yaml clusters/algovn/platform/barman-cloud.yaml
git commit -m "feat(backup): install CNPG barman-cloud plugin v0.13.0"
git push
```

- [ ] **Step 4: Verify deployment**

Run: `ssh pi 'argocd app sync barman-cloud --core && argocd app wait barman-cloud --core --timeout 300'`
Then: `ssh pi 'kubectl get pods -n cnpg-system'`
Expected: `barman-cloud` deployment pod `1/1 Running` alongside the cnpg operator pod.

---

### Task 2: WAL archiving + nightly backups to R2

**Files:**
- Create: `platform/postgres/manifests/objectstore.yaml`
- Create: `platform/postgres/manifests/scheduledbackup.yaml`
- Create: `platform/postgres/manifests/r2-backup-creds-sealed.yaml` (generated by sealing)
- Modify: `platform/postgres/manifests/cluster.yaml` (add `spec.plugins`)
- Modify: `platform/postgres/manifests/kustomization.yaml`

**Interfaces:**
- Consumes: plugin from Task 1.
- Produces: ObjectStore `r2-store` (ns `postgres`) — used by restore drill (Task 3) and rebuild runbook.

- [ ] **Step 1 (USER): Create the R2 bucket + token**

In the Cloudflare dashboard: R2 → Create bucket `algovn-pg-backups` (location: APAC). Then R2 → Manage API Tokens → Create token, permission **Object Read & Write**, scoped to bucket `algovn-pg-backups`. Record: Access Key ID, Secret Access Key, and the account ID `<R2_ACCOUNT_ID>` (shown on the R2 overview page in the S3 endpoint `https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com`).

- [ ] **Step 2: Seal the R2 credentials**

```bash
mkdir -p ~/.secrets && chmod 700 ~/.secrets
printf 'ACCESS_KEY_ID=<from step 1>\nSECRET_ACCESS_KEY=<from step 1>\n' > ~/.secrets/r2-env
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=\$HOME/.kube/config; kubectl create secret generic r2-backup-creds -n postgres --from-env-file=/dev/stdin --dry-run=client -o yaml | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml"' < ~/.secrets/r2-env > platform/postgres/manifests/r2-backup-creds-sealed.yaml
dd if=/dev/urandom of=~/.secrets/r2-env bs=1 count=$(stat -f%z ~/.secrets/r2-env) conv=notrunc && rm -f ~/.secrets/r2-env
```
Expected: sealed yaml with `kind: SealedSecret`, ns `postgres`, keys `ACCESS_KEY_ID` + `SECRET_ACCESS_KEY`.

- [ ] **Step 3: Write manifests**

`platform/postgres/manifests/objectstore.yaml`:
```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: r2-store
  namespace: postgres
spec:
  retentionPolicy: "14d"
  configuration:
    destinationPath: s3://algovn-pg-backups/
    endpointURL: https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com
    s3Credentials:
      accessKeyId: { name: r2-backup-creds, key: ACCESS_KEY_ID }
      secretAccessKey: { name: r2-backup-creds, key: SECRET_ACCESS_KEY }
    wal: { compression: gzip }
    data: { compression: gzip }
```
(`<R2_ACCOUNT_ID>` is public-ish infrastructure metadata, not a credential — committing it is fine.)

`platform/postgres/manifests/scheduledbackup.yaml` (CNPG cron has a leading seconds field; 19:00 UTC = 02:00 Asia/Ho_Chi_Minh):
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: pg-nightly
  namespace: postgres
spec:
  schedule: "0 0 19 * * *"
  cluster: { name: pg }
  backupOwnerReference: self
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

In `platform/postgres/manifests/cluster.yaml`, add under `spec:` (sibling of `instances`):
```yaml
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: r2-store
```

`platform/postgres/manifests/kustomization.yaml` resources become:
```yaml
resources:
  - cluster.yaml
  - podscrape.yaml
  - objectstore.yaml
  - scheduledbackup.yaml
  - r2-backup-creds-sealed.yaml
```

- [ ] **Step 4: Validate, commit, push**

Run: `scripts/validate.sh` → `PASS`
```bash
git add platform/postgres/manifests/objectstore.yaml platform/postgres/manifests/scheduledbackup.yaml platform/postgres/manifests/r2-backup-creds-sealed.yaml platform/postgres/manifests/cluster.yaml platform/postgres/manifests/kustomization.yaml
git commit -m "feat(backup): WAL archiving + nightly base backups of pg to Cloudflare R2"
git push
```

- [ ] **Step 5: Verify WAL archiving**

Run: `ssh pi 'argocd app sync postgres --core && argocd app wait postgres --core --timeout 300'`
(The plugin change triggers a rolling restart of `pg-1` — brief Postgres outage, nothing depends on it yet.)
Run: `ssh pi 'kubectl get cluster pg -n postgres -o yaml' | grep -A3 'type: ContinuousArchiving'`
Expected: contains `status: "True"` (allow ~2 min after restart; if `"False"`, `kubectl logs -n postgres pg-1 -c plugin-barman-cloud` shows the S3 error).

- [ ] **Step 6: On-demand first backup (throwaway CR, not git)**

```bash
ssh pi 'kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: pg-initial, namespace: postgres }
spec:
  cluster: { name: pg }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
EOF'
ssh pi 'kubectl wait backup pg-initial -n postgres --for=jsonpath="{.status.phase}"=completed --timeout=600s && kubectl get backup pg-initial -n postgres'
```
Expected: `phase: completed`. Also confirm objects exist in the R2 bucket via the Cloudflare dash (`algovn-pg-backups/pg/base/...` and `pg/wals/...`).

---

### Task 3: Restore drill, staleness alert, backup runbook

**Files:**
- Create: `docs/runbooks/postgres-restore.md`
- Modify: `platform/monitoring/manifests/vmrules.yaml` (add `backups` group)
- Modify: `docs/runbooks/postgres.md` (remove the NO BACKUPS warning)

**Interfaces:**
- Consumes: ObjectStore `r2-store` + completed backup from Task 2.

- [ ] **Step 1: Plant a marker, then run the restore drill (throwaway, kubectl only)**

```bash
ssh pi 'kubectl exec -n postgres pg-1 -c postgres -- psql -U postgres -c "CREATE DATABASE drillmark;"'
ssh pi 'kubectl exec -n postgres pg-1 -c postgres -- psql -U postgres -d drillmark -c "CREATE TABLE t(v text); INSERT INTO t VALUES (\$\$restore-proof-2026-07-13\$\$);"'
# take a fresh backup containing the marker
ssh pi 'kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: pg-drill, namespace: postgres }
spec:
  cluster: { name: pg }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
EOF'
ssh pi 'kubectl wait backup pg-drill -n postgres --for=jsonpath="{.status.phase}"=completed --timeout=600s'
```

Then the scratch recovery cluster:
```bash
ssh pi 'kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: pg-drill, namespace: postgres }
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.4-standard-trixie
  storage: { storageClass: local-path, size: 5Gi }
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits: { memory: 512Mi }
  bootstrap:
    recovery: { source: origin }
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: { barmanObjectName: r2-store, serverName: pg }
EOF'
ssh pi 'kubectl wait cluster pg-drill -n postgres --for=condition=Ready --timeout=900s'
ssh pi 'kubectl exec -n postgres pg-drill-1 -c postgres -- psql -U postgres -d drillmark -tc "SELECT v FROM t;"'
```
Expected final output: `restore-proof-2026-07-13`.

- [ ] **Step 2: Clean up the drill**

```bash
ssh pi 'kubectl delete cluster pg-drill -n postgres && kubectl delete backup pg-drill pg-initial -n postgres'
ssh pi 'kubectl exec -n postgres pg-1 -c postgres -- psql -U postgres -c "DROP DATABASE drillmark;"'
```
Expected: resources gone; `kubectl get cluster -n postgres` shows only `pg`.

- [ ] **Step 3: Staleness alert**

Append to `platform/monitoring/manifests/vmrules.yaml` under `spec.groups`:
```yaml
    - name: backups
      rules:
        - alert: PgBackupStale
          expr: >-
            (time() - cnpg_collector_last_available_backup_timestamp{cluster="pg"}) > 93600
            or absent(cnpg_collector_last_available_backup_timestamp{cluster="pg"})
          for: 30m
          labels: { severity: critical }
          annotations:
            summary: 'Last successful pg base backup is older than 26h (or metric missing)'
```

- [ ] **Step 4: Write `docs/runbooks/postgres-restore.md`**

```markdown
# Postgres restore (from R2, barman-cloud plugin)
Backups: nightly base 02:00 ICT (`ScheduledBackup pg-nightly`) + continuous WAL, bucket
`algovn-pg-backups` (R2), retention 14d (`ObjectStore r2-store`). Alert: PgBackupStale (>26h).
Drill last passed: 2026-07-13 (marker row recovered from scratch cluster).

## Full rebuild (data loss on `pg`)
1. Ensure `barman-cloud` + `postgres` Argo apps are Synced (sealed creds restored via sealing key).
2. STOP writes: scale consumers (zitadel, openfga) to 0 replicas via Argo app parameter override
   or `kubectl scale deploy -n <ns> --all --replicas=0` (self-heal will restore later — work fast
   or disable auto-sync on those apps first).
3. Recreate the cluster AS A NEW NAME from backup (in-place bootstrap swap is NOT supported):
   edit `platform/postgres/manifests/cluster.yaml` — new `metadata.name` (e.g. `pg2`), add:
       bootstrap:
         recovery: { source: origin }
       externalClusters:
         - name: origin
           plugin:
             name: barman-cloud.cloudnative-pg.io
             parameters: { barmanObjectName: r2-store, serverName: pg }
   Keep `plugins:` block but change `serverName` going forward? NO — new cluster archives under
   its own name (`pg2`) automatically; `r2-store` holds both trees. Push, wait healthy.
4. Point consumers at the new rw service if the name changed (`pg2-rw.postgres.svc`) — zitadel
   values + openfga DSN secret — or keep the old name by deleting the failed cluster first and
   reusing `pg` (then serverName for the NEW archive tree must differ: set
   `plugins[0].parameters.serverName: pg-v2`).
5. Verify: `psql -tc "SELECT count(*) FROM pg_database"` sane; app logins work; take an
   on-demand Backup; drop the old archive tree from R2 when confident.

## Point-in-time (bad migration, oops-delete)
Same as above plus under `bootstrap.recovery`:
    recoveryTarget: { targetTime: "2026-07-13 01:00:00+07" }
Restore to a SCRATCH cluster first (see drill below), extract what you need with pg_dump, then
decide whether to promote wholesale.

## Quarterly drill (copy-paste)
Exactly the Task-3 drill from the authnz plan: marker DB → on-demand Backup → scratch
`pg-drill` cluster with `bootstrap.recovery` from `r2-store`/`serverName: pg` → SELECT marker →
delete drill resources + marker. Record the date here.
```

- [ ] **Step 5: Update `docs/runbooks/postgres.md`**

Replace the line `⚠️ NO BACKUPS (decision 2026-07-12) — node/disk loss = data loss. Follow-up before anything` and its continuation line `irreplaceable lands here: WAL archiving + base backups to Cloudflare R2 (CNPG Barman Cloud plugin).` with:
```markdown
Backups: nightly base + WAL archiving → R2 (plugin barman-cloud). Restore: postgres-restore.md.
```

- [ ] **Step 6: Validate, commit, push, verify alert loads**

Run: `scripts/validate.sh` → `PASS`
```bash
git add platform/monitoring/manifests/vmrules.yaml docs/runbooks/postgres-restore.md docs/runbooks/postgres.md
git commit -m "feat(backup): restore runbook (drill passed) + PgBackupStale alert"
git push
```
Run: `ssh pi 'argocd app sync monitoring --core'` then
`ssh pi 'kubectl get vmrule platform-custom -n monitoring -o jsonpath="{.spec.groups[*].name}"'`
Expected: `gitops certificates backups`.

---

### Task 4: Zitadel database + sealed secrets

Follows `docs/runbooks/postgres.md` §"Add an app database" exactly, plus Zitadel's two extra secrets.

**Files:**
- Modify: `platform/postgres/manifests/cluster.yaml` (`managed.roles` += zitadel)
- Create: `platform/postgres/manifests/db-zitadel.yaml`
- Create: `platform/postgres/manifests/pg-role-zitadel-sealed.yaml` (sealed)
- Create: `platform/zitadel/manifests/zitadel-masterkey-sealed.yaml` (sealed)
- Create: `platform/zitadel/manifests/zitadel-config-sealed.yaml` (sealed)
- Modify: `platform/postgres/manifests/kustomization.yaml`
- Modify: `docs/runbooks/rebuild.md`

**Interfaces:**
- Produces: DB `zitadel`/role `zitadel` on `pg-rw.postgres.svc:5432`; Secrets in ns `zitadel`: `zitadel-masterkey` (key `masterkey`), `zitadel-config` (key `config-yaml`). Task 5's values reference these exact names.

- [ ] **Step 1: Generate secrets locally**

```bash
openssl rand -base64 24 | tr -d "[:space:]" > ~/.secrets/zitadel-pg-pw
openssl rand -hex 16 | tr -d "[:space:]" > ~/.secrets/zitadel-masterkey   # exactly 32 chars
openssl rand -base64 18 | tr -d "[:space:]" > ~/.secrets/zitadel-admin-pw
```

- [ ] **Step 2 (USER): Back up the masterkey**

Store `~/.secrets/zitadel-masterkey` content in the password manager as **zitadel-masterkey** (root-of-trust: rebuild needs it alongside the sealing key). Also store the admin bootstrap password as **zitadel-admin-bootstrap**.

- [ ] **Step 3: Seal all three + the DB role secret**

```bash
# role secret (ns postgres) — postgres.md pattern
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=\$HOME/.kube/config; kubectl create secret generic pg-role-zitadel -n postgres --type=kubernetes.io/basic-auth --from-literal=username=zitadel --from-file=password=/dev/stdin --dry-run=client -o yaml | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml"' < ~/.secrets/zitadel-pg-pw > platform/postgres/manifests/pg-role-zitadel-sealed.yaml

# masterkey (ns zitadel)
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=\$HOME/.kube/config; kubectl create secret generic zitadel-masterkey -n zitadel --from-file=masterkey=/dev/stdin --dry-run=client -o yaml | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml"' < ~/.secrets/zitadel-masterkey > platform/zitadel/manifests/zitadel-masterkey-sealed.yaml

# config-yaml (ns zitadel): DB passwords + first-instance admin
cat > ~/.secrets/zitadel-config.yaml <<EOF
Database:
  Postgres:
    User:
      Password: "$(cat ~/.secrets/zitadel-pg-pw)"
    Admin:
      Password: "$(cat ~/.secrets/zitadel-pg-pw)"
FirstInstance:
  Org:
    Name: AlgoVN
    Human:
      UserName: admin
      Password: "$(cat ~/.secrets/zitadel-admin-pw)"
      PasswordChangeRequired: true
      Email:
        Address: minhducle.dev@gmail.com
        Verified: true
EOF
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=\$HOME/.kube/config; kubectl create secret generic zitadel-config -n zitadel --from-file=config-yaml=/dev/stdin --dry-run=client -o yaml | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml"' < ~/.secrets/zitadel-config.yaml > platform/zitadel/manifests/zitadel-config-sealed.yaml
```
(Admin == User deliberately: the DB/role are pre-provisioned by CNPG and role `zitadel` owns DB `zitadel`, so `zitadel init` finds everything present and skips privileged steps. Fallback if the init job still fails on permissions: recreate `zitadel-config` including the CNPG superuser password from `kubectl get secret -n postgres pg-superuser` under `Database.Postgres.Admin.{Username: postgres, Password: ...}` — sealed the same way.)

Cleanup plaintext (macOS, postgres.md pattern):
```bash
for f in zitadel-pg-pw zitadel-masterkey zitadel-admin-pw zitadel-config.yaml; do dd if=/dev/urandom of=~/.secrets/$f bs=1 count=$(stat -f%z ~/.secrets/$f) conv=notrunc && rm -f ~/.secrets/$f; done
```

- [ ] **Step 4: Declare role + database**

`platform/postgres/manifests/cluster.yaml` → `spec.managed.roles` becomes:
```yaml
  managed:
    roles:
      - name: zitadel
        ensure: present
        login: true
        passwordSecret: { name: pg-role-zitadel }
```

`platform/postgres/manifests/db-zitadel.yaml`:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: zitadel
  namespace: postgres
spec:
  name: zitadel
  owner: zitadel
  cluster: { name: pg }
```

Add `db-zitadel.yaml` and `pg-role-zitadel-sealed.yaml` to `platform/postgres/manifests/kustomization.yaml` resources. (The two ns-`zitadel` sealed files join Task 5's kustomization — they're committed here but only referenced there.)

- [ ] **Step 5: Update `docs/runbooks/rebuild.md`**

In the restore-keys step (step 4, sealing key), append:
```markdown
   Also required from the password manager: **zitadel-masterkey** (Zitadel decrypts its key
   material with it — wrong/lost masterkey = unrecoverable IdP even with DB backups).
   Post-rebuild: Postgres data comes back via postgres-restore.md (R2), NOT from git.
```

- [ ] **Step 6: Validate, commit, push, verify**

Run: `scripts/validate.sh` → `PASS`
```bash
git add platform/postgres/manifests/cluster.yaml platform/postgres/manifests/db-zitadel.yaml platform/postgres/manifests/pg-role-zitadel-sealed.yaml platform/postgres/manifests/kustomization.yaml platform/zitadel/manifests/zitadel-masterkey-sealed.yaml platform/zitadel/manifests/zitadel-config-sealed.yaml docs/runbooks/rebuild.md
git commit -m "feat(zitadel): provision zitadel database, role, and sealed secrets"
git push
```
Run: `ssh pi 'argocd app sync postgres --core && kubectl get database zitadel -n postgres && kubectl get secret pg-role-zitadel -n postgres'`
Expected: Database `zitadel` ready; secret exists (missing secret = sealed for wrong ns/name — see postgres.md verify notes).

---

### Task 5: Zitadel platform component (manifests only)

**Files:**
- Create: `platform/zitadel/values.yaml`
- Create: `platform/zitadel/manifests/kustomization.yaml`
- Create: `platform/zitadel/manifests/vmservicescrape.yaml`
- Create: `clusters/algovn/platform/zitadel.yaml`

**Interfaces:**
- Consumes: secret names from Task 4 (`zitadel-masterkey`, `zitadel-config`).
- Produces: OIDC issuer `https://id.algovn.com`; services `zitadel:8080` and `zitadel-login:3000` in ns `zitadel`; Argo app `zitadel`.

- [ ] **Step 1: Write `platform/zitadel/values.yaml`**

```yaml
zitadel:
  masterkeySecretName: zitadel-masterkey
  configSecretName: zitadel-config   # merges over configmapConfig; holds DB passwords + FirstInstance
  configmapConfig:
    ExternalDomain: id.algovn.com
    ExternalPort: 443
    ExternalSecure: true
    TLS:
      Enabled: false                 # TLS terminates at CF edge / Kong default cert
    Database:
      Postgres:
        Host: pg-rw.postgres.svc
        Port: 5432
        Database: zitadel
        MaxOpenConns: 10
        MaxIdleConns: 5
        User:
          Username: zitadel
          SSL: { Mode: disable }
        Admin:
          Username: zitadel
          SSL: { Mode: disable }
resources:
  requests: { cpu: 100m, memory: 300Mi }
  limits: { memory: 512Mi }
env:
  - name: GOMEMLIMIT
    value: 450MiB
ingress:
  enabled: true
  className: kong
  hosts:
    - host: id.algovn.com
      paths: [{ path: /, pathType: Prefix }]
  tls: [{ hosts: [id.algovn.com] }]
login:
  enabled: true
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits: { memory: 256Mi }
  ingress:
    enabled: true
    className: kong
    hosts:
      - host: id.algovn.com
        paths: [{ path: /ui/v2/login, pathType: Prefix }]
    tls: [{ hosts: [id.algovn.com] }]
```

- [ ] **Step 2: Manifests kustomization + scrape**

`platform/zitadel/manifests/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - zitadel-masterkey-sealed.yaml
  - zitadel-config-sealed.yaml
  - vmservicescrape.yaml
```

`platform/zitadel/manifests/vmservicescrape.yaml` (Zitadel serves Prometheus metrics on its main port at `/debug/metrics`):
```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: zitadel
  namespace: monitoring
spec:
  namespaceSelector: { matchNames: [zitadel] }
  selector:
    matchLabels:
      app.kubernetes.io/name: zitadel
  endpoints:
    - port: http2-server
      path: /debug/metrics
```
Port-name check: in the Step-4 `helm template` output, find the `zitadel` Service's `ports[].name` — if it isn't `http2-server`, use the rendered name here.

- [ ] **Step 3: Application**

`clusters/algovn/platform/zitadel.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: zitadel
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  sources:
    - repoURL: https://charts.zitadel.com
      chart: zitadel
      targetRevision: 9.34.0
      helm:
        releaseName: zitadel
        valueFiles:
          - $values/platform/zitadel/values.yaml
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      ref: values
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      path: platform/zitadel/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: zitadel
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
    retry:
      limit: 5
      backoff: { duration: 30s, factor: 2, maxDuration: 5m }
```

- [ ] **Step 4: Sanity-render the chart locally, then validate**

```bash
helm repo add zitadel https://charts.zitadel.com && helm repo update zitadel
helm template zitadel zitadel/zitadel --version 9.34.0 -n zitadel -f platform/zitadel/values.yaml | grep -E "^kind:|^  name:" | sort | uniq -c | sort -rn | head -20
```
Expected: renders without error; includes two Ingresses (`zitadel`, `zitadel-login`), Deployments for zitadel + login, init/setup Jobs. If the login ingress default path differs from `/ui/v2/login`, keep the CHART's default path (adjust values to match) — the chart knows where login v2 lives.

Run: `scripts/validate.sh` → `PASS`

- [ ] **Step 5: Commit (no push yet — deploy is Task 6)**

```bash
git add platform/zitadel/values.yaml platform/zitadel/manifests/kustomization.yaml platform/zitadel/manifests/vmservicescrape.yaml clusters/algovn/platform/zitadel.yaml
git commit -m "feat(zitadel): platform component — chart 9.34.0, id.algovn.com, login v2"
```

---

### Task 6: Deploy Zitadel + verify OIDC discovery (spec §8.1)

**Files:** none (deploy + verify).

**Interfaces:**
- Produces: live issuer `https://id.algovn.com` with JWKS at `/oauth/v2/keys` (consumed by Tasks 7–9, 13).

- [ ] **Step 1: Push and sync**

```bash
git push
ssh pi 'argocd app sync zitadel --core && argocd app wait zitadel --core --timeout 600'
```
Expected: Synced/Healthy. First sync runs init + setup Jobs (schema + first instance) — allow several minutes on first attempt. Failure modes: init job CrashLoop on DB permissions → Task 4 Step 3 fallback (superuser Admin); sealed secret missing → `kubectl describe sealedsecret -n zitadel`.

- [ ] **Step 2: Verify pods**

Run: `ssh pi 'kubectl get pods -n zitadel'`
Expected: `zitadel-...` `1/1 Running`, `zitadel-login-...` `1/1 Running`, completed `init`/`setup` job pods.

- [ ] **Step 3: Verify discovery — LAN path first, then public**

```bash
curl -s --resolve id.algovn.com:443:192.168.102.200 https://id.algovn.com/.well-known/openid-configuration | jq -r '.issuer'
curl -s https://id.algovn.com/.well-known/openid-configuration | jq -r '.issuer'
curl -s https://id.algovn.com/oauth/v2/keys | jq '.keys | length'
```
Expected: `https://id.algovn.com` twice (public needs external-dns a minute to publish the CNAME); key count ≥ 1.

- [ ] **Step 4: Verify login page + console render**

Open `https://id.algovn.com/ui/v2/login` and `https://id.algovn.com/ui/console` in a browser.
Expected: login v2 renders (username prompt); console redirects to login. **Do not log in yet** — bootstrap is Task 7.

- [ ] **Step 5: Verify metrics scrape**

Run: `ssh pi 'kubectl get vmservicescrape zitadel -n monitoring'` then query
`ssh pi 'curl -s "http://vmsingle-vm.monitoring.svc:8428/api/v1/query?query=up{job=~\".*zitadel.*\"}" | jq ".data.result[].value[1]"'`
Expected: `"1"`.

---

### Task 7: Zitadel bootstrap — admin passkey, IdPs, passwordless policy (spec §8.2)

Console/IdP content is deliberately NOT GitOps (spec §5) — this task produces the runbook and executes it once. Steps marked **(USER)** need the user's accounts/devices.

**Files:**
- Create: `docs/runbooks/zitadel.md`

**Interfaces:**
- Produces: working Google/GitHub/passkey login; service user `iam-admin-sa` PAT (password manager) — consumed by Tasks 9 & 13 API calls; org structure (`AlgoVN` platform org, `users` default org).

- [ ] **Step 1: Write `docs/runbooks/zitadel.md`**

```markdown
# Zitadel (id.algovn.com) — bootstrap & operations
IdP for all SaaS products (spec 2026-07-13). Console: /ui/console. IdP CONTENT (orgs,
projects, IdP configs, policies) lives in Zitadel's DB — backed up via postgres-restore.md,
NOT reproducible from git. This runbook is the reproduction path.

## Bootstrap (once per instance)
1. Login: admin / password-manager item `zitadel-admin-bootstrap` (forced change on first login).
2. Admin passkey: top-right avatar → Passkeys → add (Touch ID). Then ADD A SECOND one
   (phone/YubiKey) — passkey loss with passwords disabled = console lockout.
3. Service user: Default settings → (org AlgoVN) Users → Service Users → new `iam-admin-sa`,
   Access Token Type: Bearer → create a PAT (expiry 1y) → store as `zitadel-iam-admin-sa-pat`
   in the password manager. Grant instance role: Default settings → Managers → add
   `iam-admin-sa` as IAM_OWNER. (Break-glass: this PAT can re-enable password login via API.)
4. Default org for self-registration: Organizations → New → name `users` → ⋮ → Set as default.
   (AlgoVN stays the platform/admin org that owns future product projects.)
5. Google IdP: Default settings → Identity Providers → Google. (USER) In
   console.cloud.google.com → APIs & Services → Credentials → Create OAuth client (Web app);
   Authorized redirect URI = the exact value the Zitadel IdP form displays. Paste client
   ID/secret back. Options: check Automatic creation, Automatic linking (email verified),
   uncheck manual account creation.
6. GitHub IdP: same flow — github.com → Settings → Developer settings → OAuth Apps → New;
   callback = value shown by the Zitadel GitHub IdP form.
7. Both IdPs: activate for the instance AND ensure login policy "Allow external IdP" is on
   (Default settings → Login Behavior and Security).
8. Passwordless-only policy (Default settings → Login Behavior and Security):
   - Passkeys allowed (multifactor init skipped)
   - Register allowed: ON (social auto-registration)
   - ONLY AFTER step 2 verified on a fresh browser: Username Password allowed: OFF.
9. Branding (optional now): Default settings → Branding — logo/colors; custom login app is a
   deferred project (spec §9).

## Verification (fresh private browser window each)
- Google signup: /ui/v2/login → Google → new user lands in org `users`.
- GitHub signup: same.
- Passkey: log into account page (/ui/v2/login → self-service), add passkey, log out,
  log in with passkey ONLY. Confirm NO password option is offered anywhere.

## Recovery / notes
- Admin passkey lost: use `zitadel-iam-admin-sa-pat` →
  PUT /admin/v1/policies/login {"allowUsernamePassword": true} — then fix and re-disable.
- New SaaS product onboarding: see docs/authnz-conventions.md.
- Key rotation: docs/runbooks/zitadel-key-rotation.md.
```

- [ ] **Step 2 (USER): Execute bootstrap steps 1–4**

Expected: admin has 2 passkeys; `iam-admin-sa` PAT stored; org `users` is default.

- [ ] **Step 3 (USER): Execute IdP steps 5–7 (needs Google Cloud + GitHub accounts)**

Expected: both IdPs listed as active.

- [ ] **Step 4 (USER): Execute policy step 8 + all three verifications**

Expected (spec §8.2): Google and GitHub auto-register in fresh sessions; passkey-only login works; no password field anywhere.

- [ ] **Step 5: Sanity-check the PAT works (needed by later tasks)**

```bash
export ZPAT='<paste zitadel-iam-admin-sa-pat>'
curl -s -H "Authorization: Bearer $ZPAT" https://id.algovn.com/admin/v1/instances/me | jq -r '.instance.name // .name // "FAIL"'
```
Expected: an instance name (not FAIL / 401).

- [ ] **Step 6: Commit the runbook**

```bash
git add docs/runbooks/zitadel.md
git commit -m "docs: zitadel bootstrap + operations runbook (executed, verified)"
git push
```

---

### Task 8: Kong edge JWT — consumer, credential, plugin (spec §4)

**Files:**
- Create: `platform/kong/manifests/jwt-auth-plugin.yaml`
- Create: `platform/kong/manifests/zitadel-issuer-consumer.yaml`
- Create: `platform/kong/manifests/zitadel-jwt-key.yaml` (plain Secret — public key material)
- Modify: `platform/kong/manifests/kustomization.yaml`

**Interfaces:**
- Consumes: live JWKS from Task 6.
- Produces: KongClusterPlugin `jwt-auth` — any user-facing Ingress binds it with the annotation `konghq.com/plugins: jwt-auth` (the platform convention, documented in Task 14).

- [ ] **Step 1: Extract the active signing key from JWKS**

```bash
pip3 install --quiet cryptography 2>/dev/null || pip3 install --user cryptography
curl -s https://id.algovn.com/oauth/v2/keys | python3 -c '
import json,base64,sys
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicNumbers
from cryptography.hazmat.primitives.serialization import Encoding,PublicFormat
jwk=json.load(sys.stdin)["keys"][0]
def b2i(s): return int.from_bytes(base64.urlsafe_b64decode(s+"="*(-len(s)%4)),"big")
pem=RSAPublicNumbers(b2i(jwk["e"]),b2i(jwk["n"])).public_key().public_bytes(Encoding.PEM,PublicFormat.SubjectPublicKeyInfo).decode()
print("KID:",jwk["kid"]); print(pem)'
```
Expected: a `KID: <value>` line and a `-----BEGIN PUBLIC KEY-----` PEM block. Record both.

- [ ] **Step 2: Write manifests**

`platform/kong/manifests/jwt-auth-plugin.yaml`:
```yaml
apiVersion: configuration.konghq.com/v1
kind: KongClusterPlugin
metadata:
  name: jwt-auth
  annotations:
    kubernetes.io/ingress.class: kong
plugin: jwt
config:
  key_claim_name: kid          # match credentials by the token header kid → overlap rotation works
  claims_to_verify: [exp]
```

`platform/kong/manifests/zitadel-jwt-key.yaml` (public key — plain Secret is correct here, gitleaks-safe):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: zitadel-jwt-<KID>       # substitute: zitadel-jwt-<first 8 chars of kid, lowercased>
  namespace: kong
  labels:
    konghq.com/credential: jwt
stringData:
  algorithm: RS256
  key: "<KID>"                  # full kid value from Step 1
  rsa_public_key: |
    -----BEGIN PUBLIC KEY-----
    <PEM lines from Step 1>
    -----END PUBLIC KEY-----
```

`platform/kong/manifests/zitadel-issuer-consumer.yaml`:
```yaml
apiVersion: configuration.konghq.com/v1
kind: KongConsumer
metadata:
  name: zitadel-issuer
  namespace: kong
  annotations:
    kubernetes.io/ingress.class: kong
username: zitadel-issuer
credentials:
  - zitadel-jwt-<KID>           # same name as the Secret above
```

Add all three files to `platform/kong/manifests/kustomization.yaml` resources.

- [ ] **Step 3: Validate, commit, push, sync**

Run: `scripts/validate.sh` → `PASS` (gitleaks must NOT flag the public key; if it does, the finding is a false positive on `BEGIN PUBLIC KEY` — allowlist that path in `.gitleaks.toml` with a comment, never commit private-key-shaped content).
```bash
git add platform/kong/manifests/jwt-auth-plugin.yaml platform/kong/manifests/zitadel-issuer-consumer.yaml platform/kong/manifests/zitadel-jwt-key.yaml platform/kong/manifests/kustomization.yaml
git commit -m "feat(kong): edge JWT validation — zitadel issuer consumer + jwt-auth plugin"
git push
ssh pi 'argocd app sync kong --core && argocd app wait kong --core --timeout 300'
```
Expected: Synced/Healthy; KIC logs show no translation errors: `ssh pi 'kubectl logs -n kong -l app.kubernetes.io/name=controller --tail=20'` contains no `invalid` mentions of `zitadel-issuer`.

---

### Task 9: Edge-gate e2e (spec §8.4) + key-rotation drill (spec §8.7)

**Files:**
- Create: `docs/runbooks/zitadel-key-rotation.md`
- Modify: `platform/kong/manifests/zitadel-issuer-consumer.yaml` + key Secrets (during rotation)

**Interfaces:**
- Consumes: `jwt-auth` plugin (Task 8), `iam-admin-sa` PAT (Task 7).

- [ ] **Step 1: Mint a real access token (client credentials via service user)**

(USER, console) In org AlgoVN: create service user `e2e-test` with **Access Token Type: JWT** (critical — Zitadel's default Bearer tokens are opaque and can never pass a signature-checking gate), then Actions → Generate Client Secret. Record client id/secret temporarily.
```bash
export ZTOK=$(curl -s -X POST https://id.algovn.com/oauth/v2/token \
  -d grant_type=client_credentials -d scope=openid \
  -u '<client_id>:<client_secret>' | jq -r .access_token)
echo ${ZTOK:0:20}   # non-empty prefix
```
Expected: a JWT prefix (`eyJ...`). Note: service-user tokens are JWTs signed by the same web key — exactly what the gate validates.

- [ ] **Step 2: Throwaway protected route (kubectl, not git — Kong-spec e2e pattern)**

```bash
ssh pi 'kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jwt-e2e
  namespace: homepage
  annotations:
    konghq.com/plugins: jwt-auth
spec:
  ingressClassName: kong
  rules:
    - host: jwt-e2e.algovn.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: homepage
                port: { number: 80 }
  tls:
    - hosts: [jwt-e2e.algovn.com]
EOF'
```

- [ ] **Step 3: Run the gate matrix (LAN --resolve avoids DNS wait)**

```bash
H="--resolve jwt-e2e.algovn.com:443:192.168.102.200"
curl -s -o /dev/null -w '%{http_code}\n' $H https://jwt-e2e.algovn.com/                                    # expect 401
curl -s -o /dev/null -w '%{http_code}\n' $H -H "Authorization: Bearer garbage" https://jwt-e2e.algovn.com/  # expect 401
curl -s -o /dev/null -w '%{http_code}\n' $H -H "Authorization: Bearer $ZTOK" https://jwt-e2e.algovn.com/    # expect 200
```
Expected: `401`, `401`, `200`. (Expired-token case is covered by `claims_to_verify: [exp]` + the garbage case; optionally re-run the third curl after token expiry for completeness.)

- [ ] **Step 4: Write `docs/runbooks/zitadel-key-rotation.md`**

```markdown
# Zitadel signing-key rotation (Kong pins the public key)
Kong OSS can't fetch JWKS; the active public key is a committed Secret in
platform/kong/manifests/. Rotation is DELIBERATE and zero-downtime (jwt plugin matches
credentials by token kid — old+new coexist). PAT: password manager `zitadel-iam-admin-sa-pat`.
Drill last passed: <date>.

1. Create the new web key:
   curl -s -X POST -H "Authorization: Bearer $ZPAT" -H "Content-Type: application/json" \
     https://id.algovn.com/v2beta/web_keys -d '{"rsa":{}}'   # RSA defaults (2048/SHA256)
   → note returned id. GET https://id.algovn.com/oauth/v2/keys now lists 2 keys.
2. Extract new kid+PEM (task-8 python one-liner works; pick keys[] entry with the new kid),
   add Secret platform/kong/manifests/zitadel-jwt-<newkid8>.yaml (copy existing file's shape),
   append its name to the consumer's credentials list, add to kustomization, validate, push,
   `argocd app sync kong --core`.
3. Activate: curl -s -X POST -H "Authorization: Bearer $ZPAT" \
     https://id.algovn.com/v2beta/web_keys/<id>/activate
   New tokens now carry the new kid; old tokens keep validating (old credential still present).
4. Soak ≥ max token lifetime (default 12h access tokens), then delete the retired web key:
   curl -s -X DELETE -H "Authorization: Bearer $ZPAT" https://id.algovn.com/v2beta/web_keys/<oldid>
   and remove the old Secret + credentials entry from git; push, sync.
5. Verify: mint fresh token (client_credentials) → protected route 200; JWKS shows 1 key.
If the API paths 404 (Zitadel upgrade moved them): https://zitadel.com/docs/apis/resources/webkey_service_v2
```

- [ ] **Step 5: Execute the rotation drill end-to-end**

Follow the runbook steps 1–5 exactly (steps 2/4 are real git commits: `feat(kong): rotate zitadel signing key — add <newkid8>` / `chore(kong): retire zitadel signing key <oldkid8>`), except compress the soak: after activation, immediately verify BOTH a pre-rotation token (minted in Step 1, still unexpired → 200) and a freshly minted token (new kid → 200) against the throwaway route — that proves the no-401-window claim; then proceed to retire the old key.
Expected: 200s throughout; final JWKS `keys | length` == 1. Update the runbook's "Drill last passed" date.

- [ ] **Step 6: Clean up**

```bash
ssh pi 'kubectl delete ingress jwt-e2e -n homepage'
```
(USER, console) Delete service user `e2e-test`'s client secret if you don't want it lingering — or keep the user for Task 13's checks; it's deleted for good in Task 15.

```bash
git add docs/runbooks/zitadel-key-rotation.md
git commit -m "docs: zitadel key-rotation runbook (drill passed, no 401 window)"
git push
```

---

### Task 10: OpenFGA database + sealed secrets

**Files:**
- Modify: `platform/postgres/manifests/cluster.yaml` (`managed.roles` += openfga)
- Create: `platform/postgres/manifests/db-openfga.yaml`
- Create: `platform/postgres/manifests/pg-role-openfga-sealed.yaml` (sealed)
- Create: `platform/openfga/manifests/openfga-datastore-sealed.yaml` (sealed, key `uri`)
- Create: `platform/openfga/manifests/openfga-preshared-sealed.yaml` (sealed, key `keys`)
- Modify: `platform/postgres/manifests/kustomization.yaml`

**Interfaces:**
- Produces: DB `openfga`/role `openfga`; Secrets in ns `openfga`: `openfga-datastore` (key `uri` = full DSN), `openfga-preshared` (key `keys` = comma-separated API tokens; we use one). Task 11 values reference these names; Task 12/14 clients use the preshared key.

- [ ] **Step 1: Generate + seal**

```bash
openssl rand -base64 24 | tr -d "[:space:]" > ~/.secrets/openfga-pg-pw
openssl rand -hex 32   | tr -d "[:space:]" > ~/.secrets/openfga-api-key
# role secret (ns postgres)
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=\$HOME/.kube/config; kubectl create secret generic pg-role-openfga -n postgres --type=kubernetes.io/basic-auth --from-literal=username=openfga --from-file=password=/dev/stdin --dry-run=client -o yaml | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml"' < ~/.secrets/openfga-pg-pw > platform/postgres/manifests/pg-role-openfga-sealed.yaml
# DSN (ns openfga)
printf 'postgresql://openfga:%s@pg-rw.postgres.svc:5432/openfga?sslmode=disable' "$(cat ~/.secrets/openfga-pg-pw)" | ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=\$HOME/.kube/config; kubectl create secret generic openfga-datastore -n openfga --from-file=uri=/dev/stdin --dry-run=client -o yaml | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml"' > platform/openfga/manifests/openfga-datastore-sealed.yaml
# preshared API key (ns openfga)
ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=\$HOME/.kube/config; kubectl create secret generic openfga-preshared -n openfga --from-file=keys=/dev/stdin --dry-run=client -o yaml | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml"' < ~/.secrets/openfga-api-key > platform/openfga/manifests/openfga-preshared-sealed.yaml
```

- [ ] **Step 2 (USER): Store `openfga-api-key` in the password manager** (apps will also get it via per-app sealed copies later; rotation = reseal both sides, postgres.md warning applies).

Then cleanup plaintext:
```bash
for f in openfga-pg-pw openfga-api-key; do dd if=/dev/urandom of=~/.secrets/$f bs=1 count=$(stat -f%z ~/.secrets/$f) conv=notrunc && rm -f ~/.secrets/$f; done
```

- [ ] **Step 3: Declare role + database**

`platform/postgres/manifests/cluster.yaml` → append to `spec.managed.roles`:
```yaml
      - name: openfga
        ensure: present
        login: true
        passwordSecret: { name: pg-role-openfga }
```

`platform/postgres/manifests/db-openfga.yaml`:
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: openfga
  namespace: postgres
spec:
  name: openfga
  owner: openfga
  cluster: { name: pg }
```

Add `db-openfga.yaml` + `pg-role-openfga-sealed.yaml` to the postgres kustomization resources.

- [ ] **Step 4: Validate, commit, push, verify**

Run: `scripts/validate.sh` → `PASS`
```bash
git add platform/postgres/manifests/cluster.yaml platform/postgres/manifests/db-openfga.yaml platform/postgres/manifests/pg-role-openfga-sealed.yaml platform/postgres/manifests/kustomization.yaml platform/openfga/manifests/openfga-datastore-sealed.yaml platform/openfga/manifests/openfga-preshared-sealed.yaml
git commit -m "feat(openfga): provision openfga database, role, and sealed secrets"
git push
ssh pi 'argocd app sync postgres --core && kubectl get database openfga -n postgres'
```
Expected: Database `openfga` ready.

---

### Task 11: OpenFGA platform component + deploy

**Files:**
- Create: `platform/openfga/values.yaml`
- Create: `platform/openfga/manifests/kustomization.yaml`
- Create: `platform/openfga/manifests/service-grpc.yaml`
- Create: `platform/openfga/manifests/podscrape.yaml`
- Create: `clusters/algovn/platform/openfga.yaml`

**Interfaces:**
- Consumes: secret names from Task 10.
- Produces: gRPC endpoint `dns:///openfga-grpc.openfga.svc.cluster.local:9090` (conventions-conformant) and HTTP `http://openfga.openfga.svc:8080` — consumed by Task 12 e2e and every future app (Task 14 doc).

- [ ] **Step 1: Write `platform/openfga/values.yaml`**

```yaml
replicaCount: 1
datastore:
  engine: postgres
  uriSecret: openfga-datastore     # key: uri
  applyMigrations: true
  waitForMigrations: true
authn:
  method: preshared
  preshared:
    keysSecret: openfga-preshared  # key: keys
playground:
  enabled: false
telemetry:
  metrics:
    enabled: true                  # 0.0.0.0:2112, container port name: metrics
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits: { memory: 192Mi }
```

- [ ] **Step 2: Manifests**

`platform/openfga/manifests/service-grpc.yaml` (headless, conventions port 9090 — chart's own Service keeps 8080/8081 for HTTP+migrations):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: openfga-grpc
  namespace: openfga
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: openfga
    app.kubernetes.io/instance: openfga
  ports:
    - { port: 9090, targetPort: grpc, name: grpc }
```

`platform/openfga/manifests/podscrape.yaml`:
```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMPodScrape
metadata:
  name: openfga
  namespace: monitoring
spec:
  namespaceSelector: { matchNames: [openfga] }
  selector:
    matchLabels: { app.kubernetes.io/name: openfga }
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
```

`platform/openfga/manifests/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - openfga-datastore-sealed.yaml
  - openfga-preshared-sealed.yaml
  - service-grpc.yaml
  - podscrape.yaml
```

`clusters/algovn/platform/openfga.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openfga
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  sources:
    - repoURL: https://openfga.github.io/helm-charts
      chart: openfga
      targetRevision: 0.3.10
      helm:
        releaseName: openfga
        valueFiles:
          - $values/platform/openfga/values.yaml
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      ref: values
    - repoURL: https://github.com/the-algovn/iac.git
      targetRevision: main
      path: platform/openfga/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: openfga
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
    retry:
      limit: 5
      backoff: { duration: 30s, factor: 2, maxDuration: 5m }
```

- [ ] **Step 3: Validate, commit, push, sync**

Run: `scripts/validate.sh` → `PASS`
```bash
git add platform/openfga/values.yaml platform/openfga/manifests/kustomization.yaml platform/openfga/manifests/service-grpc.yaml platform/openfga/manifests/podscrape.yaml clusters/algovn/platform/openfga.yaml
git commit -m "feat(openfga): platform component — chart 0.3.10, preshared auth, grpc :9090"
git push
ssh pi 'argocd app sync openfga --core && argocd app wait openfga --core --timeout 600'
```
Expected: Synced/Healthy; migration job Completed; `kubectl get pods -n openfga` shows openfga `1/1 Running`.

- [ ] **Step 4: gRPC health + endpoints check (conventions-style)**

```bash
ssh pi 'kubectl run grpc-check --rm -i --restart=Never --image=fullstorydev/grpcurl:latest -n openfga -- -plaintext openfga-grpc.openfga.svc.cluster.local:9090 grpc.health.v1.Health/Check'
```
Expected: `{ "status": "SERVING" }` (health endpoint is unauthenticated; data APIs require the preshared key).

---

### Task 12: OpenFGA e2e — model, tuple, Check (spec §8.6)

Throwaway store via HTTP API from in-cluster (curl image; the fga CLI image lacks a shell for heredocs). Deleted at the end — nothing persists.

**Files:** none.

**Interfaces:**
- Consumes: `openfga-preshared` key (read from the live secret), HTTP svc `openfga.openfga.svc:8080`.

- [ ] **Step 1: Write the e2e script locally and ship it to the Pi**

```bash
cat > /tmp/fga-e2e.sh <<'SCRIPT'
set -e
A="Authorization: Bearer $FGAKEY"; U=http://openfga.openfga.svc:8080
SID=$(curl -sf -H "$A" -X POST $U/stores -d '{"name":"e2e"}' | sed 's/.*"id":"\([^"]*\)".*/\1/')
echo "STORE $SID"
MID=$(curl -sf -H "$A" -X POST $U/stores/$SID/authorization-models -d '{
 "schema_version":"1.1",
 "type_definitions":[
  {"type":"user"},
  {"type":"org","relations":{"member":{"this":{}}},
   "metadata":{"relations":{"member":{"directly_related_user_types":[{"type":"user"}]}}}},
  {"type":"doc",
   "relations":{
    "parent_org":{"this":{}},
    "owner":{"this":{}},
    "viewer":{"union":{"child":[
      {"computedUserset":{"relation":"owner"}},
      {"tupleToUserset":{"tupleset":{"relation":"parent_org"},"computedUserset":{"relation":"member"}}}]}}},
   "metadata":{"relations":{
    "parent_org":{"directly_related_user_types":[{"type":"org"}]},
    "owner":{"directly_related_user_types":[{"type":"user"}]},
    "viewer":{"directly_related_user_types":[]}}}}]}' | sed 's/.*"authorization_model_id":"\([^"]*\)".*/\1/')
echo "MODEL $MID"
curl -sf -H "$A" -X POST $U/stores/$SID/write -d '{"writes":{"tuple_keys":[{"user":"user:alice","relation":"member","object":"org:acme"},{"user":"org:acme","relation":"parent_org","object":"doc:readme"}]}}' > /dev/null
printf 'CHECK-ALLOW: '; curl -sf -H "$A" -X POST $U/stores/$SID/check -d '{"tuple_key":{"user":"user:alice","relation":"viewer","object":"doc:readme"}}'; echo
curl -sf -H "$A" -X POST $U/stores/$SID/write -d '{"deletes":{"tuple_keys":[{"user":"user:alice","relation":"member","object":"org:acme"}]}}' > /dev/null
printf 'CHECK-DENY: '; curl -sf -H "$A" -X POST $U/stores/$SID/check -d '{"tuple_key":{"user":"user:alice","relation":"viewer","object":"doc:readme"}}'; echo
curl -sf -H "$A" -X DELETE $U/stores/$SID > /dev/null && echo STORE-DELETED
SCRIPT
scp /tmp/fga-e2e.sh pi:/tmp/fga-e2e.sh
```

- [ ] **Step 2: Run it in-cluster**

```bash
ssh pi 'FGAKEY=$(kubectl get secret openfga-preshared -n openfga -o jsonpath="{.data.keys}" | base64 -d) && kubectl run fga-e2e --rm -i --restart=Never --image=curlimages/curl:latest -n openfga --env FGAKEY=$FGAKEY --command -- sh -s < /tmp/fga-e2e.sh'
```
(`--command -- sh -s` overrides the image's `curl` entrypoint; `-i` feeds the script on stdin.)
Expected output lines: `STORE <id>`, `MODEL <id>`, `CHECK-ALLOW: {"allowed":true...}`, `CHECK-DENY: {"allowed":false...}`, `STORE-DELETED`. Clean up: `rm /tmp/fga-e2e.sh; ssh pi 'rm /tmp/fga-e2e.sh'`.

- [ ] **Step 3: Negative auth check (preshared key enforced)**

```bash
ssh pi 'kubectl run fga-noauth --rm -i --restart=Never --image=curlimages/curl:latest -n openfga -- -s -o /dev/null -w "%{http_code}\n" -X POST http://openfga.openfga.svc:8080/stores -d "{\"name\":\"x\"}"'
```
Expected: `401`.

---

### Task 13: SSO + role-claim verification (spec §8.3, §8.5)

Uses the device authorization grant — real browser login (login v2), fully scriptable token retrieval, and a natural SSO probe (second flow must skip credentials).

**Files:** none (console steps recorded as extensions of the zitadel runbook in Task 14's conventions doc).

**Interfaces:**
- Consumes: live login (Task 7); produces evidence only.

- [ ] **Step 1 (USER, console): Create test fixtures in org AlgoVN**

Projects → New `platform-e2e` → check **Assert Roles on Authentication**; Roles → add key `admin`. Applications → New → Native, name `e2e-device`, auth method NONE, enable **Device Code** grant, and in Token Settings set **Auth Token Type: JWT** (default Bearer is opaque — would fail the Kong gate and the claim-decode step) → note client id. Users → your admin user → Authorizations → add project `platform-e2e` role `admin`.

- [ ] **Step 2: Device flow login #1 (fresh browser profile)**

```bash
CID=<e2e-device client id>
R=$(curl -s -X POST https://id.algovn.com/oauth/v2/device_authorization -d client_id=$CID -d 'scope=openid profile urn:zitadel:iam:org:projects:roles')
echo $R | jq -r '.verification_uri_complete'   # open this in a FRESH private window
DC=$(echo $R | jq -r .device_code)
```
(USER) Open the printed URL, log in with **passkey**, approve.
```bash
TOK=$(curl -s -X POST https://id.algovn.com/oauth/v2/token -d grant_type=urn:ietf:params:oauth:grant-type:device_code -d device_code=$DC -d client_id=$CID)
echo $TOK | jq -r .access_token | cut -d. -f2 | python3 -c 'import sys,base64,json; s=sys.stdin.read().strip(); print(json.dumps(json.loads(base64.urlsafe_b64decode(s+"="*(-len(s)%4))), indent=2))'
```
Expected (spec §8.5): payload contains `"urn:zitadel:iam:org:project:roles"` (or the `...:projects:roles` aggregate form) including key `admin`, plus `iss: https://id.algovn.com`.

- [ ] **Step 3: SSO probe — device flow #2 in the SAME browser window (spec §8.3)**

Re-run Step 2's device_authorization curl, open the new `verification_uri_complete` in the **same** browser window (not private-new): the flow must complete with **no credential prompt** (session reused; at most a consent/confirm click).
Expected: token retrieved without re-authentication → SSO confirmed.

- [ ] **Step 4: Bonus — confirm the device-flow token passes the Kong gate**

Re-apply the Task 9 throwaway ingress, curl with this token → 200, delete ingress. (Optional but cheap; proves human-user tokens — not just service-user tokens — pass the edge gate.)

---

### Task 14: `docs/authnz-conventions.md` — the contract apps code against

**Files:**
- Create: `docs/authnz-conventions.md`

**Interfaces:**
- Consumes: everything above; Produces: the onboarding contract (sibling of `grpc-conventions.md`).

- [ ] **Step 1: Write the doc**

```markdown
# AuthN/Z conventions
Spec: docs/superpowers/specs/2026-07-13-authnz-foundation-design.md. Zitadel (id.algovn.com)
owns WHO YOU ARE (users, orgs, org roles → in the token). OpenFGA owns WHAT YOU CAN TOUCH
(per-resource relations). Kong's `jwt-auth` plugin is the edge gate. Runbooks: zitadel.md,
zitadel-key-rotation.md.

## Protecting a route (edge gate)
Ingress annotation: `konghq.com/plugins: jwt-auth`. Kong 401s missing/invalid/expired
tokens (RS256, kid-matched against the committed public key). Machine routes keep key-auth.

## What your service does with the token
Kong verified the SIGNATURE; your service still parses the payload for identity (read-only
base64 decode of segment 2 — do NOT re-verify, do NOT skip parsing):
- `sub` — stable user id ・ `iss` must be https://id.algovn.com (assert it)
- `urn:zitadel:iam:org:project:roles` — {role: {orgID: orgDomain}} (needs project
  "Assert Roles on Authentication" + scope `urn:zitadel:iam:org:projects:roles`)
- `urn:zitadel:iam:user:resourceowner:id` — the user's org id
Role checks (org-level, coarse) happen HERE from claims. Per-resource checks go to OpenFGA.
Never invent per-app auth: no local users, no password fields, no API-issued sessions.

## Registering a product (console, org AlgoVN — see zitadel.md)
1. Project `<product>` (+ check Assert Roles) with roles it needs (keep coarse: admin/member).
2. Applications in that project: SPA → Web + PKCE (no secret); CLI → Native + device code;
   server → Web + client secret, or service user for M2M.
   ⚠️ EVERY app/service-user whose tokens must pass the Kong gate needs
   **Auth/Access Token Type: JWT** (Zitadel's default is opaque Bearer → edge 401).
3. Customer orgs get the project via Project Grants; users get role Authorizations.

## OpenFGA
- Endpoints (cluster-internal ONLY): gRPC dns:///openfga-grpc.openfga.svc.cluster.local:9090
  (deadline 5s, round_robin — grpc-conventions.md applies), HTTP http://openfga.openfga.svc:8080.
- Auth: preshared key. Seal a copy into your app's ns (postgres.md double-seal pattern;
  rotation = reseal everywhere, source of truth in password manager `openfga-api-key`).
- One STORE per product, created at onboarding: use the HTTP API or fga CLI (see the e2e
  transcript in the authnz plan Task 12 for exact calls). Record the store id in app config.
- The MODEL (.fga DSL) lives in the product repo; CI applies it; the app PINS the returned
  authorization_model_id and passes it on every Check/Write (immutable model versions —
  same rule as protos: never mutate, always add).
- Single writer: only the owning app writes its store's tuples (on resource create/share/delete).
- Org bridge: on login, JIT-write org:<orgid>#member@user:<sub> from token claims if your
  model needs `member from parent_org`. Mirror MEMBERSHIP only — org roles stay in the token.
- Enforce with Check AT THE API BOUNDARY (UI hiding is cosmetics). ListObjects for listings,
  sparingly.

## Go snippets
Claims (after Kong):
    type ZClaims struct {
        Sub string `json:"sub"`
        Iss string `json:"iss"`
        Roles map[string]map[string]string `json:"urn:zitadel:iam:org:project:roles"`
    }
    seg := strings.Split(bearer, ".")[1]
    b, _ := base64.RawURLEncoding.DecodeString(seg)
    var c ZClaims; json.Unmarshal(b, &c)   // assert c.Iss == "https://id.algovn.com"
FGA check (github.com/openfga/go-sdk/client):
    fga, _ := client.NewSdkClient(&client.ClientConfiguration{
        ApiUrl: "http://openfga.openfga.svc:8080", StoreId: storeID,
        AuthorizationModelId: modelID,
        Credentials: &credentials.Credentials{Method: credentials.CredentialsMethodApiToken,
            Config: &credentials.Config{ApiToken: os.Getenv("FGA_API_KEY")}}})
    ctx, cancel := context.WithTimeout(ctx, 5*time.Second); defer cancel()
    ok, _ := fga.Check(ctx).Body(client.ClientCheckRequest{
        User: "user:"+c.Sub, Relation: "viewer", Object: "doc:"+id}).Execute()
    if !ok.GetAllowed() { /* 403 */ }
(gRPC client instead of HTTP is fine too — port 9090, same preshared key via
PerRPCCredentials; HTTP SDK shown because it's the shortest correct thing.)

## Deferred (spec §9)
Custom login app (design system) · per-user rate limiting · JWKS auto-sync · SMTP flows ·
Terraformed IdP config · FGA HA.
```

- [ ] **Step 2: Cross-link + commit**

Add to `docs/grpc-conventions.md` under `## Exposure` a final line:
```markdown
- User-facing HTTP routes are protected by the Kong `jwt-auth` plugin — see `docs/authnz-conventions.md`.
```

```bash
git add docs/authnz-conventions.md docs/grpc-conventions.md
git commit -m "docs: authN/Z conventions — token contract, FGA store/model rules, onboarding"
git push
```

---

### Task 15: Final sweep — dashboard, verify.md, README, headroom gate (spec §8.9–§8.10)

**Files:**
- Create: `platform/monitoring/manifests/authnz-dashboard-cm.yaml`
- Modify: `platform/monitoring/manifests/kustomization.yaml`
- Modify: `docs/runbooks/verify.md`
- Modify: `README.md`

**Interfaces:** none (terminal task).

- [ ] **Step 1: AuthN/Z dashboard (guaranteed metrics only: up/container/cnpg)**

`platform/monitoring/manifests/authnz-dashboard-cm.yaml` (same provisioning label pattern as `kong-dashboard-cm.yaml` — copy its `metadata.labels` block verbatim):
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: authnz-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"   # same provisioning label as kong-dashboard-cm.yaml (verified)
data:
  authnz.json: |
    {
      "uid": "authnz", "title": "AuthN/Z", "schemaVersion": 39, "refresh": "1m",
      "time": { "from": "now-6h", "to": "now" },
      "panels": [
        { "id": 1, "type": "stat", "title": "Components up",
          "gridPos": { "h": 6, "w": 8, "x": 0, "y": 0 },
          "targets": [ { "expr": "sum(up{namespace=~\"zitadel|openfga\"})" } ] },
        { "id": 2, "type": "stat", "title": "Hours since last pg backup",
          "gridPos": { "h": 6, "w": 8, "x": 8, "y": 0 },
          "targets": [ { "expr": "(time() - cnpg_collector_last_available_backup_timestamp{cluster=\"pg\"}) / 3600" } ] },
        { "id": 3, "type": "timeseries", "title": "Memory (working set)",
          "gridPos": { "h": 8, "w": 12, "x": 0, "y": 6 },
          "targets": [ { "expr": "sum by (pod) (container_memory_working_set_bytes{namespace=~\"zitadel|openfga\", container!=\"\"})", "legendFormat": "{{pod}}" } ] },
        { "id": 4, "type": "timeseries", "title": "CPU",
          "gridPos": { "h": 8, "w": 12, "x": 12, "y": 6 },
          "targets": [ { "expr": "sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=~\"zitadel|openfga\", container!=\"\"}[5m]))", "legendFormat": "{{pod}}" } ] }
      ]
    }
```
Add `authnz-dashboard-cm.yaml` to the monitoring kustomization resources.

- [ ] **Step 2: verify.md additions**

Append to `docs/runbooks/verify.md`:
```markdown
## AuthN/Z (spec 2026-07-13)
- `curl -s https://id.algovn.com/.well-known/openid-configuration | jq -r .issuer` → `https://id.algovn.com`
- Login page renders: https://id.algovn.com/ui/v2/login (passkey/social only — no password field)
- Edge gate: any `konghq.com/plugins: jwt-auth` route → 401 bare / 200 with fresh token
- `kubectl get backup -n postgres --sort-by=.metadata.creationTimestamp` → newest < 26h, phase completed
- OpenFGA: grpcurl health check == SERVING (see authnz plan Task 11 Step 4)
- Grafana dashboard "AuthN/Z" renders with live data
```

- [ ] **Step 3: README status line**

Append to `README.md` `## Status`:
```markdown
AuthN/Z foundation live (Zitadel 9.34.0 chart @ id.algovn.com + OpenFGA 0.3.10, Kong jwt edge gate, pg backups → R2) — <completion date>, spec docs/superpowers/specs/2026-07-13-authnz-foundation-design.md, conventions docs/authnz-conventions.md.
```

- [ ] **Step 4: Headroom gate (spec §8.9) + Loki logs (spec §8.10)**

```bash
ssh pi 'free -h'
ssh ducle@192.168.102.201 'free -h' 2>/dev/null || ssh w1 'free -h'
```
Expected: `available` ≥ 250Mi on BOTH nodes. If breached: pressure valves (Kong spec §5 — disable VM defaultDashboards, trim vmsingle limits) before sign-off.

Loki: in Grafana → Explore → `{namespace="zitadel"}` and `{namespace="openfga"}` return recent lines.

- [ ] **Step 5: Full-platform green check**

```bash
ssh pi 'argocd app list --core -o name | xargs -I{} argocd app get {} --core --refresh -o json' | jq -r '"\(.metadata.name): \(.status.sync.status)/\(.status.health.status)"'
```
Expected: every app `Synced/Healthy` (incl. new: barman-cloud, zitadel, openfga).

(USER, console) Delete the `e2e-test` service user and the `platform-e2e` project + `e2e-device` app if you want zero test fixtures — or keep them as living examples; note the choice in zitadel.md.

- [ ] **Step 6: Validate, commit, push**

Run: `scripts/validate.sh` → `PASS`
```bash
git add platform/monitoring/manifests/authnz-dashboard-cm.yaml platform/monitoring/manifests/kustomization.yaml docs/runbooks/verify.md README.md
git commit -m "feat(authnz): dashboard, verify checklist, README status — foundation complete"
git push
ssh pi 'argocd app sync monitoring --core'
```
Expected: monitoring Synced/Healthy; dashboard visible in Grafana.

---

## Spec-coverage map (self-check)

| Spec item | Task |
|---|---|
| §4 edge gate + kid matching | 8, 9 |
| §5 identity model, IdPs, passwordless, orgs | 7 |
| §6 FGA store/model/tuple conventions | 12, 14 |
| §7 GitOps shape, DBs, resources, backups, observability | 1–5, 10–11, 15 |
| §8.1 discovery/login | 6 |
| §8.2 social + passkey e2e | 7 |
| §8.3 SSO / §8.5 role claim | 13 |
| §8.4 edge-gate 401/200 | 9 |
| §8.6 FGA check | 12 |
| §8.7 rotation drill | 9 |
| §8.8 backup + restore drill + alert | 2, 3 |
| §8.9 headroom / §8.10 metrics-dashboards-logs | 6, 11, 15 |
| Out of scope guards (no SMTP, no CF-Access migration, validate-only Kong) | respected throughout |
