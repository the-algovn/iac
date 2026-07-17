# the-button (algovn.com/the-button)

Live global click counter; PoW-gated. Service ns `the-button` (`the-button-service`,
2 replicas, gRPC :9090 + metrics :9091), SPA ns `the-button-web`, routed via
api-control-plane registration `/the-button` and SSE channel `the-button.counter`.
Design docs: `specs/products/the-button.md` (product) and `specs/ARCHITECTURE.md`
(platform); this runbook is self-contained and doesn't require either for on-call
use. Load/calibration evidence: `iac/docs/load-results-the-button.md`. Data: Redis ns `redis`
(hot control state — `pow:L`, `pow:min_interval`), Postgres db
`the_button` in the shared CNPG cluster (durable truth — `SUM(user_clicks)` is the
only counter truth). Alerts: VMRule
`the-button-alerts` (`platform/monitoring/manifests/the-button-rules.yaml`).

## Degradation ladder (manual — nothing here is automated)

Apply cheapest/lowest-blast-radius first; revert once the triggering alert clears.

`REDIS_PASS` helper (secret `redis-auth`, ns `redis`, key `password`):
```
REDIS_PASS=$(kubectl --context algovn-remote -n redis get secret redis-auth -o jsonpath='{.data.password}' | base64 -d)
```

1. **Raise PoW difficulty / the hard throttle (click relief, immediate, transient).**
   `pow:min_interval` is the HARD per-user valve; `pow:L` is the cost valve the SPA's
   solver sizes its batch against (`POW_W0=2048`, ~1.5s target solve, shrinks
   automatically as `L` rises). Force both up by hand:
   ```
   kubectl --context algovn-remote -n redis exec redis-0 -- redis-cli -a "$REDIS_PASS" SET pow:min_interval 10
   kubectl --context algovn-remote -n redis exec redis-0 -- redis-cli -a "$REDIS_PASS" SET pow:L 16
   ```
   ⚠️ The publisher (single replica) recomputes both keys every ~1s from an EWMA of
   accepted-submit rate. A manual `SET` is overwritten within ~1s UNLESS real load
   already keeps the controller pinned there itself — treat this as a nudge to
   confirm the controller's own ceiling, not a durable latch. For a durable clamp use
   knobs 2/3 below instead.

2. **Lower the SSE cap (edge relief, durable, but NOT connection-preserving).** Fewer
   held connections means less cloudflared memory and less acp memory:
   ```
   kubectl --context algovn-remote -n api-control-plane set env deploy/api-control-plane SSE_MAX_CONNS=8000
   ```
   ⚠️ `kubectl set env` patches the pod template, which triggers a RollingUpdate
   (`maxSurge:1/maxUnavailable:0`, 2 replicas) — **this drops every existing SSE
   connection**, not just new ones above the cap, as each pod is replaced (measured
   ~23-24s rollout wall time). Clients reconnect with the SPA's own full-jitter
   exponential backoff (cap starts 5s, doubles per failure, ceilinged at 60s) — full
   recovery measured at ~127s in a single-IP test (see Known limits), likely faster
   with real, distributed clients. Only once the rollout completes do new connections
   above the (now-lower) cap start getting a 503. Revert by re-setting to `15000`
   (same rolling-restart caveat applies).

3. **Scale cloudflared / acp / the-button-service (throughput + memory relief).**
   No HPA on any long-lived-connection path — scale by hand:
   ```
   kubectl --context algovn-remote -n cloudflared scale deploy/cloudflared --replicas=4
   kubectl --context algovn-remote -n api-control-plane scale deploy/api-control-plane --replicas=3
   kubectl --context algovn-remote -n the-button scale deploy/the-button-service --replicas=3
   ```
   ⚠️ **Scaling cloudflared does NOT raise the SSE ceiling** (measured — see Known
   limits: 3→6 replicas left 3 pods completely idle and the wall did not move). The 503
   wall is at the Cloudflare edge, not in a pod we can scale. Scale cloudflared only for
   redundancy or a genuine memory alert; to relieve an SSE ceiling use knob 2 (lower
   `SSE_MAX_CONNS`) instead. Restarting/scaling `the-button-service` does not drop
   SSE (that path is entirely acp+cloudflared); each api replica polls Postgres
   independently for its own `GetCounter` cache, so there is no leadership to fail
   over. `the-button-publisher` (the separate single-replica broadcaster) is
   unaffected by scaling `the-button-service` either way.

