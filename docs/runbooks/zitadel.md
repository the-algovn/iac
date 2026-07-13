# Zitadel (id.algovn.com) — bootstrap & operations
IdP for all SaaS products (spec 2026-07-13). Console: /ui/console. IdP CONTENT (orgs,
projects, IdP configs, policies) lives in Zitadel's DB — backed up via postgres-restore.md,
NOT reproducible from git. This runbook is the reproduction path.

## Bootstrap (once per instance)
1. Login: admin / password-manager item `zitadel-admin-bootstrap` (forced change on first login).
   Login name format: `<username>@algovn.id.algovn.com` — the org-domain suffix is required;
   bare usernames don't resolve.
2. Admin passkey: top-right avatar → Passkeys → add (Touch ID). Then ADD A SECOND one
   (phone/YubiKey) — passkey loss with passwords disabled = console lockout.
3. Instance-admin API access: the setup chart auto-creates machine user iam-admin (IAM_OWNER)
   plus in-cluster secrets iam-admin / iam-admin-pat (ns zitadel). The bootstrap PAT in that
   secret was REVOKED 2026-07-13; the live PAT is console-created and lives ONLY in the
   password manager as zitadel-iam-admin-sa-pat. Rotate: Console → Users → Service Users →
   iam-admin → Personal Access Tokens. (Break-glass: this PAT can re-enable password login via
   API.)
4. Default org for self-registration: Organizations → New → name `users` → ⋮ → Set as default.
   (AlgoVN stays the platform/admin org that owns future product projects.)
5. Google IdP: Default settings → Identity Providers → Google. (USER) In
   console.cloud.google.com → APIs & Services → Credentials → Create OAuth client (Web app);
   Authorized redirect URI = the exact value the Zitadel IdP form displays. Paste client
   ID/secret back. Options: check Automatic creation, Automatic linking (email verified),
   uncheck manual account creation.
6. GitHub IdP: same flow — github.com → Settings → Developer settings → OAuth Apps → New;
   callback = value shown by the Zitadel GitHub IdP form. (PENDING as of 2026-07-13 — Google
   only for now.)
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
- GitHub signup: PENDING (IdP not configured yet).
- Passkey: log into account page (/ui/v2/login → self-service), add passkey, log out,
  log in with passkey ONLY. Confirm NO password option is offered anywhere.

## Recovery / notes
- Admin passkey lost: use `zitadel-iam-admin-sa-pat` →
  PUT /admin/v1/policies/login {"allowUsernamePassword": true} — then fix and re-disable.
- New SaaS product onboarding: see docs/authnz-conventions.md.
- Key rotation: docs/runbooks/zitadel-key-rotation.md.

## Login versions & device flows (findings 2026-07-13)
- Instance feature `loginV2` = required (set via API; GET /v2/features/instance to check).
  All standard OIDC flows use login v2 (/ui/v2/login).
- EXCEPTION: device-code flows fall back to the legacy v1 login (login v2 has no device
  support yet). v1 sessions are SEPARATE from v2, and with password auth disabled v1
  auto-redirects IdP-linked users straight to the IdP.
- IdP callbacks differ per login version: v2 uses https://id.algovn.com/idps/callback,
  v1 uses https://id.algovn.com/ui/login/login/externalidp/callback. Register BOTH in
  every IdP's OAuth client (Google: v2 registered, v1 pending; GitHub: both when added).
