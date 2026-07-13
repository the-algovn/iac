# Cloudflare Access (Zero Trust) — protected admin UIs

Policies live in Cloudflare, NOT in git — re-check after any rebuild.
Team domain: `the-thing-universe.cloudflareaccess.com`. Owner email: `minhducle.dev@gmail.com`.
Current protected hosts: `argocd.algovn.com`.

## Recreate the policies
In Cloudflare dashboard: **Zero Trust → Access → Applications → Add an application → Self-hosted**:
1. App 1: name `argocd`, domain `argocd.algovn.com`; policy `admin-only`: Action Allow,
   Include → Emails → `minhducle.dev@gmail.com`; identity: One-time PIN (default).
   Session duration 24h. Save.

`grafana.algovn.com` is NOT Access-protected — it uses Zitadel SSO (grafana-sso spec, 2026-07-13).

## Verify
`curl -s -o /dev/null -w '%{http_code}' https://argocd.algovn.com/` → `302` (redirect to
`<team>.cloudflareaccess.com` login), NOT `200`. Browser: email OTP → UI loads.
grafana now expects `302` + redirect to `id.algovn.com/oauth/v2/authorize` via
`curl -s -o /dev/null -w '%{http_code} %{redirect_url}' https://grafana.algovn.com/login/generic_oauth`.

## OTP email not arriving
Access pretends to send the code even for emails no policy allows (anti-enumeration).
Check, in order: the policy's Include→Emails entry matches the typed email EXACTLY;
spam folder (`noreply@notify.cloudflare.com`); Zero Trust → Settings → Authentication →
Login methods includes "One-time PIN"; the app accepts that identity provider.

## Pending (2026-07-13): remote-access hostnames
`ssh-pi.algovn.com`, `ssh-w1.algovn.com`, `k8s.algovn.com` (host tunnels,
docs/runbooks/remote-access.md) are NOT yet gated — apps deferred at setup.
Create: apps `ssh-pi`/`ssh-w1`/`k8s`, one per hostname, same `admin-only` policy
as above. Then verify: `curl -s -o /dev/null -w '%{http_code}' https://<host>/`
→ `302`, and move these hosts to the protected list above.

## Known gap
`ssh.algovn.com` (pre-existing production tunnel `algovn`) is NOT Access-protected —
follow-up candidate; do not confuse it with `ssh-pi.algovn.com`.
