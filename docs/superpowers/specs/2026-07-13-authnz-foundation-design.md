# AuthN/Z Foundation — Design

**Date:** 2026-07-13
**Status:** Approved (brainstorm dialogue)
**Depends on:** `2026-07-11-k3s-gitops-cluster-design.md`, `2026-07-12-kong-gateway-grpc-conventions-design.md` (both live per README Status)

## 1. Goal

Deliver the authN/Z foundation for the algovn SaaS platform: one shared identity
(sign up once, SSO into every product), organizations with per-org roles, and a
central fine-grained permission service — self-hosted, GitOps-managed, consumable
by future apps without new design work. Login at launch: Google, GitHub, and
passkeys. Passwordless — no password storage anywhere.

This fires two deferred triggers from prior specs: the Kong spec's "jwt when an
issuer exists" (§5) and the k3s spec's "PV data backups before first stateful
app" (§13) — identity data is the first irreplaceable state.

## 2. Decisions (from brainstorm Q&A)

| Question | Decision |
|---|---|
| First consumer | Foundation first, no concrete app yet (same philosophy as gRPC conventions) |
| Identity scope | One shared user pool + SSO across all SaaS products |
| Tenancy | Users + organizations (B2B-ready: memberships, per-org roles) from day one |
| Login methods | Social (Google/GitHub) + passkeys (WebAuthn). No passwords, no email OTP |
| AuthZ depth | Central fine-grained permission service, Zanzibar-style |
| Hosting | Self-hosted on cluster (no external IdP dependency) |
| Stack | **Zitadel** (IdP) + **OpenFGA** (permissions), both on existing CNPG Postgres. Chosen over Ory stack (headless — would require building login UI + org model) and Keycloak (JVM footprint exceeds Pi budget) |
| Token validation | At the Kong edge via `jwt` plugin (user decision; mechanics in §4) |
| Login UI | Stock Zitadel **login v2** pod (chart default; v4 deprecates the built-in v1 login). Custom login app sharing the platform design system = deferred (§9) |

**Out of scope:** any concrete SaaS app, email/SMTP flows, Kong-issued tokens
(Kong stays validate-only per its spec), migrating Argo CD/Grafana off
Cloudflare Access.

## 3. Target architecture

```
Browser ── CF edge ── tunnel ─▶ Kong ─▶ id.algovn.com ─▶ Zitadel ──┐
  │   (login page, OIDC endpoints, JWKS — public)                  │   CNPG Postgres
  │                                                                ├─▶ (zitadel DB,
  └─ SPA/app with access token                                     │    openfga DB)
        │                                                          │
        ▼                                                          │
Kong [jwt plugin: 401 gate] ─▶ app.algovn.com ─▶ SaaS service ─────┘
                                       │
                                       └── gRPC h2c east-west ─▶ OpenFGA :9090 (never public)
```

- **Zitadel** (`platform/zitadel/`): Go binary + chart-managed **login v2**
  pod (Next.js), public at `id.algovn.com` via a normal kong-class Ingress. The only OIDC
  issuer on the platform; each SaaS product registers as a Zitadel application
  → SSO falls out for free.
- **OpenFGA** (`platform/openfga/`): cluster-internal only, follows the gRPC
  conventions (headless Service, port 9090 named `grpc`, metrics 9091,
  grpc_health_v1, deadlines). No Ingress, ever.
- **Division of labor (load-bearing boundary):** *Zitadel owns who you are* —
  users, orgs, memberships, org-level roles, delivered in the token. *OpenFGA
  owns what you can touch* — per-resource, relationship-based permissions,
  written and queried by each app. Apps bridge the two (§6).

## 4. Edge JWT validation (Kong OSS mechanics)

Kong OSS's `jwt` plugin cannot fetch JWKS (Enterprise feature), so key material
is explicit:

- **Gate:** `jwt` KongPlugin bound via `konghq.com/plugins` annotation on every
  user-facing API route (same convention as key-auth). Invalid/absent token →
  consistent `401` at the edge; requests never reach services.
