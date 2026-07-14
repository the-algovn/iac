# API conventions — api.algovn.com

Architecture: the-algovn/specs `ARCHITECTURE.md`.
Every product API lives under `https://api.algovn.com/<prefix>/…`, served by
`api-control-plane` (Kong routes the host with NO jwt-auth plugin; the control
plane verifies Zitadel JWTs itself — see authnz-conventions.md).

## Calling an API
`POST /<prefix>/<pkg.Service>/<Method>` with a JSON body (protojson mapping,
≤1 MiB). Errors: `{"code":"<grpc-code>","message":"…"}`; status mapping:
InvalidArgument→400, Unauthenticated→401, PermissionDenied→403, NotFound→404,
Unavailable→502, DeadlineExceeded→504, else 500.

## Registering a product API
Add `apps/api-control-plane/registrations/<product>.yaml` in THIS repo (PR-reviewed,
hot-reloaded — no gateway restart):

    prefix: /<product>              # single lowercase segment
    upstream: dns:///<svc>.<ns>.svc.cluster.local:9090
    defaultRule: authenticated      # anonymous | authenticated | role:<r>
    routes:
      - method: algovn.<product>.v1.<Service>/<Method>
        rule: anonymous
        deadline: 3s                # optional, default 5s
    channels:
      - name: <product>.<topic>     # SSE channel, same rule vocabulary
        rule: anonymous

Requirements for the upstream: pure gRPC on :9090 h2c with server reflection
enabled (descriptors are fetched via reflection; unary only in v1). The
verified `Authorization` header arrives as gRPC metadata — parse claims per
authnz-conventions.md, never re-verify.

Tenancy boundary: a registration may point its upstream at ANY cluster
Service, and the gateway forwards end-user Authorization headers to it. PR
review of registrations/*.yaml IS the boundary — there are no NetworkPolicies.
Review upstream addresses accordingly.

## Realtime push (shared mechanic)
Publish JSON to RabbitMQ topic exchange `events`, routing key = channel name;
body = exactly what browsers receive. Browsers: `new EventSource
('https://api.algovn.com/events/<channel>')`. No replay: snapshots or
fire-and-forget only. Broker creds: seal a copy of `amqp-creds` into your
namespace (double-seal pattern, source `rabbitmq-events` in the password
manager). Go publish example: see `cmd/demo-service/main.go` (newPublisher)
in the api-control-plane repo.

v1 limitation: native EventSource cannot send an Authorization header, so
browser-consumed channels must be `anonymous`. Token-gated channels need a
fetch-based SSE client (or a v2 token transport such as a query-param ticket).
