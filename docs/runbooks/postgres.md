# Postgres (CloudNativePG)
Shared single-instance PostgreSQL 18 cluster `pg`, ns `postgres` (operator `cnpg` 1.30.0 in ns `cnpg-system`).
⚠️ NO BACKUPS (decision 2026-07-12) — node/disk loss = data loss. Follow-up before anything
irreplaceable lands here: WAL archiving + base backups to Cloudflare R2 (CNPG Barman Cloud plugin).
(2026-07-13: zitadel/openfga data landed; risk re-accepted — see README + authnz spec §7.)

## Connect
In-cluster: `pg-rw.postgres.svc:5432`. LAN: `192.168.102.201:5432` (svclb `pg-lb`). Never `.200` — the Pi's hand-managed ufw blocks 5432 even though svclb advertises both node IPs.
w1's ufw is currently INACTIVE (verified 2026-07-12) — no firewall rule needed today; if ufw is ever
enabled on w1, allow 5432/tcp from 192.168.102.0/24.
Admin password: `kubectl get secret -n postgres pg-superuser -o jsonpath='{.data.password}' | base64 -d`
In-pod psql (no password): `kubectl exec -it -n postgres pg-1 -c postgres -- psql -U postgres`
Default bootstrap created DB `app`/role `app` (secret `pg-app`); it's unmanaged and shows as `"not-managed": ["app"]` in managedRolesStatus. Don't name a future app "app"; drop via in-pod psql if unwanted.

## Add an app database (all declarative, no manual psql)
Sealing needs `kubectl` + `kubeseal` — the Mac has neither; run the seal pipeline over ssh on the Pi
(password piped via stdin, never argv). `scripts/seal.sh` is the same `kubeseal` invocation for any
host that already has kubectl+kubeseal locally.
1. Password: `openssl rand -base64 24 | tr -d "[:space:]" > ~/.secrets/<app>-pw` (chmod 700 dir).
2. Seal TWICE — same password, two namespaces:
   ```
   ssh ducle@192.168.102.200 'bash -c "export KUBECONFIG=\$HOME/.kube/config; kubectl create secret generic pg-role-<app> -n postgres --type=kubernetes.io/basic-auth --from-literal=username=<app> --from-file=password=/dev/stdin --dry-run=client -o yaml | kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml"' < ~/.secrets/<app>-pw > platform/postgres/manifests/pg-role-<app>-sealed.yaml
   ```
   Repeat with `-n <appns>` (and secret/file name adjusted) → `apps/<app>/pg-credentials-sealed.yaml`
   (app reads username/password keys).
   ⚠️ The ns-postgres copy holds the RAW password (CNPG consumes it as basic-auth). If the app
   secret instead embeds the password in a URI (`postgres://user:pw@host/db`, `redis://:pw@host` —
   e.g. the-button's `pg-the-button`/`uri`, `redis-creds`/`url`), PERCENT-ENCODE it first:
   `python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$PW"`
   — base64 passwords contain `/` and `+`, which break URI parsing raw. The two sealed copies are
   deliberately different encodings of the same password, not copies of each other.
3. `platform/postgres/manifests/cluster.yaml` → `spec.managed.roles` += `{name: <app>, ensure: present, login: true, passwordSecret: {name: pg-role-<app>}}`
4. `platform/postgres/manifests/db-<app>.yaml` → Database CR (spec.name/owner `<app>`, cluster.name `pg`); add both new files to the kustomization.
5. `scripts/validate.sh`, push, `argocd app wait postgres --core`.
6. Cleanup local plaintext: macOS has no `shred` — overwrite then remove:
   `dd if=/dev/urandom of=~/.secrets/<app>-pw bs=1 count=$(stat -f%z ~/.secrets/<app>-pw) conv=notrunc && rm -f ~/.secrets/<app>-pw`
Verify (kubectl on the Pi prints a k3s-config permission warning on stderr — keep stderr separate,
never `2>&1 | head -1`): `kubectl get secret -n postgres pg-role-<app>` (missing = sealed for wrong
ns/name — sealing is ns+name-scoped and fails SILENTLY; `kubectl describe sealedsecret -n postgres
pg-role-<app>` shows why) · `kubectl get database -n postgres <app>` · `kubectl get cluster pg -n
postgres -o jsonpath='{.status.managedRolesStatus}'`
Rotation: update BOTH sealed copies (ns postgres + app ns) or DB and app silently diverge. If the
app copy is URI-shaped, redo the percent-encoding — don't copy the raw value across. Resealing does
NOT restart pods (no reloader/checksum annotation in this cluster): `kubectl rollout restart
deploy/<app> -n <appns>`.

## Remove an app database
Deleting the Database CR removes only the CR (`databaseReclaimPolicy: retain` default) — data stays.
Role sync is EVENT-DRIVEN (CNPG 1.30 reconciles managed roles only on a Cluster spec/generation
change) — a blocked role drop is NEVER retried periodically, and `argocd app sync` alone is a no-op
retrigger. Correct order:
1. Drop the DATABASE first (in-pod psql `DROP DATABASE <app>;`) — a role owning a database can't drop.
2. THEN set `ensure: absent` on the role entry and push — that spec change is what triggers the reconcile.
3. If the drop is blocked by ownership anyway, recovery is manual: in-pod psql `DROP ROLE IF EXISTS <app>;`.
4. Delete the role entry from git once reconciled.
A stale `status.managedRolesStatus.cannotReconcile` entry may linger after cleanup — cosmetic, clears
on the next real role change.

## Failure modes
- `postgres` app SyncFailed after retry exhaustion (first bootstrap / slow ghcr pull): `argocd app sync postgres --core` on the Pi — automated sync won't re-attempt a failed revision.
- Stuck retry loop on an OLD commit after fixing a failed revision: `argocd app terminate-op postgres --core` then `argocd app sync postgres --core`.
- App shows stale status after a fix: refresh the app directly — `argocd app get <app> --core --refresh` (refreshing root does not cascade to child apps).
- Manifests >256KiB (e.g. vendored Grafana dashboard ConfigMaps) need the per-resource annotation
  `argocd.argoproj.io/sync-options: ServerSideApply=true` — that's why `postgres-dashboard` carries it.
- Disk: local-path can NOT expand and does NOT enforce the 10Gi size — the real limit is w1's disk (shared with vmsingle/loki/uptime-kuma). Watch node fs on dashboard; growth path is manual dump/restore.
- NEVER label nodes `svccontroller.k3s.cattle.io/enablelb` — flips ALL svclb LBs (incl. Kong 80/443) into allow-list mode.
- Cluster CR carries `argocd.argoproj.io/sync-options: Prune=false` — deleting cluster.yaml in git will NOT delete the database (PV reclaim is Delete; this is the guardrail).

## Monitoring
VMPodScrape `postgres` (ns monitoring) scrapes `:9187/metrics` (`cnpg_*` series). vmsingle HTTP API:
svc `vmsingle-vm` port 8428. Grafana dashboard: "CloudNativePG" (uid `cloudnative-pg`, dashboard
20417, vendored ConfigMap `postgres-dashboard`).

## Upgrades
Operator: bump chart pin in `clusters/algovn/platform/cnpg.yaml` (watch CNPG EOL: 1.30.x ~Dec 2026).
PG minor: bump `imageName` tag in cluster.yaml (rolling restart). PG major: CNPG declarative offline
in-place upgrade — read the docs, plan it, don't wing it.
