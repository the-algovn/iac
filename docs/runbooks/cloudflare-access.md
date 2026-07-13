# Cloudflare Access (Zero Trust) — protected admin UIs

Policies live in Cloudflare, NOT in git — re-check after any rebuild.
Team domain: `the-thing-universe.cloudflareaccess.com`. Owner email: `minhducle.dev@gmail.com`.
Current protected hosts: none (admin UIs use Zitadel SSO — grafana 2026-07-13, argocd 2026-07-13). Pending: the ssh/k8s host-tunnel apps below.

## Recreate the policies
Template — policy `admin-only`: Action Allow, Include → Emails → `minhducle.dev@gmail.com`;
identity: One-time PIN (default); session duration 24h.
No admin-UI apps remain (grafana + argocd use Zitadel SSO, 2026-07-13). The pending
ssh-pi / ssh-w1 / k8s apps below use this template.

In Cloudflare dashboard: **Zero Trust → Access → Applications → Add an application → Self-hosted**:

`grafana.algovn.com` is NOT Access-protected — it uses Zitadel SSO (grafana-sso spec, 2026-07-13).
`argocd.algovn.com` is NOT Access-protected — it uses Zitadel SSO (argocd-zitadel-sso spec, 2026-07-13).

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

## Pending (2026-07-13): remote-access hostnames
`ssh-pi.algovn.com`, `ssh-w1.algovn.com`, `k8s.algovn.com` (host tunnels,
docs/runbooks/remote-access.md) are NOT yet gated — apps deferred at setup.
Create: apps `ssh-pi`/`ssh-w1`/`k8s`, one per hostname, using the `admin-only` template above.
Then verify: `curl -s -o /dev/null -w '%{http_code}' https://<host>/`
→ `302`, and move these hosts to the protected list above.

## Known gap
`ssh.algovn.com` (pre-existing production tunnel `algovn`) is NOT Access-protected —
follow-up candidate; do not confuse it with `ssh-pi.algovn.com`.
