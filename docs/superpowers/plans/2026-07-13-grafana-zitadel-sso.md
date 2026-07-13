# Grafana SSO via Zitadel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grafana at `grafana.algovn.com` authenticates via Zitadel (`id.algovn.com`) with strict role mapping, break-glass local admin retained, and Cloudflare Access removed from the hostname once SSO is proven.

**Architecture:** Grafana's native `auth.generic_oauth` against Zitadel as a confidential client. Zitadel fixtures (project `platform-admin`, app `grafana`, role grant) are console-managed per the IdP-content precedent; the client secret enters the cluster as a SealedSecret injected via the grafana chart's `envFromSecret`; all other config is plain values in `platform/monitoring/values.yaml`. Staged rollout: verify behind the existing CF Access gate, then remove the gate.

**Tech Stack:** Grafana (victoria-metrics-k8s-stack subchart, `platform/monitoring/`), Zitadel v4 (live), SealedSecrets, Kong Ingress (unchanged).

**Spec:** `docs/superpowers/specs/2026-07-13-grafana-zitadel-sso-design.md`

## Global Constraints

- **No plaintext secrets in git.** Client secret only as SealedSecret `grafana-oauth` (ns `monitoring`, key `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`). The client **id** is non-secret and is committed in values.
- **Sealing runs locally** (established convention): `kubectl --context algovn-remote create secret ... --dry-run=client -o yaml | kubeseal --context algovn-remote --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml`. Sealing is ns+name-scoped and fails silently on mismatch — always verify the unsealed Secret in-cluster.
- **kubectl runs locally** with `--context algovn-remote` (never ssh for kubectl); tunnel if refused: `cloudflared access tcp --hostname k8s.algovn.com --url 127.0.0.1:16443 &`. No `argocd` CLI — poll Application status via kubectl jsonpath, refresh-annotate to accelerate.
- `scripts/validate.sh` PASS before every push; `main` deploys (Argo auto-sync).
- Commits: small, scoped, no Co-Authored-By/"Generated with" lines; never stage `docs/superpowers/` (except explicitly force-added spec/plan updates) or `.superpowers/`.
- Steps marked **(USER)** need the human (console clicks, browser logins, Cloudflare dashboard).
- Execution parameters recorded during Task 1: `<GRAFANA_CLIENT_ID>` (non-secret). The client secret lives transiently in `~/.secrets/grafana-oauth-secret` and is wiped after sealing.

---

### Task 1: Zitadel fixtures + runbook update

**Files:**
- Modify: `docs/runbooks/zitadel.md` (bootstrap section)

**Interfaces:**
- Produces: Zitadel project `platform-admin` (roles `admin`/`editor`/`viewer`, assert-roles ON), web app `grafana` with redirect `https://grafana.algovn.com/login/generic_oauth`, admin user granted `admin`; `<GRAFANA_CLIENT_ID>` recorded; client secret at `~/.secrets/grafana-oauth-secret` (Task 2 consumes, then wipes).

- [ ] **Step 1 (USER): Create the project + roles**

Console (`https://id.algovn.com/ui/console`, org AlgoVN): Projects → **New** → name `platform-admin` → create. In the project: check **Assert Roles on Authentication**. Roles → New: key `admin` (display `admin`); repeat for `editor` and `viewer`.

- [ ] **Step 2 (USER): Create the Grafana app**

In project `platform-admin`: Applications → **New** → name `grafana` → type **Web** → authentication method **Basic** → redirect URI `https://grafana.algovn.com/login/generic_oauth` (no post-logout URI needed) → create. Copy the **ClientId** (non-secret — paste it into the chat/report) and the **ClientSecret**; save the secret locally:
```bash
mkdir -p ~/.secrets && chmod 700 ~/.secrets
printf '%s' '<paste ClientSecret>' > ~/.secrets/grafana-oauth-secret && chmod 600 ~/.secrets/grafana-oauth-secret
```

- [ ] **Step 3 (USER): Grant yourself admin**

Project `platform-admin` → Authorizations → New → user `admin` (admin@algovn.id.algovn.com) → role `admin`.

- [ ] **Step 4: Update the runbook**

