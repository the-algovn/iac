# API conventions — api.algovn.com

Architecture: the-algovn/specs `ARCHITECTURE.md`.
Every product API lives under `https://api.algovn.com/<prefix>/…`, served by
`api-control-plane` (Kong routes the host with NO jwt-auth plugin; the control
plane verifies Zitadel JWTs itself — see authnz-conventions.md).

## Calling an API
Each gRPC method is exposed at an explicit HTTP verb + path declared in the
product's registration (below), e.g. `GET /the-button/counter`,
`POST /the-button/clicks`. Write methods take a JSON body (protojson mapping,
≤1 MiB). An unregistered path returns 404; a registered path called with the
wrong verb returns 405 with an `Allow` header. Errors:
`{"code":"<grpc-code>","message":"…"}`; status mapping: InvalidArgument→400,
Unauthenticated→401, PermissionDenied→403, NotFound→404, Unavailable→502,
DeadlineExceeded→504, else 500.

## Registering a product API
Add `apps/api-control-plane/registrations/<product>.yaml` in THIS repo (PR-reviewed,
hot-reloaded — no gateway restart):

    prefix: /<product>              # single lowercase segment
    upstream: dns:///<svc>.<ns>.svc.cluster.local:9090
    defaultRule: authenticated      # anonymous | authenticated | role:<r>
    routes:                         # authoritative allowlist: unlisted methods are unreachable
      - method: algovn.<product>.v1.<Service>/<Method>   # gRPC target
        verb: GET                   # GET | POST | PUT | PATCH | DELETE
        path: /<resource>           # relative to prefix; ^(/[a-z0-9-]+)+$
        rule: anonymous             # anonymous | authenticated | role:<r>
        deadline: 3s                # optional, default 5s
    channels:
      - name: <product>.<topic>     # SSE channel, same rule vocabulary
        rule: anonymous

Each `(verb, prefix+path)` pair must be unique across all registrations.

Requirements for the upstream: pure gRPC on :9090 h2c with server reflection
enabled (descriptors are fetched via reflection; unary only in v1). The
verified `Authorization` header arrives as gRPC metadata — parse claims per
authnz-conventions.md, never re-verify.

Tenancy boundary: a registration may point its upstream at ANY cluster
Service, and the gateway forwards end-user Authorization headers to it. PR
review of registrations/*.yaml IS the boundary — there are no NetworkPolicies.
Review upstream addresses accordingly.

## Realtime push (shared mechanic)
Publish JSON to a Kafka (Redpanda) topic named after the channel; body =
exactly what browsers receive. Browsers: `new EventSource
('https://api.algovn.com/events/<channel>')`. No replay: snapshots or
fire-and-forget only. Broker address: the `KAFKA_BROKERS` env literal
(`redpanda.redpanda.svc.cluster.local:9092`) — not secret, no ExternalSecret
needed. See `the-button-service`/`the-button-worker` for a working
producer/consumer example.

v1 limitation: native EventSource cannot send an Authorization header, so
browser-consumed channels must be `anonymous`. Token-gated channels need a
fetch-based SSE client (or a v2 token transport such as a query-param ticket).
