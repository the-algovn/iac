# the-button (algovn.com/the-button)

Live global click counter; PoW-gated. Service ns `the-button` (`the-button-service`,
2 replicas, gRPC :9090 + metrics :9091), SPA ns `the-button-web`, routed via
api-control-plane registration `/the-button` and SSE channel `the-button.counter`.
Spec: the-button-service repo `docs/superpowers/specs/2026-07-14-the-button-design.md`.
Load/calibration evidence: `iac/docs/load-results-the-button.md`. Data: Redis ns `redis`
(hot control state — `pow:L`, `pow:min_interval`, `counter:global`), Postgres db
`the_button` in the shared CNPG cluster (durable truth). Alerts: VMRule
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
   ⚠️ The tick leader recomputes both keys every ~1s from an EWMA of accepted-submit
   rate (`internal/ticker/ticker.go`'s `lead()`). A manual `SET` is overwritten within
   one tick UNLESS real load already keeps the controller pinned there itself — treat
   this as a nudge to confirm the controller's own ceiling, not a durable latch. For a
   durable clamp use knobs 2/3 below instead.

2. **Lower the SSE cap (edge relief, immediate, durable).** Fewer held connections
   means less cloudflared memory and less acp memory:
   ```
   kubectl --context algovn-remote -n api-control-plane set env deploy/api-control-plane SSE_MAX_CONNS=8000
   ```
   New connections above the cap get a 503 and the SPA reconnects with its own
   full-jitter exponential backoff (cap starts 5s, doubles per failure, ceilinged at
   60s) — existing connections keep serving. Revert by re-setting to `15000`.

3. **Scale cloudflared / acp / the-button-service (throughput + memory relief).**
   No HPA on any long-lived-connection path — scale by hand:
   ```
   kubectl --context algovn-remote -n cloudflared scale deploy/cloudflared --replicas=4
   kubectl --context algovn-remote -n api-control-plane scale deploy/api-control-plane --replicas=3
   kubectl --context algovn-remote -n the-button scale deploy/the-button-service --replicas=3
   ```
   cloudflared is the proven SSE wall (see Known limits) — scaling it first buys the
   most headroom per replica. Restarting/scaling `the-button-service` does not drop
   SSE (that path is entirely acp+cloudflared); tick leadership fails over to another
   replica in ~12ms (measured).

## What each alert means

### Alert: cloudflared memory & restarts
- `ButtonCloudflaredMemoryHigh` — working set > 75% of the 1536Mi limit for 10m.
- `ButtonCloudflaredOOMRestart` — any cloudflared restart in the last 10m. This is the
  proven SSE capacity wall (2026-07-14 ramp: 512Mi limit OOMKilled a pod at ~7.4k QUIC
  streams cluster-wide, ~140KB/stream); fixed to 3×1536Mi, but the wall is memory, not
  CPU or Kong's connection budget.

First three checks:
1. `kubectl --context algovn-remote -n cloudflared get pods` — how many replicas, any
   `OOMKilled`/restart count.
2. Current SSE connection count: `sum(acp_sse_clients)` (see next alert) — is a real
   ramp in progress, or a leak?
3. Apply knob 2 (lower `SSE_MAX_CONNS`) or knob 3 (scale cloudflared) above; don't wait
   for the second replica to also OOM.

### Alert: acp memory & SSE clients
- `ButtonAcpMemoryHigh` — api-control-plane RSS > 75% of its 1Gi limit for 10m.
- `ButtonSSEClientsNearCap` — `sum(acp_sse_clients) > 12000` (80% of `SSE_MAX_CONNS=15000`)
  for 5m. Measured: RSS peaked ~125Mi of 1Gi at ~7.4k connections in the load test — acp
  was never close to distressed; cloudflared broke first. A memory alert here without a
  matching connection count is more likely a leak or a different workload.

First three checks:
1. `sum(acp_sse_clients)` and `max(process_resident_memory_bytes{namespace="api-control-plane"})`
   via the vmsingle HTTP API (`svc vmsingle-vm:8428`, see `docs/runbooks/postgres.md`
   for the query pattern).
2. `kubectl --context algovn-remote -n api-control-plane get pods` — restarts, per-pod
   RSS split evenly across the 2 replicas?
3. Apply knob 2 (lower `SSE_MAX_CONNS`) first; scale acp (knob 3) if RSS stays high
   after the cap drops.

### Alert: counter divergence & outbox depth
- `ButtonCounterDivergenceNonZero` — `the_button_counter_divergence` (SUM(user_clicks)
  minus Redis `counter:global`) non-zero for 10m straight.
- `ButtonOutboxSweeperStuck` — `the_button_counter_outbox_depth` (rows in
  `counter_outbox`) elevated above 100 for 10m; the sweeper runs every 30s and applies
  up to 500 rows/pass, so a healthy sweeper should never sit above that for long.

**Do NOT hand-edit Redis.** Both metrics are observation-only by design (spec §8) —
nothing in the service auto-corrects them, because a diff between Postgres and Redis
can't tell a lost increment from one merely in flight. The counter's exactly-once
design: every batch commits once in Postgres and writes a `counter_outbox` row in the
same transaction, then a best-effort apply increments Redis; the tick leader's sweeper
re-applies any row whose apply never landed, keyed by an idempotency marker so a
retry can never double-count.

First three checks:
1. Which replica currently holds tick leadership — grep logs for `"tick leadership
   acquired"` (`kubectl --context algovn-remote -n the-button logs -l app=the-button-service --tail=200`).
   ⚠️ Both metrics are per-process gauges refreshed only by the CURRENT leader; a
   just-demoted replica's copy freezes at its last value instead of resetting to zero,
   so confirm the alerting series belongs to the *current* leader before treating it as
   real drift.
2. Postgres and Redis both reachable from that leader (check its recent logs for
   `"divergence metric"` / `"outbox depth metric"` read failures — those short-circuit
   the refresh entirely, which can look identical to real drift).
3. If genuinely non-zero and persistent: check for a stuck sweeper (`"outbox sweep
   failed"` in logs) or a leadership flap (repeated acquire/release) rather than
   attempting any manual fix — there is no supported manual healing path.

### Alert: service down / no leader
- `ButtonServiceDown` — no `the-button-service` replica scraping as up for 30s. The
  counter freezing (no tick, `SubmitClicks` failing) is the single most user-visible
  failure this alert set covers.
- Known gap: this fires only on a full outage (both replicas unreachable). There is no
  dedicated "tick freshness" metric yet — a single replica stuck in a state where it
  holds no lock and never becomes leader, while still scraping as up, would not trip
  this alert. If the counter looks frozen but this alert is silent, check leadership
  directly (see checks below) rather than trusting the alert's absence.

First three checks:
1. `kubectl --context algovn-remote -n the-button get pods` — both replicas present
   and Ready?
2. `curl -s https://api.algovn.com/the-button/algovn.button.v1.ButtonService/GetCounter -d '{}'`
   — does it respond at all (gRPC reachable through the gateway)?
3. Postgres/Redis reachability from the pod (see divergence alert's check 2) — a
   downed dependency can starve every replica of leadership simultaneously.

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

- **PoW secret** (`POW_SECRET`, ns `the-button`, SealedSecret `pow-secret`): rotating
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
  one-liner and why the two sealed copies of a rotated password are deliberately
  different encodings, not copies of each other. Resealing does not restart pods:
  `kubectl --context algovn-remote -n the-button rollout restart deploy/the-button-service`.

## Known limits — stated honestly

- **10,000 concurrent users was the target; the measured ceiling is lower.** The
  2026-07-14 SSE ramp held cleanly to 5,000 connections with zero failures, then broke
  at ~7,300-7,500 when a cloudflared pod (512Mi limit at the time) was OOMKilled.
  **cloudflared memory is the wall**, not Kong (0 restarts throughout) and not acp
  (RSS peaked ~125Mi of 1Gi, `SSE_MAX_CONNS=15000` never approached). cloudflared is
  now sized at 3×1536Mi; a re-run to confirm 10k holds at the new size has not been
  reported back into `iac/docs/load-results-the-button.md` as of this runbook — check
  that file for a "Load test results" addendum before assuming 10k is proven.
- **The authenticated click-soak (real gRPC `SubmitClicks`, genuine PoW, forged
  bearers) was not run** — deferred pending a credential-handling decision, per
  `iac/docs/load-results-the-button.md`. The write-path evidence backing the 750
  txn/s ceiling is a direct in-cluster soak against Postgres (981 txn/s achieved,
  fail=0, real batch shape/contention) plus the service's own integration tests — not
  an end-to-end load test through the gateway and PoW gate.
- **Rollout behavior (measured):** restarting `api-control-plane` drops SSE
  connections; clients reconnect with jittered backoff (~2,000 connections, single-IP
  test methodology: ~127s to full recovery, inflated by shared-IP rate limiting).
  Restarting `the-button-service` does **not** drop SSE (0 disruption observed); tick
  leadership fails over to the new leader in ~12ms.
