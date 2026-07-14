# Kong gateway

Kong OSS, DB-less, Kong Ingress Controller. App `kong` (wave -3), config `platform/kong/`.
Default TLS: Certificate `wildcard-algovn` in ns kong → secret `wildcard-algovn-tls`.
Admin API is cluster-internal; Kong Manager disabled. Rate limiting: policy `local` only
(single node — revisit if a second node joins).

## Protect a route (key-auth + rate limit)
1. KongPlugin (namespace of the app):
   `plugin: key-auth` — and/or `plugin: rate-limiting` with `config: {minute: N, policy: local}`.
2. Consumer + key (key lives in OpenBao, synced by ESO — see `docs/runbooks/secrets.md`):
   Write the key to bao at `secret/algovn/<ns>/<app>-apikey` (field `key`), then add an
   ExternalSecret manifest `<dir>/<app>-apikey-external.yaml` referencing ClusterSecretStore `bao`.
   Add label `konghq.com/credential: key-auth` under the ExternalSecret `spec.target.template.metadata.labels`.
   KongConsumer with `credentials: [<app>-apikey]` (annotation `kubernetes.io/ingress.class: kong`).
3. Bind on the Ingress: annotation `konghq.com/plugins: "<plugin-names>"`.
4. Verify: curl without key → 401; with `apikey: <KEY>` header → 200.

## JWT validation
Deployed (2026-07-13). Protect a route by annotating its Ingress `konghq.com/plugins:
jwt-auth`. The plugin is a CLUSTER-scoped `KongClusterPlugin` named `jwt-auth` — do NOT
create a namespaced `KongPlugin` with the same name. Consumer `zitadel-issuer` holds the
pinned Zitadel public key. Key rotation: `docs/runbooks/zitadel-key-rotation.md`. Token
contract: `docs/authnz-conventions.md`.

## Debug
- Routes not admitted: `kubectl -n kong logs deploy -l app.kubernetes.io/component=controller --tail 50`
- What Kong sees: `kubectl -n kong port-forward svc/kong-gateway-admin 8001:8001` is NOT exposed;
  use controller logs + `kubectl get ingresses,kongplugins,kongconsumers -A` instead.
- Metrics: Grafana "Kong (official)" dashboard; logs: Loki `{namespace="kong"}`.
