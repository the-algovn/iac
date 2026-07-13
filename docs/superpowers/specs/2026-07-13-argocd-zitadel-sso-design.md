# Argo CD SSO via Zitadel — Design

**Date:** 2026-07-13
**Status:** Approved (brainstorm dialogue)
**Depends on:** `2026-07-13-authnz-foundation-design.md`, `2026-07-13-grafana-zitadel-sso-design.md` (both live).
Completes the authnz spec's §9 deferred row "Migrating Argo CD off CF Access onto
Zitadel SSO" — after this, **no admin UI remains behind Cloudflare Access**.

## 1. Goal

Argo CD (`argocd.algovn.com`) authenticates via Zitadel: web UI "Log in via
AlgoVN ID" button → passkey/Google → admin session; `argocd login --sso` works
from a workstation; Cloudflare Access removed from the hostname once proven;
local `admin` account stays as break-glass. (Unlike Grafana there is no
auto-redirect — Argo serves its own login page with an SSO button.)

## 2. Decisions (from brainstorm Q&A)

| Question | Decision |
|---|---|
| Client type | **PKCE public client** (`enablePKCEAuthentication: true`) — no client secret exists, nothing to seal or rotate. Rejected: confidential client (a secret whose only job is being stored) |
| RBAC mapping | **By email, roles later**: `policy.csv` grants `role:admin` to `minhducle.dev@gmail.com`; `policy.default: ""` (SSO users get nothing). Zitadel's object-shaped roles claim doesn't match Argo's flat-string RBAC; the Action-flattened groups-claim approach is the documented upgrade path when a second human joins — config swap, no migration |
| CF Access fate | Staged removal, same pattern as Grafana: verify behind the gate, then user deletes the `argocd` Access app |
| CLI SSO | Included: redirect `http://localhost:8085/auth/callback` on the same app. Requires **Dev Mode** on the Zitadel Web app (plain-http loopback); if dev mode ever bothers us, the CLI splits into its own Native app |
| Dex | Stays deleted (slim install). Direct `oidc.config` — no dex revival |
| Break-glass | Local `admin` account untouched (same rationale as Grafana: the IdP outage is when you need the deploy tool) |

## 3. Design

**Zitadel (console, extends zitadel.md bootstrap item 11):** app `argocd` in the
existing `platform-admin` project — type **Web**, auth method **PKCE**, redirect
URIs `https://argocd.algovn.com/auth/callback` + `http://localhost:8085/auth/callback`,
**Dev Mode ON**. No role grants (email-based RBAC). Client ID recorded; there is
no secret.

**Argo CD (GitOps, `platform/argocd/`, kustomize):**
- New patch for `argocd-cm`:
  - `url: https://argocd.algovn.com`
  - `oidc.config`: name `AlgoVN ID`, issuer `https://id.algovn.com`, clientID
    (**quoted string** — Helm/YAML float64 lesson), `enablePKCEAuthentication: true`,
    requestedScopes `[openid, profile, email]`.
- New patch for `argocd-rbac-cm`:
  - `policy.default: ""`
  - `policy.csv`: `g, minhducle.dev@gmail.com, role:admin`
  - `scopes: '[email]'`
- Nothing else changes: dex-delete patch, `server.insecure: true`, resources,
  Ingress all stay as-is. No new secrets, no RAM cost.

**Rollout order:** Zitadel app → cm patches push (the `argocd` Application
manages its own config; sync picks it up) → verify behind CF Access → user
removes the `argocd` Access app → edge verify → docs.

## 4. Verification

1. Fresh window → `argocd.algovn.com` → (CF OTP while gated) → "Log in via
   AlgoVN ID" → passkey → UI shows the app list; a sync action is permitted
   (role:admin).
2. Deny: Google test user (no policy row) logs in via SSO but sees an empty
   app list and cannot act (`policy.default: ""`).
3. Break-glass: local `admin` + password login still works.
4. CLI: `argocd login argocd.algovn.com --sso --grpc-web` from the Mac opens
   the browser, completes via existing session or passkey; `argocd app list`
   returns the platform apps.
5. After Access-app removal: unauthenticated `https://argocd.algovn.com`
   serves Argo's login page directly (no `cloudflareaccess.com` hop); SSO
   button → `id.algovn.com`.
6. All Argo Applications stay Synced/Healthy (including `argocd` itself after
   self-managing the cm changes).

## 5. Documentation updates

- `docs/runbooks/zitadel.md` item 11: add the `argocd` app (PKCE, both
  redirects, Dev Mode note, no grant needed).
- `docs/runbooks/cloudflare-access.md`: argocd app removed — admin-UI section
  becomes historical; pending ssh-host section remains.
- `docs/runbooks/verify.md`: Argo SSO line (edge redirect + SSO button check).
- Authnz spec §9: the migration row marked fully done (Grafana + Argo CD).

## 6. Out of scope / deferred

| Item | Trigger |
|---|---|
| Role-driven Argo RBAC via Zitadel Action → flat groups claim | Second human needs Argo access |
| Argo CD notifications, dex revival | Never (slim install is deliberate) |
| SSO for ssh/k8s host tunnels (CF Access apps still pending there) | Separate concern — tracked in remote-access.md |
