# Internal gRPC conventions

Scope: east-west only — gRPC never traverses Kong. Plaintext h2c inside the cluster
(single-node accepted risk; mTLS/mesh is a multi-node trigger, spec §8).

## Contracts
- All protos in `the-algovn/protos`, managed with buf. CI gates `buf lint` and
  `buf breaking --against '.git#branch=main'`.
- Generated Go is committed in that repo under `gen/go/` and consumed as a Go module:
  `go get github.com/the-algovn/protos/gen/go@latest`. Services never run protoc locally.
- Package naming: `algovn.<service>.v1`; breaking change ⇒ new `v2` package, never mutate `v1`.

## Service shape (see templates/grpc-service/)
- Port 9090 named `grpc`; Prometheus metrics on 9091 named `metrics`.
- Headless Service (clusterIP: None). Clients dial
  `dns:///NAME.NAMESPACE.svc.cluster.local:9090` with
  `grpc.WithDefaultServiceConfig('{"loadBalancingConfig":[{"round_robin":{}}]}')`
  — no client change needed when replicas > 1.
- Implement `grpc_health_v1.Health`; k8s-native gRPC probes (no sidecar binary).
- Enable server reflection in all environments (single-tenant cluster; aids grpcurl debugging).

## Client discipline
- Every outbound call sets a deadline (default 5s; long ops explicit).
- Retries ONLY via service config on idempotent methods (maxAttempts 3, exponential backoff);
  never hand-rolled retry loops.
- Keepalive: client `Time: 30s, Timeout: 10s, PermitWithoutStream: false`;
  server `MinTime: 15s` enforcement to match.

## Observability
- go-grpc-middleware v2 Prometheus interceptors (server + client), `/metrics` on 9091,
  VMServiceScrape per service (template included). Tracing deferred (spec §8).

## Exposure
- A gRPC service never gets an Ingress. If one ever needs to be public: Kong proxies
  gRPC/gRPC-Web — design that when it happens (spec §8 trigger).
