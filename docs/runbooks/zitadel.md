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
