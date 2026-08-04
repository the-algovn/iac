# Cloudflare Access (Zero Trust) — protected admin UIs

Policies live in Cloudflare, NOT in git — re-check after any rebuild.
Team domain: `the-thing-universe.cloudflareaccess.com`. Owner email: `minhducle.dev@gmail.com`.
Current protected hosts (re-verified 2026-08-04): `pve.algovn.com`, `ssh-pve.algovn.com`
(Proxmox host tunnel — MUST stay gated, see remote-access.md), `ssh-cp.algovn.com`,
`k8s.algovn.com`. `ssh-w1.algovn.com` was also gated but its hostname and tunnel were
deleted 2026-08-04 (workers are reached via `ProxyJump cp` now) — **delete that stale
Access app** if it still exists. Admin UIs use Zitadel SSO instead
(grafana, argocd — clients recreated 2026-07-16 after the rebuild — and
`redis.algovn.com`, see docs/runbooks/redisinsight.md).

## Recreate the policies
Template — policy `admin-only`: Action Allow, Include → Emails → `minhducle.dev@gmail.com`;
identity: One-time PIN (default); session duration 24h.
No admin-UI apps remain (grafana + argocd use Zitadel SSO, 2026-07-13; redis.algovn.com
likewise uses Zitadel SSO + oauth2-proxy, 2026-07-17 — not Access). The pending
ssh-pi / ssh-w1 / k8s apps below use this template.

In Cloudflare dashboard: **Zero Trust → Access → Applications → Add an application → Self-hosted**:

`grafana.algovn.com` is NOT Access-protected — it uses Zitadel SSO (grafana-sso spec, 2026-07-13).
`argocd.algovn.com` is NOT Access-protected — it uses Zitadel SSO (argocd-zitadel-sso spec, 2026-07-13).
`redis.algovn.com` is NOT Access-protected — it is intentionally gated by
oauth2-proxy + Zitadel SSO instead (see docs/runbooks/redisinsight.md).

## Verify
`curl -s -o /dev/null -w '%{http_code}' https://<host>/` → `302` (redirect to
`<team>.cloudflareaccess.com` login), NOT `200` — applies to the pending ssh/k8s hosts once created.
argocd and grafana are off Access now — argocd expects a plain `200`
(`curl -s -o /dev/null -w '%{http_code}' https://argocd.algovn.com/`); grafana expects `302` + redirect
to `id.algovn.com/oauth/v2/authorize` via
`curl -s -o /dev/null -w '%{http_code} %{redirect_url}' https://grafana.algovn.com/login/generic_oauth`.

## OTP email not arriving
Access pretends to send the code even for emails no policy allows (anti-enumeration).
Check, in order: the policy's Include→Emails entry matches the typed email EXACTLY;
spam folder (`noreply@notify.cloudflare.com`); Zero Trust → Settings → Authentication →
Login methods includes "One-time PIN"; the app accepts that identity provider.

## Pending
`nas.algovn.com` — the TrueNAS admin UI. Moved onto the shared `algovn-k8s` tunnel
via Kong on 2026-08-04 (`apps/nas`); it answers 302 → `/ui/`, which is TrueNAS's own
redirect, NOT an Access redirect. An admin UI for the cluster's storage is the same
risk class as `pve.algovn.com`, so it is a gating candidate — decide deliberately
rather than leaving it unlisted.

`photos.algovn.com` (Immich, `apps/photos`) is likewise ungated and relies on Immich's
own login. Intentional so far — recorded here so a review stops re-flagging it.

## Known gap
None. The old entry for `ssh.algovn.com` (legacy tunnel `algovn`) is resolved: the
hostname no longer resolves and the tunnel object was deleted 2026-08-04.