In `docs/runbooks/zitadel.md`, append to the Bootstrap numbered list (after the loginV2 step):
```markdown
11. Admin-tool SSO project: Projects → `platform-admin` (Assert Roles ON; roles
    admin/editor/viewer). Apps: `grafana` — Web, auth method Basic, redirect
    https://grafana.algovn.com/login/generic_oauth; client secret sealed as
    monitoring/grafana-oauth (see grafana-sso spec). Grant admins the `admin` role.
    Future admin tools (Argo CD) join this project.
```

- [ ] **Step 5: Validate, commit, push**

Run: `scripts/validate.sh` → `PASS`
```bash
git add docs/runbooks/zitadel.md
git commit -m "docs: zitadel runbook — platform-admin project for admin-tool SSO"
git push
```

- [ ] **Step 6: Verify fixtures via discovery (no PAT needed)**

Run: `curl -s https://id.algovn.com/.well-known/openid-configuration | jq -r '.authorization_endpoint, .token_endpoint, .userinfo_endpoint'`
Expected:
```
https://id.algovn.com/oauth/v2/authorize
https://id.algovn.com/oauth/v2/token
https://id.algovn.com/oidc/v1/userinfo
```
(These are the three URLs Task 2 writes into values — confirming them from live discovery pins them exactly.)

---

### Task 2: Sealed secret + Grafana OAuth config + deploy

**Files:**
- Create: `platform/monitoring/manifests/grafana-oauth-sealed.yaml`
- Modify: `platform/monitoring/manifests/kustomization.yaml`
- Modify: `platform/monitoring/values.yaml` (grafana section)

**Interfaces:**
- Consumes: `<GRAFANA_CLIENT_ID>` + `~/.secrets/grafana-oauth-secret` from Task 1.
- Produces: Grafana live with `auth.generic_oauth`; `/login/generic_oauth` 302s to Zitadel. Task 3 verifies the human flows.

- [ ] **Step 1: Seal the client secret**

```bash
kubectl --context algovn-remote create secret generic grafana-oauth -n monitoring \
  --from-file=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=/dev/stdin \
  --dry-run=client -o yaml < ~/.secrets/grafana-oauth-secret \
| kubeseal --context algovn-remote --controller-name sealed-secrets \
  --controller-namespace sealed-secrets --format yaml \
> platform/monitoring/manifests/grafana-oauth-sealed.yaml
```
Expected: file contains `kind: SealedSecret`, ns `monitoring`, name `grafana-oauth`, encrypted key `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`. Then wipe the plaintext:
```bash
dd if=/dev/urandom of=~/.secrets/grafana-oauth-secret bs=1 count=$(stat -f%z ~/.secrets/grafana-oauth-secret) conv=notrunc && rm -f ~/.secrets/grafana-oauth-secret
```

- [ ] **Step 2: Add to kustomization**

In `platform/monitoring/manifests/kustomization.yaml`, add `grafana-oauth-sealed.yaml` to `resources`.

- [ ] **Step 3: Extend the grafana values**

In `platform/monitoring/values.yaml`, inside the existing `grafana:` block, add `envFromSecret` and extend `grafana.ini` (keep the existing `server:` key; `<GRAFANA_CLIENT_ID>` from Task 1):
```yaml
grafana:
  # ... existing keys unchanged (enabled, admin, resources, persistence, additionalDataSources)
  envFromSecret: grafana-oauth   # injects GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET
  grafana.ini:
    server:
      root_url: https://grafana.algovn.com
    auth.generic_oauth:
      enabled: true
      name: AlgoVN ID
      auto_login: true
      allow_sign_up: true
      use_pkce: true
      client_id: <GRAFANA_CLIENT_ID>
      scopes: openid profile email urn:zitadel:iam:org:projects:roles
      auth_url: https://id.algovn.com/oauth/v2/authorize
      token_url: https://id.algovn.com/oauth/v2/token
      api_url: https://id.algovn.com/oidc/v1/userinfo
      role_attribute_strict: true
      role_attribute_path: >-
        contains(keys("urn:zitadel:iam:org:project:roles" || `{}`), 'admin') && 'Admin'
        || contains(keys("urn:zitadel:iam:org:project:roles" || `{}`), 'editor') && 'Editor'
        || contains(keys("urn:zitadel:iam:org:project:roles" || `{}`), 'viewer') && 'Viewer'
```
(`client_secret` is deliberately absent — the env var supplies it.)

