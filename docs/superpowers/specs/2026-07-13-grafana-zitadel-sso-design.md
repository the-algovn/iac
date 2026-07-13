# Grafana SSO via Zitadel — Design

**Date:** 2026-07-13
**Status:** Approved (brainstorm dialogue)
**Depends on:** `2026-07-13-authnz-foundation-design.md` (live). Fires its §9 deferred
trigger "Migrating Argo CD/Grafana off CF Access" — **Grafana only**; Argo CD stays
behind CF Access.

## 1. Goal

Grafana (`grafana.algovn.com`) logs in through the platform IdP: browser →
auto-redirect to `id.algovn.com` → passkey/Google → Grafana session with a role
mapped from Zitadel. Cloudflare Access on the grafana hostname is removed once
SSO is proven. Local admin password stays as break-glass.

## 2. Decisions (from brainstorm Q&A)

| Question | Decision |
|---|---|
| Mechanism | Grafana native `auth.generic_oauth` (confidential client). Rejected: Kong-level OIDC (no OSS plugin — would adopt a third-party Lua dep), Grafana `auth.jwt` (no browser flow) |
| CF Access fate | Staged: deploy + verify SSO behind the existing Access gate, then remove the `grafana` Access app (argocd's untouched) |
| Access policy | Explicit roles only: Zitadel project `platform-admin` (shared home for future admin tools), roles `admin`/`editor`/`viewer`, `role_attribute_strict: true` — no role ⇒ denied |
| Break-glass | `auto_login: true` to Zitadel; local admin form remains at `/login?disableAutoLogin` (sealed `grafana-admin` unchanged) — a Zitadel/Postgres outage is exactly when dashboards are needed |
| Logout | Local only (Grafana session ends; Zitadel session persists). Single-logout deferred — YAGNI |

## 3. Design

**Zitadel (console/API, runbook'd — IdP content stays out of GitOps per precedent):**
- Project **`platform-admin`** in org AlgoVN, "assert roles on authentication" ON,
  roles `admin`, `editor`, `viewer`.
- **Web application `grafana`**: auth method client-secret (confidential);
  redirect URI `https://grafana.algovn.com/login/generic_oauth`.
  (Browser-session app — the JWT access-token-type rule for Kong-gated APIs does
  not apply here.)
- Admin user granted `admin`.

**Grafana (GitOps, `platform/monitoring/`):**
- `values.yaml` → `grafana.grafana.ini` gains `auth.generic_oauth`:
  auth/token/api URLs on `https://id.algovn.com` (`/oauth/v2/authorize`,
  `/oauth/v2/token`, `/oidc/v1/userinfo`), scopes
  `openid profile email urn:zitadel:iam:org:projects:roles`, `auto_login: true`,
  `allow_sign_up: true`, `role_attribute_strict: true`, and a JMESPath
  `role_attribute_path` mapping the `urn:zitadel:iam:org:project:roles` claim →
  `Admin`/`Editor`/`Viewer` (exact expression pinned in the plan).
- **Client secret never enters values** (public repo): new SealedSecret
  `grafana-oauth` (ns `monitoring`, key `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`)
  wired via the grafana chart's `envFromSecret` — Grafana's native
  `GF_<SECTION>_<KEY>` env override.
- Everything else (admin secret, ingress, resources) unchanged.

**Rollout order:** Zitadel fixtures → sealed secret + values push (Argo syncs
monitoring) → verify behind CF Access → user removes the `grafana` Access app
(Cloudflare dashboard, manual) → verify edge behavior → doc updates.

## 4. Verification

1. Fresh window → `grafana.algovn.com` → (CF OTP while gated) → auto-redirect to
   `id.algovn.com` → passkey → lands in Grafana; `/api/user` shows the SSO
   identity; role = Admin (from the `admin` grant).
2. Strict deny: a temporary Zitadel user with **no** `platform-admin` role cannot
   log in (role mapping rejects).
3. Break-glass: `/login?disableAutoLogin` + sealed `grafana-admin` password works.
4. After Access-app removal: unauthenticated hit redirects to `id.algovn.com`
   (no `cloudflareaccess.com` in the chain); dashboards render for the SSO admin.
5. Argo apps all Synced/Healthy; no change to other monitoring components.

## 5. Documentation updates

- `docs/runbooks/zitadel.md`: `platform-admin` project + grafana app recreation
  steps (bootstrap section).
- `docs/runbooks/cloudflare-access.md`: grafana app removed (argocd remains);
  verify snippet updated.
- `docs/runbooks/secrets.md`: `monitoring/grafana-oauth` added to the inventory.
- Authnz spec §9: deferred row annotated "Grafana done 2026-07-13; Argo CD still
  deferred".

## 6. Out of scope / deferred

| Item | Trigger |
|---|---|
| Argo CD → Zitadel SSO (would join `platform-admin`) | Next consolidation urge; Argo has its own OIDC config + RBAC mapping to design |
| Zitadel single-logout from Grafana | Real multi-user tenancy on admin tools |
| Team-sync / editor+viewer users | First non-admin consumer of dashboards |
