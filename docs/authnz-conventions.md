# AuthN/Z conventions
Architecture: the-algovn/specs `ARCHITECTURE.md`. Zitadel (id.algovn.com)
owns WHO YOU ARE (users, orgs, org roles → in the token). OpenFGA owns WHAT YOU CAN TOUCH
(per-resource relations). Kong's `jwt-auth` plugin is the edge gate. Runbooks: zitadel.md,
zitadel-key-rotation.md.

## Protecting a route (edge gate)
Ingress annotation: `konghq.com/plugins: jwt-auth`. Kong 401s missing/invalid/expired
tokens (RS256, kid-matched against the committed public key). Machine routes keep key-auth.

**Exception — api.algovn.com:** this host is routed to `api-control-plane`
WITHOUT Kong's jwt-auth plugin. The control plane verifies RS256 signatures
against Zitadel's JWKS (auto-refreshed — no committed public key, no manual
rotation) and enforces per-route rules (anonymous / authenticated / role:<r>)
from GitOps registration files. Upstream services behind it keep the same
contract: parse the forwarded token payload, never re-verify. See
docs/api-conventions.md.

## What your service does with the token
Kong verified the SIGNATURE; your service still parses the payload for identity (read-only
base64 decode of segment 2 — do NOT re-verify, do NOT skip parsing):
- `sub` — stable user id ・ `iss` must be https://id.algovn.com (assert it)
- `urn:zitadel:iam:org:project:roles` — {role: {orgID: orgDomain}} (needs project
  "Assert Roles on Authentication" + scope `urn:zitadel:iam:org:projects:roles`)
- `urn:zitadel:iam:user:resourceowner:id` — the user's org id
Role checks (org-level, coarse) happen HERE from claims. Per-resource checks go to OpenFGA.
Never invent per-app auth: no local users, no password fields, no API-issued sessions.

## Registering a product (console, org AlgoVN — see zitadel.md)
1. Project `<product>` (+ check Assert Roles) with roles it needs (keep coarse: admin/member).
2. Applications in that project: SPA → Web + PKCE (no secret); CLI → Native + device code;
   server → Web + client secret, or service user for M2M.
   ⚠️ EVERY app/service-user whose tokens must pass the Kong gate needs
   **Auth/Access Token Type: JWT** (Zitadel's default is opaque Bearer → edge 401).
   ⚠️ Roles claim is app-gated too: enable accessTokenRoleAssertion (and
   idTokenRoleAssertion) on the app — project-level "assert roles" alone is not enough.
   Avoid the device-code grant for now: it falls back to the legacy v1 login (separate
   sessions, different IdP callback) until Zitadel's login v2 supports it.
3. Customer orgs get the project via Project Grants; users get role Authorizations. GitHub IdP is configured-pending (Google live) — see zitadel.md.

## OpenFGA
- Endpoints (cluster-internal ONLY): gRPC dns:///openfga-grpc.openfga.svc.cluster.local:9090
  (deadline 5s, round_robin — grpc-conventions.md applies), HTTP http://openfga.openfga.svc:8080.
- Gotcha: OpenFGA's authn interceptor also gates gRPC REFLECTION — grpcurl/SDK tooling needs the bearer token even to resolve descriptors; only grpc.health.v1 is exempt. The container binds gRPC on 9090 natively (values grpc.addr) — headless Services cannot remap ports, so never rely on port/targetPort translation for any chart's native port.
- Auth: preshared key. Seal a copy into your app's ns (postgres.md double-seal pattern;
  rotation = reseal everywhere, source of truth in password manager `openfga-api-key`).
- One STORE per product, created at onboarding: use the HTTP API or fga CLI (see the e2e
  transcript in the authnz plan Task 12 for exact calls). Record the store id in app config.
- The MODEL (.fga DSL) lives in the product repo; CI applies it; the app PINS the returned
  authorization_model_id and passes it on every Check/Write (immutable model versions —
  same rule as protos: never mutate, always add).
- Single writer: only the owning app writes its store's tuples (on resource create/share/delete).
- Org bridge: on login, JIT-write org:<orgid>#member@user:<sub> from token claims if your
  model needs `member from parent_org`. Mirror MEMBERSHIP only — org roles stay in the token.
- Enforce with Check AT THE API BOUNDARY (UI hiding is cosmetics). ListObjects for listings,
  sparingly.

## Go snippets
Claims (after Kong):
    type ZClaims struct {
        Sub string `json:"sub"`
        Iss string `json:"iss"`
        Roles map[string]map[string]string `json:"urn:zitadel:iam:org:project:roles"`
    }
    seg := strings.Split(bearer, ".")[1]
    b, _ := base64.RawURLEncoding.DecodeString(seg)
    var c ZClaims; json.Unmarshal(b, &c)   // assert c.Iss == "https://id.algovn.com"
FGA check (github.com/openfga/go-sdk/client):
    fga, _ := client.NewSdkClient(&client.ClientConfiguration{
        ApiUrl: "http://openfga.openfga.svc:8080", StoreId: storeID,
        AuthorizationModelId: modelID,
        Credentials: &credentials.Credentials{Method: credentials.CredentialsMethodApiToken,
            Config: &credentials.Config{ApiToken: os.Getenv("FGA_API_KEY")}}})
    ctx, cancel := context.WithTimeout(ctx, 5*time.Second); defer cancel()
    ok, _ := fga.Check(ctx).Body(client.ClientCheckRequest{
        User: "user:"+c.Sub, Relation: "viewer", Object: "doc:"+id}).Execute()
    if !ok.GetAllowed() { /* 403 */ }
(gRPC client instead of HTTP is fine too — port 9090, same preshared key via
PerRPCCredentials; HTTP SDK shown because it's the shortest correct thing.)

## Deferred (spec §9)
Custom login app (design system) · per-user rate limiting · JWKS auto-sync · SMTP flows ·
Terraformed IdP config · FGA HA.
