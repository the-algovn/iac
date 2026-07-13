# Argo CD SSO via Zitadel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Argo CD (`argocd.algovn.com`) logs in via Zitadel (PKCE, no client secret), email-mapped admin RBAC, CLI `--sso` support, and Cloudflare Access removed from the hostname once proven.

**Architecture:** Two kustomize ConfigMap patches on the existing raw-manifest Argo CD install (`platform/argocd/`): `argocd-cm` gains `url` + `oidc.config` (PKCE public client — no secret anywhere), `argocd-rbac-cm` maps `minhducle.dev@gmail.com` → `role:admin` with `policy.default: ""`. Zitadel app lives in the existing `platform-admin` project (console-managed). Staged rollout behind CF Access; CLI verification happens after the gate is removed (the CLI can't answer a CF OTP).

**Tech Stack:** Argo CD v3.4.5 (raw manifests + kustomize, dex deleted), Zitadel v4 (live), Kong Ingress (unchanged). No new secrets, no new components, zero RAM cost.

**Spec:** `docs/superpowers/specs/2026-07-13-argocd-zitadel-sso-design.md`

## Global Constraints

- **PKCE public client — there is NO client secret.** If any step appears to need one, the Zitadel app was created with the wrong auth method (must be PKCE).
- **clientID is a QUOTED string** in YAML (`"<ARGOCD_CLIENT_ID>"`) — unquoted 18-digit ints get float64-mangled (proven on the Grafana rollout).
- **kubectl runs locally** with `--context algovn-remote` (never ssh for kubectl); tunnel if refused: `cloudflared access tcp --hostname k8s.algovn.com --url 127.0.0.1:16443 &`. No `argocd` CLI for cluster admin until Task 4 verifies it — poll Applications via kubectl jsonpath, refresh-annotate to accelerate.
- `scripts/validate.sh` PASS before every push; `main` deploys (the `argocd` Application manages its own config — pushes to `platform/argocd/` self-apply).
- Commits: small, scoped, no Co-Authored-By/"Generated with"; never stage `docs/superpowers/` (except explicitly force-added spec/plan edits) or `.superpowers/`.
- Steps marked **(USER)** need the human. Execution parameter from Task 1: `<ARGOCD_CLIENT_ID>` (non-secret).
- Dex stays deleted; `patches/slim.yaml` and `patches/params-cm.yaml` must not change.

---

### Task 1: Zitadel app fixture + runbook

**Files:**
- Modify: `docs/runbooks/zitadel.md` (bootstrap item 11)

**Interfaces:**
- Produces: Zitadel app `argocd` (project `platform-admin`, PKCE, both redirect URIs, Dev Mode ON); `<ARGOCD_CLIENT_ID>` recorded. No secret exists. No role grant needed (email RBAC).

- [ ] **Step 1 (USER): Create the app**

Console (`https://id.algovn.com/ui/console`, org AlgoVN): project `platform-admin` → Applications → **New** → name `argocd` → type **Web** → authentication method **PKCE** → redirect URIs (both):
```
https://argocd.algovn.com/auth/callback
http://localhost:8085/auth/callback
```
→ create. Then open the app's configuration and enable **Dev Mode** (required: Zitadel rejects the plain-http localhost redirect on Web apps otherwise) — save. Copy the **Client ID** (paste into chat — non-secret).

- [ ] **Step 2: Extend runbook item 11**

In `docs/runbooks/zitadel.md`, Bootstrap item 11, append:
```markdown
    App `argocd` — Web, auth method PKCE (NO secret), Dev Mode ON (needed for the
    plain-http CLI loopback redirect), redirects
    https://argocd.algovn.com/auth/callback + http://localhost:8085/auth/callback.
    No role grant — Argo RBAC maps by email (platform/argocd/patches/rbac-cm.yaml).
    Recreation issues a new client_id → update the quoted clientID in
    platform/argocd/patches/oidc-cm.yaml.
```

- [ ] **Step 3: Validate, commit, push**

Run: `scripts/validate.sh` → `PASS`
```bash
git add docs/runbooks/zitadel.md
git commit -m "docs: zitadel runbook — argocd PKCE app in platform-admin"
git push
```

---

### Task 2: Argo CD OIDC + RBAC patches + deploy

**Files:**
- Create: `platform/argocd/patches/oidc-cm.yaml`
- Create: `platform/argocd/patches/rbac-cm.yaml`
- Modify: `platform/argocd/kustomization.yaml`

**Interfaces:**
- Consumes: `<ARGOCD_CLIENT_ID>` from Task 1.
- Produces: live `oidc.config` (settings API advertises the issuer); login page shows "Log in via AlgoVN ID". Tasks 3–4 verify the human flows.

- [ ] **Step 1: Write the patches**

`platform/argocd/patches/oidc-cm.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
data:
  url: https://argocd.algovn.com
  oidc.config: |
    name: AlgoVN ID
    issuer: https://id.algovn.com
    clientID: "<ARGOCD_CLIENT_ID>"
    enablePKCEAuthentication: true
    requestedScopes: ["openid", "profile", "email"]
```

`platform/argocd/patches/rbac-cm.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
data:
  policy.default: ""
  policy.csv: |
    g, minhducle.dev@gmail.com, role:admin
  scopes: '[email]'
```

- [ ] **Step 2: Wire into the kustomization**

In `platform/argocd/kustomization.yaml`, extend `patches:`:
```yaml
patches:
  - path: patches/slim.yaml
  - path: patches/params-cm.yaml
  - path: patches/oidc-cm.yaml
  - path: patches/rbac-cm.yaml
```

- [ ] **Step 3: Validate, commit, push, sync**

Run: `scripts/validate.sh` → `PASS`
```bash
git add platform/argocd/patches/oidc-cm.yaml platform/argocd/patches/rbac-cm.yaml platform/argocd/kustomization.yaml
git commit -m "feat(argocd): SSO via Zitadel — PKCE oidc.config + email-mapped admin RBAC"
git push
```
Poll: `kubectl --context algovn-remote get application argocd -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}'` → `Synced/Healthy` (refresh-annotate to accelerate; argocd-server hot-reloads settings ConfigMaps — no restart expected).

- [ ] **Step 4: Verify the settings API (works despite the CF gate — in-cluster)**

```bash
kubectl --context algovn-remote run argocd-check --rm -i --restart=Never --image=curlimages/curl:latest -n argocd -- -s http://argocd-server.argocd.svc/api/v1/settings
```
Expected: JSON whose `oidcConfig` contains `"name":"AlgoVN ID"`, `"issuer":"https://id.algovn.com"`, and the exact 18-digit `clientID` (no `e+17` mangling — check character-for-character). Also confirm no OIDC errors: `kubectl --context algovn-remote logs -n argocd deploy/argocd-server --tail=20` contains no `oidc` error lines.

---

### Task 3: Gated UI verification (spec §4.1–4.3)

**Files:** none (verification; USER-interactive).

**Interfaces:**
- Consumes: live SSO from Task 2.
- Produces: attested §4.1/§4.2/§4.3 evidence. Task 4 proceeds only when all three pass.

- [ ] **Step 1 (USER): Admin SSO (§4.1)**

Fresh private window → `https://argocd.algovn.com` → CF OTP → Argo login page → click **"Log in via AlgoVN ID"** → passkey → UI loads.
Expected: the full application list (20 apps) is visible; pick any app (e.g. `homepage`) and hit **Refresh** — it succeeds (admin can act). User menu shows your Zitadel identity.

- [ ] **Step 2 (USER): Strict deny (§4.2)**

Second private window → same path → SSO login as the **Google test user**.
Expected: login SUCCEEDS (Argo accepts any Zitadel user) but the app list is **empty** and any action fails with permission denied (`policy.default: ""` + no policy row). That emptiness IS the pass condition.

- [ ] **Step 3 (USER): Break-glass (§4.3)**

Same URL, log out (or new window) → login form → local `admin` + the Argo CD admin password (password manager).
Expected: works, full access.

- [ ] **Step 4: Record outcomes**

No commit — report pass/fail per check. All three must pass before Task 4.

---

### Task 4: Remove CF Access + CLI SSO + edge verify + docs (spec §4.4–4.6, §5)

**Files:**
- Modify: `docs/runbooks/cloudflare-access.md`
- Modify: `docs/runbooks/verify.md`
- Modify: `docs/superpowers/specs/2026-07-13-authnz-foundation-design.md` (§9 row — force-add)

**Interfaces:**
- Consumes: Task 3 all-pass.

- [ ] **Step 1 (USER): Remove the Access app**

Cloudflare dashboard → Zero Trust → Access → Applications → delete the app named `argocd` (`argocd.algovn.com`). (This was the last admin-UI Access app; the pending ssh-host apps are unrelated.)

- [ ] **Step 2: Edge verification (§4.5)**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://argocd.algovn.com/
curl -s https://argocd.algovn.com/api/v1/settings | jq -r '.oidcConfig.issuer'
```
Expected: `200` (Argo serves its SPA directly — no cloudflareaccess redirect) and `https://id.algovn.com`.

- [ ] **Step 3: CLI SSO (§4.4) — needs the gate gone, hence this task**

```bash
which argocd || brew install argocd
argocd login argocd.algovn.com --sso --grpc-web
argocd app list --grpc-web | head -5
```
Expected: browser opens (or prints a URL) → existing Zitadel session or passkey → "'minhducle.dev@gmail.com' logged in successfully"; `app list` returns the platform apps. ((USER) completes the browser hop.)

- [ ] **Step 4: Doc updates**

`docs/runbooks/cloudflare-access.md`: protected-hosts line becomes `Current protected hosts: none (admin UIs use Zitadel SSO — grafana 2026-07-13, argocd 2026-07-13). Pending: the ssh/k8s host-tunnel apps below.`; delete the App 1 (argocd) recreation item; keep the OTP-debugging + pending-hosts sections (still relevant for the host tunnels).

`docs/runbooks/verify.md`: in the AuthN/Z section append:
```markdown
- Argo CD SSO: `curl -s https://argocd.algovn.com/api/v1/settings | jq -r .oidcConfig.issuer` → `https://id.algovn.com`; UI "Log in via AlgoVN ID" → passkey → admin; local admin login = break-glass; `argocd login argocd.algovn.com --sso --grpc-web` works
```

`docs/superpowers/specs/2026-07-13-authnz-foundation-design.md` §9: change the row `| Migrating Argo CD off CF Access onto Zitadel SSO (Grafana done 2026-07-13 — see grafana-zitadel-sso spec) | Desire to consolidate |` to `| ~~Migrating admin tools off CF Access~~ Done: Grafana + Argo CD on Zitadel SSO, 2026-07-13 (grafana-/argocd-zitadel-sso specs) | — |`.

- [ ] **Step 5: Validate, commit, push, all-green**

Run: `scripts/validate.sh` → `PASS`
```bash
git add docs/runbooks/cloudflare-access.md docs/runbooks/verify.md
git add -f docs/superpowers/specs/2026-07-13-authnz-foundation-design.md
git commit -m "docs: argocd off CF Access — Zitadel SSO live; admin-UI Access era closed"
git push
```
`kubectl --context algovn-remote get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'` → every row `Synced/Healthy` (§4.6).

---

## Failure modes & decision rules

- **SSO button missing on the login page:** `oidc.config` failed to parse — `kubectl --context algovn-remote logs -n argocd deploy/argocd-server --tail=30 | grep -i oidc` shows the reason; commonest is YAML indentation inside the `oidc.config: |` block.
- **Zitadel error `invalid_request ... redirect_uri`:** the app's redirect list doesn't exactly match `https://argocd.algovn.com/auth/callback` (Grafana precedent — check https vs http, trailing slash, typos).
- **`Errors.App.NotFound` at Zitadel:** clientID mangled or wrong — compare the settings-API value char-for-char with the console's Client ID (Grafana precedent: quoting).
- **Login works but admin sees empty app list:** the `scopes: '[email]'` ↔ policy.csv email mismatch — confirm the Zitadel account's email is exactly `minhducle.dev@gmail.com` (case-sensitive match in Argo RBAC) and that the `email` scope was granted (requestedScopes includes it).
- **CLI `--sso` hangs:** port 8085 busy or Dev Mode off on the Zitadel app (localhost redirect rejected). `lsof -i :8085` first, then re-check the app config.

## Spec-coverage map (self-check)

| Spec item | Task |
|---|---|
| §3 Zitadel app (PKCE, redirects, Dev Mode), runbook'd | 1 |
| §3 oidc-cm + rbac-cm patches, nothing else touched | 2 |
| §4.1 admin / §4.2 deny / §4.3 break-glass | 3 |
| §4.4 CLI / §4.5 edge / §4.6 all-green | 4 |
| §5 docs (zitadel.md T1; cloudflare-access, verify, authnz §9 T4) | 1, 4 |
| §6 deferred respected (no Action, no dex, no notifications) | all |