## What each alert means

### Alert: cloudflared memory & restarts
- `ButtonCloudflaredMemoryHigh` — working set > 75% of the 768Mi limit for 10m.
- `ButtonCloudflaredOOMRestart` — any cloudflared restart in the last 10m.

⚠️ **These are leak/regression safety nets, NOT the SSE capacity wall.** The original
512Mi OOM (2026-07-14, ~7.4k streams) was real and is fixed (now 6×768Mi; measured peaks
251–339Mi, i.e. ~33–44% of limit, 0 restarts across two later ramps). The SSE ceiling
that remains is a **503 wall at the Cloudflare edge** which appears while cloudflared
memory is still low — see Known limits. A memory alert here at *normal* connection counts
therefore means a **leak**, not saturation.

First three checks:
1. `kubectl --context algovn-remote -n cloudflared get pods` — how many replicas, any
   `OOMKilled`/restart count.
2. Current SSE connection count: `sum(acp_sse_clients)` (see next alert) — is a real
   ramp in progress, or a leak? High memory with *low* connection count = leak.
3. Apply knob 2 (lower `SSE_MAX_CONNS`). **Do not expect knob 3 (scaling cloudflared) to
   raise the SSE ceiling — it is measured not to.** Scale only to relieve genuine
   per-pod memory pressure.

### Alert: acp memory & SSE clients
- `ButtonAcpMemoryHigh` — api-control-plane RSS > 75% of its 1Gi limit for 10m.
- `ButtonSSEClientsNearCap` — `sum(acp_sse_clients) > 12000` (80% of `SSE_MAX_CONNS=15000`)
  for 5m. Measured: acp RSS peaked ~110–125Mi of 1Gi at 5.5k–7.4k connections — acp was
  never close to distressed in any run. A memory alert here without a matching connection
  count is more likely a leak or a different workload.

⚠️ **`SSE_MAX_CONNS=15000` is not a capacity claim.** The edge 503s new connections
somewhere between ~5.5k and ~8.2k (single-IP measurement), so this cap has never actually
been reached and this alert has never fired for real. Expect the *edge* to refuse
connections long before acp's own cap does.

First three checks:
1. `sum(acp_sse_clients)` and `max(process_resident_memory_bytes{namespace="api-control-plane"})`
   via the vmsingle HTTP API (`svc vmsingle-vm:8428`, see `docs/runbooks/postgres.md`
   for the query pattern).
2. `kubectl --context algovn-remote -n api-control-plane get pods` — restarts, per-pod
   RSS split evenly across the 2 replicas?
3. Apply knob 2 (lower `SSE_MAX_CONNS`) first; scale acp (knob 3) if RSS stays high
   after the cap drops.

### Alert: broadcast frozen / publish failures

Since the 2026-07-17 api-publisher split there is no outbox and no Redis
counter: Postgres SUM(user_clicks) is the only counter truth and a
single-replica publisher Deployment (`the-button-publisher`) polls it every
second, publishing frames to RabbitMQ for acp's SSE hub. **The counter
cannot drift by construction** — there is nothing to heal and no divergence
to watch.

**ButtonTickFrozen / ButtonTickFrozenCritical** — the publisher has not
completed a successful poll in 30s+ (or its metric is absent entirely: pod
deleted/unschedulable). Effect: SSE viewers see a frozen live counter (their
connection stays open through acp, so the web client's poll fallback does
NOT kick in); page loads / GetCounter stay correct via the api's own cache.
Diagnose:

    kubectl --context algovn-remote -n the-button get pods -l app=the-button-publisher
    kubectl --context algovn-remote -n the-button logs deploy/the-button-publisher --tail=50

- Pod crash/restart: k8s self-heals in seconds; node loss: reschedule can
  take ~5min — accepted single-replica trade.
- Pod healthy but polls failing: look for "counter poll failed" → Postgres
  problem; check the postgres namespace.

**ButtonPublishFailures** — polls healthy, AMQP publishes failing: RabbitMQ
problem (see ButtonRabbitMQDown). Frames stall; counter accounting is
unaffected.

### Alert: service down
- `ButtonServiceDown` — `up{namespace="the-button"}` has no target scraping as up for
  30s. This namespace holds both the api (`the-button-service`) replicas and the
  `the-button-publisher` pod, so it only fires on a full namespace outage: clicking
  (`SubmitClicks`) and the counter are both dead.
