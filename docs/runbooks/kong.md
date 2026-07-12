# Kong gateway

Kong OSS, DB-less, Kong Ingress Controller. App `kong` (wave -3), config `platform/kong/`.
Default TLS: Certificate `wildcard-algovn` in ns kong → secret `wildcard-algovn-tls`.
Admin API is cluster-internal; Kong Manager disabled. Rate limiting: policy `local` only
(single node — revisit if a second node joins).

## Protect a route (key-auth + rate limit)
1. KongPlugin (namespace of the app):
   `plugin: key-auth` — and/or `plugin: rate-limiting` with `config: {minute: N, policy: local}`.
2. Consumer + key (key sealed for git!):
   kubectl create secret generic <app>-apikey -n <ns> --from-literal=key=<KEY> --dry-run=client -o yaml \
     | scripts/seal.sh > <dir>/<app>-apikey-sealed.yaml
   Add label `konghq.com/credential: key-auth` under the SealedSecret `spec.template.metadata.labels`.
   KongConsumer with `credentials: [<app>-apikey]` (annotation `kubernetes.io/ingress.class: kong`).
3. Bind on the Ingress: annotation `konghq.com/plugins: "<plugin-names>"`.
4. Verify: curl without key → 401; with `apikey: <KEY>` header → 200.

## JWT validation (when an issuer exists)
`plugin: jwt` KongPlugin + KongConsumer with a jwt credential secret holding the issuer's
public key. Not deployed — pattern only.

## Debug
- Routes not admitted: `kubectl -n kong logs deploy -l app.kubernetes.io/component=controller --tail 50`
- What Kong sees: `kubectl -n kong port-forward svc/kong-gateway-admin 8001:8001` is NOT exposed;
  use controller logs + `kubectl get ingresses,kongplugins,kongconsumers -A` instead.
- Metrics: Grafana "Kong (official)" dashboard; logs: Loki `{namespace="kong"}`.
