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
   ⚠️ **Scaling cloudflared does NOT raise the SSE ceiling** (measured — see Known
   limits: 3→6 replicas left 3 pods completely idle and the wall did not move). The 503
   wall is at the Cloudflare edge, not in a pod we can scale. Scale cloudflared only for
   redundancy or a genuine memory alert; to relieve an SSE ceiling use knob 2 (lower
   `SSE_MAX_CONNS`) instead. Restarting/scaling `the-button-service` does not drop
   SSE (that path is entirely acp+cloudflared); tick leadership fails over to another
   replica in ~12ms (measured).

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
  Restarting `the-button-service` does **not** drop SSE (0 disruption observed); tick
  leadership fails over to the new leader in ~12ms.