- A publisher-only death (api still up and scraping fine) does NOT trip this alert —
  that gap is covered by `ButtonTickFrozen` / `ButtonTickFrozenCritical` instead (see
  previous section). If the counter looks frozen but this alert is silent, check that
  alert rather than trusting this one's absence.

First three checks:
1. `kubectl --context algovn-remote -n the-button get pods` — which pods are down:
   api (`the-button-service`) replicas, `the-button-publisher`, or both?
2. `curl -s https://api.algovn.com/the-button/algovn.button.v1.ButtonService/GetCounter -d '{}'`
   — does it respond at all (gRPC reachable through the gateway)?
3. Postgres reachability from the affected pod(s) — a downed Postgres can starve
   every replica at once even though each still scrapes as up.

### Alert: PG commit rate
`ButtonPGCommitRateNearCeiling` — `the_button` commit rate > 700/s for 5m, against the
750 batch-txn/s engineered ceiling. Measured in-cluster (same node as `pg-1`, real
batch shape, real contention): 981 txn/s achieved, p50 2.27ms / p95 3.46ms / p99
5.34ms — ~30% margin above 750. `pg_test_fsync` measured `fdatasync` at ~550-570
ops/sec serialized; group commit is why the transaction-level ceiling sits well above
that single-writer number, but it's also why sustained load near the ceiling is worth
watching for latency creep, not just raw rate.

First three checks:
1. Is this organic load (real click volume) or a client bug (retry storm, no
   backoff)?
2. `kubectl --context algovn-remote -n postgres exec pg-1 -c postgres -- psql -U postgres -c "SELECT count(*) FROM pg_stat_activity WHERE datname='the_button'"` —
   connection count vs pool size (`pgxpool.MaxConns=10` per replica).
3. Apply knob 1 (raise `pow:min_interval`/`pow:L`) to throttle at the source before
   Postgres saturates.

### Alert: PV usage
`ButtonPVUsageWarning` (>70%, 15m, warning) / `ButtonPVUsageCritical` (>85%, 5m,
critical) on the `postgres`/`redis` PVCs. **local-path cannot expand** (`docs/runbooks/postgres.md`)
— the real limit is w1's shared disk. There is no in-place fix; plan a manual
dump/restore to a larger volume before critical fires, not after.

## Secret rotation

- **PoW secret** (`POW_SECRET`, ns `the-button`, ExternalSecret `pow-secret`,
  bao KV path `secret/algovn/the-button/pow-secret` — see `docs/runbooks/secrets.md`): rotating
  it invalidates every in-flight challenge issued under the old key immediately.
  Set the new value as `POW_SECRET` and the OLD value as `POW_SECRET_PREV` in the same
  deploy — the service verifies against both keys for the rotation window (see
  `internal/config/config.go`), so challenges issued just before the rotation still
  verify. Drop `POW_SECRET_PREV` once you're confident nothing old is still in flight
  (batches solve in ~1-2s, so a few minutes is generous).
- **Redis / Postgres password rotation** (`redis-creds`/`pg-the-button`, both
  URI-shaped secrets): percent-encode the password before embedding it in the URI —
  base64 passwords contain `/` and `+` which break URI parsing raw. See
  `docs/runbooks/postgres.md` (Add an app database, step 2) for the exact
  `python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))'`
  one-liner and why the two bao copies of a rotated password are deliberately
  different encodings, not copies of each other. Write the new value to bao and let
  the ExternalSecret sync it (procedure: `docs/runbooks/secrets.md`). Syncing the
  secret does not restart pods:
  `kubectl --context algovn-remote -n the-button rollout restart deploy/the-button-service`.

## Known limits — stated honestly

- **Single-node reality: node loss takes the whole product (and login) down, not
  just a pod.** The api (`the-button-service`) replicas, `the-button-publisher`, AND
  the Postgres primary (`pg-1`) all run on `algovn-w1` — the cluster's only
  schedulable worker (the control-plane VM `algovn` doesn't schedule these
  workloads). A pod crash/restart self-heals in seconds (k8s reschedules on the same
  node); losing `algovn-w1` itself is a different story — it takes out
  the-button-service, the-button-publisher, and Postgres (and therefore Zitadel/login,
  which shares the CNPG cluster) simultaneously, with no automatic failover to
  another node because there isn't one yet. The topologySpreadConstraints added to
  `apps/the-button/deployment.yaml` is a preference that only takes effect once a
  second amd64 worker joins — it cannot help `the-button-publisher` regardless,
  since that Deployment is single-replica by design.
