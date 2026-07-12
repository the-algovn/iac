# Cloudflare Access (Zero Trust) — protected admin UIs

Policies live in Cloudflare, NOT in git — re-check after any rebuild.
Team domain: `the-thing-universe.cloudflareaccess.com`. Owner email: `minhducle.dev@gmail.com`.
Current protected hosts: `argocd.algovn.com`, `grafana.algovn.com`.

## Recreate the policies
In Cloudflare dashboard: **Zero Trust → Access → Applications → Add an application → Self-hosted**:
1. App 1: name `argocd`, domain `argocd.algovn.com`; policy `admin-only`: Action Allow,
   Include → Emails → `minhducle.dev@gmail.com`; identity: One-time PIN (default).
   Session duration 24h. Save.
2. App 2: name `grafana`, domain `grafana.algovn.com`, same policy. Save.

## Verify
`curl -s -o /dev/null -w '%{http_code}' https://argocd.algovn.com/` → `302` (redirect to
`<team>.cloudflareaccess.com` login), NOT `200`. Same for grafana. Browser: email OTP → UI loads.

## OTP email not arriving
Access pretends to send the code even for emails no policy allows (anti-enumeration).
Check, in order: the policy's Include→Emails entry matches the typed email EXACTLY;
spam folder (`noreply@notify.cloudflare.com`); Zero Trust → Settings → Authentication →
Login methods includes "One-time PIN"; the app accepts that identity provider.