- [ ] **Step 4: Validate, commit, push, sync**

Run: `scripts/validate.sh` → `PASS`
```bash
git add platform/monitoring/manifests/grafana-oauth-sealed.yaml platform/monitoring/manifests/kustomization.yaml platform/monitoring/values.yaml
git commit -m "feat(grafana): SSO via Zitadel generic_oauth — strict role mapping, sealed client secret"
git push
```
Poll BOTH apps (values → `monitoring`, manifests → `monitoring-config`):
`kubectl --context algovn-remote get application monitoring monitoring-config -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'` until both `Synced/Healthy` (refresh-annotate to accelerate; the grafana Deployment restarts on the values change).

- [ ] **Step 5: Verify config landed**

```bash
kubectl --context algovn-remote get secret grafana-oauth -n monitoring -o jsonpath='{.type} {.data.GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET}' | cut -c1-20
kubectl --context algovn-remote get pods -n monitoring -l app.kubernetes.io/name=grafana
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://grafana.algovn.com/login/generic_oauth
```
Expected: secret exists (Opaque + base64 prefix — do NOT print more); grafana pod `Running` (freshly restarted); the curl shows `302` — while CF Access still gates the host the redirect goes to `the-thing-universe.cloudflareaccess.com` (expected at this stage; the Zitadel-bound redirect is verified in-browser in Task 3 and again post-ungating in Task 4). If the pod crashloops: `kubectl --context algovn-remote logs -n monitoring deploy/vm-grafana | tail -20` — a `role_attribute_path` quoting error shows as an ini parse failure at startup.

---

### Task 3: Verification behind the CF Access gate (spec §4.1–4.3)

**Files:** none (verification; USER-interactive).

**Interfaces:**
- Consumes: live SSO config from Task 2.
- Produces: attested evidence for spec §4.1 (admin SSO), §4.2 (strict deny), §4.3 (break-glass). Task 4 may proceed only after all three pass.

- [ ] **Step 1 (USER): Admin SSO login (§4.1)**

Fresh private window → `https://grafana.algovn.com` → CF Access email OTP (still gated) → expect **automatic redirect to id.algovn.com** → passkey → back in Grafana, logged in. Then open `https://grafana.algovn.com/api/user` in the same window.
Expected: JSON with your Zitadel email and `"login"` = your Zitadel preferred_username. Also open Administration → Users: your SSO user shows role **Admin** (server admin is separate and stays with the local `admin` account).

- [ ] **Step 2 (USER): Strict deny (§4.2)**

Second private window → `https://grafana.algovn.com` → OTP → Zitadel → sign in with the **Google-registered test user** from the foundation rollout (it lives in org `users` and has no `platform-admin` role).
Expected: Grafana REFUSES the login with an oauth error page (role mapping returned nothing and `role_attribute_strict: true` denies). If it logs in instead: FAIL — check that the project has Assert Roles ON and that the user truly has no authorization.

- [ ] **Step 3 (USER): Break-glass (§4.3)**

Same or new window → `https://grafana.algovn.com/login?disableAutoLogin` → the password form renders → log in as `admin` with the `grafana-admin` password (password manager).
Expected: local admin session works. Log out.

- [ ] **Step 4: Record the evidence**

No commit — report the three outcomes (pass/fail each) for the task report. All three must pass before Task 4.

---

### Task 4: Remove CF Access from grafana + edge verification + docs (spec §4.4, §5)

**Files:**
- Modify: `docs/runbooks/cloudflare-access.md`
- Modify: `docs/runbooks/secrets.md`
- Modify: `docs/runbooks/verify.md`
- Modify: `docs/superpowers/specs/2026-07-13-authnz-foundation-design.md` (§9 deferred row — force-add)

**Interfaces:**
- Consumes: Task 3 all-pass.

- [ ] **Step 1 (USER): Remove the Access app**

Cloudflare dashboard → Zero Trust → Access → Applications → delete (or disable) the app named `grafana` (domain `grafana.algovn.com`). Leave `argocd` untouched.

- [ ] **Step 2: Edge verification (§4.4)**

