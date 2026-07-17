# Redis Insight (redis.algovn.com) — admin UI

Browse/write/inspect UI for the platform Redis. Design: archived spec
`2026-07-17-redisinsight-design.md`. Manifests: `platform/redisinsight/manifests`.

## Shape

    Browser → Cloudflare → cloudflared → kong → Ingress redis.algovn.com
            → oauth2-proxy :4180 → redisinsight :5540 → redis.redis.svc:6379

Redis Insight has **no authentication of its own**. Two independent gates protect it:

1. **Zitadel** — project `internal-tool`, single role `admin`, "Check authorization on
   Authentication" ON (also "Check for Project on Authentication" ON — see
   docs/runbooks/zitadel.md item 12 for the full reproduction detail). No role ⇒ no
   token (`Errors.User.ProjectRequired`).
2. **oauth2-proxy** — `--authenticated-emails-file` (ConfigMap `oauth2-proxy-emails`).

NetworkPolicy makes oauth2-proxy the only route to :5540; without it, any pod in the
cluster is an admin. The policy protecting oauth2-proxy itself is scoped just as
tightly: ingress to :4180 is restricted to Kong's gateway pods specifically
(`namespaceSelector` + `podSelector` combined in one peer, i.e. AND), not the whole
`kong` namespace — a namespace-wide allowance would let `kong-controller` reach the
proxy and forge `X-Forwarded-*` headers (oauth2-proxy runs `--reverse-proxy=true`).

## ⚠️ The one fatal misconfiguration

**Never set `--email-domain` on this oauth2-proxy.** Its `NewValidator` combines
allowed-domains with the emails file using **OR**, and `--email-domain=*` sets
`allowAll` — either one silently nullifies the allowlist and publishes an
unauthenticated Redis write console. Setting neither fails closed (denies all).
The emails file alone is the correct configuration.

## ⚠️ Grant rule

On `internal-tool`, only ever grant the **`admin` role** — never a bare project grant.
Per zitadel#9633 a grant with an empty role list still passes the project role check,
defeating gate #1. Gate #2 would still hold, but do not spend it.

Likewise: **keep `admin` the only role on this project.** The check means "has *any*
role", so a second role silently widens access to this UI. This is exactly why
`internal-tool` exists instead of reusing `platform-admin` (3 roles).

## Add a person

Both gates, in this order: Zitadel → `internal-tool` → Authorizations → New → role
`admin`; then add their email to `platform/redisinsight/manifests/emails-configmap.yaml`
and commit. Two edits is the intended friction for a prod Redis write console.

## Remove a person

Delete their line from `platform/redisinsight/manifests/emails-configmap.yaml` and
commit. oauth2-proxy re-validates against the hot-reloaded
`--authenticated-emails-file` on every request, so this kills even an already-logged-in
session within the kubelet ConfigMap propagation window (~1 min) — no pod restart
needed. For defence in depth, also remove their `admin` authorization on
`internal-tool` in Zitadel.

## Break-glass

Zitadel down, or the UI broken? The UI is a convenience, not the access path:

    kubectl --context algovn-remote -n redis exec -it redis-0 -- \
      sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning'

## Rotate the Zitadel client secret

Console → `internal-tool` → Applications → `redisinsight` → Regenerate secret (shown
once). Write it to bao and force ESO to resync, then restart the proxy:

    # write algovn/redisinsight/oauth field client-secret — see secrets.md
    kubectl --context algovn-remote -n redisinsight annotate externalsecret redisinsight-oauth force-sync=$(date +%s) --overwrite
    kubectl --context algovn-remote -n redisinsight annotate externalsecret redisinsight-oauth force-sync-
    kubectl --context algovn-remote -n redisinsight rollout restart deploy/oauth2-proxy

Remove the force-sync annotation (second command) or Argo reports drift.

The same secret carries a `cookie-secret` field, which has its own recipe — do NOT
reuse the `openssl rand -base64 24` pattern from postgres.md here:

    openssl rand -base64 32 | tr -- '+/' '-_'

oauth2-proxy requires the *decoded* cookie secret to be 16, 24, or 32 bytes, and it
decodes with **base64url**, not standard base64. Standard `openssl rand -base64`
output has a ~74% chance of containing a `+` or `/`, which base64url rejects —
oauth2-proxy then falls back to treating the raw 44-char string as bytes and
crashloops with `cookie_secret must be 16, 24, or 32 bytes to create an AES cipher,
but is 44 bytes`. The `tr` above remaps to the base64url alphabet so the 32 raw
bytes decode cleanly.

## Recreating the app

Recreation issues a **new client_id** → update `--client-id` in
`oauth2-proxy-deployment.yaml` and write the new secret to bao. No quoting needed
here: `--client-id=...` is a flag *argument*, which YAML already parses as a plain
string. The float64-mangling gotcha (18-digit id → `3.8e+17` ⇒
`Errors.App.NotFound`) is a bare-Helm-scalar-value problem (see
`platform/monitoring/values.yaml`), not a flag-arg one — see the manifest's own
comment.

## Notes

- **No PVC.** The connection is pre-seeded from env on every start, so `/data` is an
  emptyDir. Cost: Workbench history resets on restart. Do not "fix" this with a PVC.
- **`RI_ACCEPT_TERMS_AND_CONDITIONS=true` is REQUIRED, not cosmetic.** Redis Insight gates
  ALL database auto-discovery behind EULA acceptance — remove it and `/api/databases`
  returns `[]` forever, the pre-seeded connection silently vanishes, and the UI looks
  empty with nothing in the logs to explain why. The upstream docs claim the default is
  `true`; it is not (`GET /api/settings` → `"agreements":null`). Cost us a debug cycle
  on 2026-07-17.
- `RI_DATABASE_MANAGEMENT=false` — the UI cannot add/edit/delete connections. Verified
  server-side, not just a hidden button: `POST`/`PATCH`/`DELETE /api/databases` all
  return `403 {"message":"Database connection management is disabled."}`.
- Root path only: Redis Insight does not support hosting behind a prefix path.
- `--upstream-timeout=60s` — Redis Insight requires >30s; oauth2-proxy defaults to 30s.
- Redis Insight can `FLUSHALL` the-button's `noeviction` keys. There is no technical
  guard — that is inherent to a write console. Recovery is the Postgres outbox.
- The Profiler tab runs `MONITOR`, which materially degrades live Redis throughput —
  same hazard class as `FLUSHALL`, but easy to reach for since it looks read-only.
