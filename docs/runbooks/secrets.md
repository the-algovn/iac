# Secrets — OpenBao + External Secrets Operator

Since 2026-07-15 secrets live in **OpenBao** (Vault-compatible, LXC 124 `bao` on the
Proxmox host, `http://192.168.102.124:8200`) and reach the cluster via **External
Secrets Operator** (Argo app `external-secrets`, wave -5). The repo holds only
`*-external.yaml` ExternalSecret references — never secret material. The old
SealedSecrets system is gone; encrypted blobs in git history are permanently
undecryptable (key destroyed 2026-07-15).

## Layout

KV v2 mount `secret/`, everything under `secret/algovn/<namespace>/<name>`, one field
per k8s Secret key (dots in key names become underscores in KV fields:
`.dockerconfigjson` → `dockerconfigjson`, `credentials.json` → `credentials_json`).
Shared entries (single source, many consumers — replaces the old double-seal pattern):

- `shared/ghcr-pull` — GHCR pull `.dockerconfigjson` for all app namespaces + image-updater
- `shared/cloudflare-dns` — API token for cert-manager + external-dns
- `shared/amqp-events` — AMQP URL for every events publisher
- `redisinsight/oauth` — Zitadel client secret + oauth2-proxy cookie secret for
  redis.algovn.com (see redisinsight.md). The Redis password is NOT duplicated here:
  ns `redisinsight` has its own ExternalSecret pointing at `algovn/redis/redis-auth`.

Non-cluster secrets also live here: `home/nas-smb` (Samba), `zitadel/bootstrap-admin`.

## Add a new secret

1. Write the value:
   `ssh root@192.168.102.100`, then
   `curl -X POST -H "X-Vault-Token: $(cat /root/.openbao/root.token)" http://192.168.102.124:8200/v1/secret/data/algovn/<ns>/<name> -d '{"data":{"<field>":"<value>"}}'`
   (or use the UI at http://192.168.102.124:8200 with the root token).
2. Add a `<name>-external.yaml` ExternalSecret next to the consumer's manifests
   (copy any existing one; set `target.template.type` if the Secret needs a type)
   and list it in the dir's `kustomization.yaml`.
3. `scripts/validate.sh`, commit, push. ESO syncs within `refreshInterval` (1h);
   force with: `kubectl -n <ns> annotate externalsecret <name> force-sync=$(date +%s) --overwrite`
   — then REMOVE the annotation (`force-sync-`) or Argo reports drift.

## Rotate a secret

Update the KV entry (same command as above — KV v2 keeps prior versions), force-refresh
the ExternalSecret(s), restart consumers if they read at boot.

## Bootstrap (fresh cluster)

ESO authenticates via AppRole. The ONLY manual secret step per rebuild:
```
ssh root@192.168.102.100 'cat /root/.openbao/eso.role_id'  > role-id
ssh root@192.168.102.100 'cat /root/.openbao/eso.secret_id' > secret-id
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets create secret generic eso-bao-approle --from-file=role-id=role-id --from-file=secret-id=secret-id
rm -P role-id secret-id
```

## OpenBao operations

- **Unseal:** automatic at host boot — `openbao-unseal.service` on the PVE host reads
  `/root/.openbao/unseal.key`. Manual: `systemctl start openbao-unseal.service` (host).
- **Root of trust:** `/root/.openbao/init.json` (unseal key + root token) — copy lives
  in the password manager ("algovn openbao init"). Host compromise = vault compromise
  (accepted single-box tradeoff).
- **Backups:** LXC 124 is in the weekly vzdump job. Additionally snapshot Raft before
  risky changes: `pct exec 124 -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=<root> bao operator raft snapshot save /tmp/bao.snap`.
- **Disaster:** restore LXC from vzdump; worst case re-run the populate flow — every
  value is regenerable or user-reissuable (see the OpenBao design doc in the archive).

## Not in OpenBao (password manager only)

Argo CD admin pw · Cloudflare account creds · GitHub PATs (source copies; composed
values ARE in bao) · zitadel-iam-admin-sa-pat · openbao init.json (copy).

## TLS note

Bao listens plain HTTP on the LAN (single-host homelab). Issuing it a real cert via
cert-manager is an open follow-up.