- **Key material:** one `KongConsumer` `zitadel-issuer` holds a `jwt` credential
  with Zitadel's current RS256 signing **public key** (issuer
  `https://id.algovn.com`). Public keys aren't secret → plain committed Secret,
  not a SealedSecret.
- **Rotation is controlled, not automatic:** Zitadel *web keys* (managed
  web-key API, standard in the deployed v4) put
  signing-key rotation under our control instead of auto-rotating under Kong.
  The plugin is configured with `key_claim_name: kid` so credentials are
  matched by the token's `kid` header — two credentials (old + new key) can
  coexist during rotation. Runbook: create new web key → add its credential →
  activate in Zitadel → retire old credential. Zero-downtime; executed once as
  part of verification (§8).
- **What Kong does NOT provide:** the plugin maps every valid token to the
  single `zitadel-issuer` consumer — it answers "is this a valid platform
  token?", not "who is this user?". **Apps parse the already-verified JWT
  payload for identity and claims** (read-only decode; no key management in
  apps). Per-user rate limiting stays deferred; per-IP `rate-limiting` works
  today.
- Machine-to-machine routes keep plain `key-auth` — unchanged.

## 5. Identity model (Zitadel)

- **One platform org** (`AlgoVN`) administers everything. Each SaaS product =
  one Zitadel **project** owned by that org; each client of a product (web SPA,
  CLI, machine client) = an **application** in that project. SPAs use OIDC
  authorization-code + PKCE; no client secrets in browsers.
- **Customer tenancy:** each team/company = a Zitadel **organization**; a
  product's project is *granted* to the customer org and users get role
  **authorizations** scoped to their org — Zitadel's native B2B model, no
  custom schema. Individual users self-register into a shared default org
  (`users`): solo users work day one, teams are an org-grant away.
- **Roles** are defined per project (product-specific, e.g. `admin`, `member`)
  and arrive in the access token via Zitadel's project-roles claim (requested
  with the standard Zitadel scopes). Convention: roles stay coarse (org-level
  job titles); anything per-resource belongs to OpenFGA.
- **Login:** Google + GitHub as instance-wide identity providers with
  auto-registration; passkeys enabled natively (register at first login or from
  the account page). No password authenticator enabled. Users self-manage
  sessions/passkeys via Zitadel's account UI.
- **SSO:** one browser session at `id.algovn.com`; every product's OIDC
  redirect reuses it silently.
- **Administration:** Zitadel console, instance admin secured with a passkey.
  IdP content (projects, grants, IdP configs) managed via console + captured in
  a runbook — deliberately not Terraformed (same precedent as CF Access; see
  §9 trigger). `docs/authnz-conventions.md` (sibling of `grpc-conventions.md`)
  records the contract apps code against: token validation expectations, claim
  shapes, scopes, FGA conventions (§6).

## 6. Permission model (OpenFGA) & app conventions