```bash
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://grafana.algovn.com/login/generic_oauth
curl -s -o /dev/null -w '%{http_code}\n' https://grafana.algovn.com/api/health
```
Expected: first → `302` with `redirect_url` starting `https://id.algovn.com/oauth/v2/authorize` (NOT `cloudflareaccess.com`); second → `200` (Grafana serves directly). (USER) One fresh-window browser login end-to-end: straight to Zitadel (no OTP), passkey, dashboards render.

- [ ] **Step 3: Doc updates**

`docs/runbooks/cloudflare-access.md`: change the protected-hosts line to `Current protected hosts: argocd.algovn.com.` and under "Recreate the policies" delete the App 2 (grafana) item, adding a line: `grafana.algovn.com is NOT Access-protected — it uses Zitadel SSO (grafana-sso spec, 2026-07-13).` Update the Verify section: grafana now expects `302` to `id.algovn.com` (not cloudflareaccess) via `curl -s -o /dev/null -w '%{redirect_url}' https://grafana.algovn.com/login/generic_oauth`.

`docs/runbooks/secrets.md`: add `monitoring/grafana-oauth` (Zitadel client secret for Grafana SSO) to the sealed-secret inventory.

`docs/runbooks/verify.md`: in the AuthN/Z section append:
```markdown
- Grafana SSO: `curl -s -o /dev/null -w '%{redirect_url}' https://grafana.algovn.com/login/generic_oauth` starts with `https://id.algovn.com/oauth/v2/authorize`; passkey login lands as Admin; `/login?disableAutoLogin` + grafana-admin = break-glass
```

`docs/superpowers/specs/2026-07-13-authnz-foundation-design.md` §9: change the row `| Migrating Argo CD/Grafana off CF Access onto Zitadel SSO | Desire to consolidate; CF Access is fine today |` to `| Migrating Argo CD off CF Access onto Zitadel SSO (Grafana done 2026-07-13 — see grafana-zitadel-sso spec) | Desire to consolidate |`.

- [ ] **Step 4: Validate, commit, push**

Run: `scripts/validate.sh` → `PASS`
```bash
git add docs/runbooks/cloudflare-access.md docs/runbooks/secrets.md docs/runbooks/verify.md
git add -f docs/superpowers/specs/2026-07-13-authnz-foundation-design.md
git commit -m "docs: grafana off CF Access — Zitadel SSO live; runbooks + verify updated"
git push
```

- [ ] **Step 5: Final green check**

`kubectl --context algovn-remote get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'` → every row `Synced/Healthy`.

---

## Failure modes & decision rules

- **Token exchange fails** (Grafana log: `invalid_client` after Zitadel redirect): Zitadel app auth method mismatch. In console, open app `grafana` → change Authentication Method **Basic → Post** → retry login. Record which method worked in the task report (runbook already says Basic; correct it if Post was needed).
- **Login loops back to Grafana login page with `login.OAuthLogin(missing saved state)`**: cookie/root_url issue — confirm `server.root_url` is exactly `https://grafana.algovn.com` (it already is; don't change without evidence).
- **role_attribute_path returns nothing for the admin** (denied despite grant): fetch the actual claims — in a private window log into Zitadel, then `curl -s -H "Authorization: Bearer <token from a PKCE flow>" https://id.algovn.com/oidc/v1/userinfo | jq 'keys'` is NOT easily available without a client; instead check Grafana's log line `error="user does not have a valid role"` and re-verify in console: project `platform-admin` → Assert Roles ON; authorization exists for the admin user; the app's project association is `platform-admin` (an app created in the wrong project yields role-less tokens).

## Spec-coverage map (self-check)

| Spec item | Task |
|---|---|
| §3 Zitadel fixtures (project/roles/app/grant), runbook'd | 1 |
| §3 Grafana generic_oauth + sealed secret + envFromSecret | 2 |
| §2/§3 break-glass preserved | 2 (config), 3 (verified) |
| §4.1 admin SSO / §4.2 strict deny / §4.3 break-glass | 3 |
| §4.4 Access removal + edge verify / §4.5 apps green | 4 |
| §5 doc updates (zitadel.md in T1; cloudflare-access, secrets, verify, spec §9 in T4) | 1, 4 |
| §6 out-of-scope respected (no Argo CD SSO, no single-logout) | all |
