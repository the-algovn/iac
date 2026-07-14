# Postgres (CloudNativePG)
Shared single-instance PostgreSQL 18 cluster `pg`, ns `postgres` (operator `cnpg` 1.30.0 in ns `cnpg-system`).
⚠️ NO BACKUPS (decision 2026-07-12) — node/disk loss = data loss. Follow-up before anything
irreplaceable lands here: WAL archiving + base backups to Cloudflare R2 (CNPG Barman Cloud plugin).
(2026-07-13: zitadel/openfga data landed; risk re-accepted — see README + authnz spec §7.)

## Connect
In-cluster: `pg-rw.postgres.svc:5432`. LAN: `192.168.102.112:5432` (svclb `pg-lb`; node IPs are algovn `.111` / algovn-w1 `.112`).
w1's ufw is currently INACTIVE (verified 2026-07-12) — no firewall rule needed today; if ufw is ever
enabled on w1, allow 5432/tcp from 192.168.102.0/24.
Admin password: `kubectl get secret -n postgres pg-superuser -o jsonpath='{.data.password}' | base64 -d`
In-pod psql (no password): `kubectl exec -it -n postgres pg-1 -c postgres -- psql -U postgres`
Default bootstrap created DB `app`/role `app` (secret `pg-app`); it's unmanaged and shows as `"not-managed": ["app"]` in managedRolesStatus. Don't name a future app "app"; drop via in-pod psql if unwanted.

## Add an app database (all declarative, no manual psql)
Secrets go through OpenBao + External Secrets Operator — full procedure in
`docs/runbooks/secrets.md`.
1. Password: `openssl rand -base64 24 | tr -d "[:space:]" > ~/.secrets/<app>-pw` (chmod 700 dir).
2. Write the password to bao TWICE — same password, two KV paths (see docs/runbooks/secrets.md for
   the write command via `ssh root@192.168.102.100`):
   `secret/algovn/postgres/pg-role-<app>` (fields `username`, `password`) and
   `secret/algovn/<appns>/<name>`. Then add the ExternalSecret manifests:
   `platform/postgres/manifests/pg-role-<app>-external.yaml` (target secret type
   `kubernetes.io/basic-auth`, ClusterSecretStore `bao`) and `apps/<app>/pg-credentials-external.yaml`
   (app reads username/password keys).
   ⚠️ The ns-postgres KV entry holds the RAW password (CNPG consumes it as basic-auth). If the app
   secret instead embeds the password in a URI (`postgres://user:pw@host/db`, `redis://:pw@host` —
   e.g. the-button's `pg-the-button`/`uri`, `redis-creds`/`url`), PERCENT-ENCODE it first:
   `python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$PW"`
   — base64 passwords contain `/` and `+`, which break URI parsing raw. The two KV entries are
   deliberately different encodings of the same password, not copies of each other.
3. `platform/postgres/manifests/cluster.yaml` → `spec.managed.roles` += `{name: <app>, ensure: present, login: true, passwordSecret: {name: pg-role-<app>}}`
4. `platform/postgres/manifests/db-<app>.yaml` → Database CR (spec.name/owner `<app>`, cluster.name `pg`); add both new files to the kustomization.
5. `scripts/validate.sh`, push, `argocd app wait postgres --core`.
6. Cleanup local plaintext: macOS has no `shred` — overwrite then remove:
   `dd if=/dev/urandom of=~/.secrets/<app>-pw bs=1 count=$(stat -f%z ~/.secrets/<app>-pw) conv=notrunc && rm -f ~/.secrets/<app>-pw`
Verify: `kubectl get secret -n postgres pg-role-<app>` (missing = ExternalSecret not synced —
`kubectl describe externalsecret -n postgres pg-role-<app>` shows why, e.g. wrong KV path or field)
· `kubectl get database -n postgres <app>` · `kubectl get cluster pg -n
postgres -o jsonpath='{.status.managedRolesStatus}'`
Rotation: update BOTH bao KV entries (postgres + app ns paths) or DB and app silently diverge. If
the app copy is URI-shaped, redo the percent-encoding — don't copy the raw value across. Rotating
in bao does NOT restart pods (no reloader/checksum annotation in this cluster): `kubectl rollout
restart deploy/<app> -n <appns>`.

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
- `postgres` app SyncFailed after retry exhaustion (first bootstrap / slow ghcr pull): `argocd app sync postgres --core` on cp — automated sync won't re-attempt a failed revision.
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