- **One OpenFGA instance, one store per product** — models evolve
  independently. Store creation is part of app onboarding (runbook'd).
- **Models are code:** each product's FGA model (DSL) lives in that product's
  repo, applied via its CI/deploy. Model versions are immutable (every change =
  new model ID); the app pins the model ID it was tested against — same spirit
  as the proto versioning rule.
- **Tuple ownership — single writer:** the owning app writes/deletes tuples as
  resources live and die. Nothing else writes to its store.
- **The org bridge:** FGA doesn't know Zitadel exists. On login, an app
  JIT-writes `org:<id>#member@user:<id>` tuples from verified token claims so
  models can reference org membership (`define viewer: member from
  parent_org`). Org *roles* stay in the token (Zitadel-owned); org *membership
  as a relation* may be mirrored; never mirror role logic itself.
- **Enforcement point:** services call `Check` at the API boundary (gRPC, 5s
  deadline per client discipline) — UI hiding is cosmetics, the Check is the
  gate. `ListObjects` available for listings, used judiciously.
- **API security:** preshared-key auth on OpenFGA (SealedSecret) — config-only
  hardening on top of the accepted in-cluster h2c posture.

## 7. Deployment & operations

- **GitOps shape:** `platform/zitadel/` + `platform/openfga/` (official Helm
  charts, pinned, Renovate-watched) + Applications in
  `clusters/algovn/platform/`, sync-waved after the Postgres wave. Zitadel gets
  a kong-class Ingress at `id.algovn.com` (external-dns as usual).
- **Databases:** two new databases in the existing CNPG cluster (`zitadel`,
  `openfga`), each with its own owner role; credentials sealed. Zitadel's
  `masterkey` is a SealedSecret **and** joins the sealing key in the password
  manager as root-of-trust — rebuild needs both (rebuild runbook updated).
- **Resources (requests → limits):**

  | Component | RAM | Notes |
  |---|---|---|
  | Zitadel | 300Mi → 512Mi | `GOMEMLIMIT` tuned |
  | Zitadel login v2 | 128Mi → 256Mi | Next.js pod (chart-managed) |
  | OpenFGA | 64Mi → 192Mi | |

  Budget note: ~500Mi requested net new. Since the k3s spec, the cluster
  gained a second node (`w1`, hosts Postgres/vmsingle/Loki) — pods schedule
  across both nodes, so this fits, but verification still gates on headroom
  per node (§8.9). Pressure valves as in the Kong spec remain available.
- **Backups:** ~~CNPG scheduled backups to Cloudflare R2~~ **Descoped at
  execution (user decision, 2026-07-13)** — the cluster remains backup-less;
  postgres.md's NO BACKUPS warning stays accurate. Accepted risk: disk loss
  on w1 = permanent loss of all identities. Re-entry: the plan's Tasks 1–3
  remain executable as written (Task 1, the barman-cloud plugin, is deployed).
- **Observability:** VMServiceScrapes for both (Prometheus metrics), Grafana
  dashboards provisioned from git, logs via existing Alloy. ~~New alert: backup
  staleness~~ (descoped with backups, 2026-07-13).

## 8. Verification criteria

1. `https://id.algovn.com/.well-known/openid-configuration` serves publicly
   with issuer `https://id.algovn.com`; login page renders.
2. E2E signup: Google **and** GitHub auto-register; passkey registered, then
   login from a fresh browser session with passkey alone. No password option
   visible anywhere.
3. SSO: a second test OIDC client reuses the existing session without
   re-prompting.
4. Edge gate: throwaway Ingress + `jwt` plugin (removed after, Kong-spec e2e
   pattern) — no/garbage/expired token → `401` from Kong; valid Zitadel access
   token → `200`.
5. Claims: test user in a test org receives the project role in the access
   token.
6. OpenFGA from in-cluster via gRPC: apply demo model, write tuple → `Check`
   allows, delete tuple → denies.
7. Key rotation runbook executed once end-to-end with no 401 window.
8. ~~Backup/restore runbook executed once~~ Waived — backups descoped at
   execution (user decision, 2026-07-13; see §7).
9. All Argo apps Synced/Healthy; `free -h` available ≥ 250Mi post-deploy on
   each node (pressure valves execute before sign-off if breached).
10. Both services' metrics in VictoriaMetrics, dashboards render, logs in Loki.

## 9. Explicitly deferred (with triggers)

| Deferred | Trigger to revisit |
|---|---|
| Email/SMTP (org invites to unregistered users, notifications) | First flow that genuinely needs email |
| JWKS→Kong auto-sync CronJob | Rotation needed >2×/year, or a rotation incident |
| Per-user rate limiting at edge | First abuse incident |
| Zitadel config via Terraform provider | IdP objects grow past a handful / drift pain |
| Migrating Argo CD off CF Access onto Zitadel SSO (Grafana done 2026-07-13 — see grafana-zitadel-sso spec) | Desire to consolidate |
| Zitadel/OpenFGA HA replicas | Second node joins |
| Self-service org creation, SCIM, MFA policies, audit-log shipping | First real team customer / compliance need |
| Custom login app (fork of Zitadel's login v2, restyled) in `the-algovn/login` | First product design system exists — gets its own spec/plan |