- **10,000 concurrent users is the target. It has never been reached. 5,000 is the
  only number proven to hold.** Three ramps (2026-07-14) tell a consistent story:
  5,000 concurrent SSE connections hold cleanly every time (0 failures, 0 5xx, flat
  frame-gaps). Above that, a hard **HTTP 503 wall** appears somewhere between ~5.5k
  and ~8.2k, varying run to run.
- **The wall is at the Cloudflare edge, and we cannot scale past it.** The original
  512Mi cloudflared OOM was real and is fixed (now 6×768Mi; peak observed 251-339Mi,
  0 restarts). But memory was never the ceiling: after the fix the ramp still hit 503s
  with cloudflared at 33% of its limit, acp at 110Mi of 1Gi, Kong idle, and **429=0**.
  Doubling the tunnel's registered edge QUIC connections (3→6 replicas, 12→24 conns)
  **did not raise the ceiling — the measured number went 8,235 → 5,536, and 3 of the 6
  pods never received a single stream.** Scaling cloudflared does not buy SSE capacity.
- **⚠️ The measured number is a FLOOR, not a proven ceiling.** Every test to date ran
  from a **single source IP**, which cannot distinguish a global tunnel ceiling from a
  per-source-IP edge cap. If it is per-IP (the best-fitting explanation), real users on
  thousands of distinct IPs would never collectively hit it and true capacity is likely
  much higher — but that is **untested**. Do not quote 5.5k/8.2k as the system's
  capacity; quote 5,000 as proven and say the rest is unknown. Full evidence:
  `iac/docs/load-results-the-button.md` ("Re-test 2: tunnel stream capacity").
- **⚠️ At tunnel saturation the WHOLE API host degrades, not just SSE.**
  `api.algovn.com/healthz` returned 503 during the saturation window even though it has
  nothing to do with SSE. A large enough SSE crowd 503s the click path and health checks
  too. The static apex / `/ui-showcase` / `/the-button/` stay 200 (Cloudflare-served, they
  never touch the tunnel). If `healthz` is 503ing, check `sum(acp_sse_clients)` before
  assuming acp is broken — it is probably the tunnel, and the fix is knob 2 (lower
  `SSE_MAX_CONNS`), not scaling.
- **The authenticated click-soak (real gRPC `SubmitClicks`, genuine PoW, forged
  bearers) was not run** — deferred pending a credential-handling decision, per
  `iac/docs/load-results-the-button.md`. The write-path evidence backing the 750
  txn/s ceiling is a direct in-cluster soak against Postgres (981 txn/s achieved,
  fail=0, real batch shape/contention) plus the service's own integration tests — not
  an end-to-end load test through the gateway and PoW gate.
- **Rollout behavior (measured):** restarting `api-control-plane` drops SSE
  connections; clients reconnect with jittered backoff (~2,000 connections, single-IP
  test methodology: ~127s to full recovery, inflated by shared-IP rate limiting).
  Restarting `the-button-service` does **not** drop SSE (0 disruption observed) — SSE
  lives entirely in acp+cloudflared, and each api replica polls Postgres
  independently for its own `GetCounter` cache, so there's no leadership to fail
  over. Restarting/losing `the-button-publisher` does briefly freeze the live counter
  for SSE viewers until the replacement pod's next successful poll — see
  `ButtonTickFrozen`.

## 2026-07-17 outbox removal — one-time cleanup (done during rollout)

After the api/publisher split rolled out, the orphaned outbox table and
Redis counter key were removed manually (the Go schema deliberately never
DROPs — old pods still wrote to the table during the rolling update):

    kubectl --context algovn-remote -n postgres exec -it <cnpg-primary-pod> -- \
      psql -U postgres -d the_button -c 'DROP TABLE IF EXISTS counter_outbox;'
    kubectl --context algovn-remote -n redis exec -it <redis-pod> -- \
      redis-cli -a "$REDIS_PASSWORD" DEL counter:global

`applied:*` marker keys expired on their own (1h TTL).
