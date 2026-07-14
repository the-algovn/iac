# the-button — load & calibration results

This doc is the tracked home for the-button's pre-launch load evidence (the
service repo's own `docs/superpowers/` is gitignored there). Task 20 creates
the `## Calibration` section below. Task 21 appends its own `## Load test
results (k6)` section underneath — never overwrite this one.

## Calibration

Date: 2026-07-14. Goal: put real numbers behind the two figures the whole
capacity model rests on — the 750 batch-txn/s Postgres ceiling and the
`POW_W0` difficulty constant — before the k6 load test (T21) and launch (T22).

### 1. `pg_test_fsync` (w1, real data dir, in-pod)

Ran directly against the CNPG pod's data dir (`pg-1`, node `algovn-w1`, the
same node the-button-service runs on):

```
kubectl --context algovn-remote -n postgres exec pg-1 -c postgres -- \
  pg_test_fsync -f /var/lib/postgresql/data/pgdata/pg_test_fsync.tmp -s 5
```

```
Compare file sync methods using one 8kB write:
        open_datasync                       214.716 ops/sec    4657 usecs/op
        fdatasync                           548.172 ops/sec    1824 usecs/op
        fsync                               160.824 ops/sec    6218 usecs/op
        open_sync                           161.383 ops/sec    6196 usecs/op

Compare file sync methods using two 8kB writes:
        open_datasync                       117.118 ops/sec    8538 usecs/op
        fdatasync                           570.825 ops/sec    1752 usecs/op
        fsync                               161.392 ops/sec    6196 usecs/op
        open_sync                            80.389 ops/sec   12439 usecs/op

Non-sync'ed 8kB writes:
        write                           3247872.414 ops/sec       0 usecs/op
```

Tmp file cleaned up by `pg_test_fsync` itself on exit (verified — no leftover).

**Read plainly**: `fdatasync` (Linux's default `wal_sync_method`) does ~550-570
serialized ops/sec, i.e. ~1.75-1.8ms per synchronous 8kB write — a good deal
slower than the brief's "representative NVMe" expectation of thousands of
ops/sec (<0.5ms/op). This node's storage (local-path PV, consumer-grade disk,
no documented power-loss-protected NVMe) is not top-tier for *serialized,
single-writer* fsync latency. Taken alone this would undercut the "a couple of
fsyncs stays well under 3ms" reasoning in spec §12.

It does **not**, however, directly cap transaction throughput: PostgreSQL
group-commits — concurrently-committing backends share one WAL flush, so the
*effective* fsyncs/sec at the transaction layer under concurrency is much
higher than this single-writer benchmark's number. Section 2 measures that
directly, and it comfortably clears the serialized-fsync figure — see below
for why the two aren't in conflict.

### 2. 1k-txn/s soak (scratch DB `the_button_soak`, real batch shape)

Bench source: `the-button-service/load/soak/main.go` (RED verified first — ran
against a nonexistent DB, got a loud connection failure, exit 1, proving the
harness truly connects rather than silently no-opping).

**Run A — from a laptop, over the documented LAN endpoint (`192.168.102.201`,
postgres.md's svclb path) — methodology caveat.** This matches the brief's
literal instructions, but this operator's laptop reaches that LAN over Wi-Fi
with real, highly variable RTT (`ping` to `.201`: avg 25.3ms, **stddev
29.2ms**, max 78.8ms — not sub-ms same-subnet behavior). Result:

```
target_rate=1000 duration=1m0s ok=15768 fail=0 achieved_rate=263/s
commit_latency p50=33.712583ms p95=119.016042ms p99=127.2105ms max=879.359375ms
```

This number is **not a Postgres capacity measurement** — it's dominated by
client-side network jitter. Each `oneTxn` does 4 pgx protocol round trips
(Begin/Query/Exec/Commit); at ~9-25ms/RTT that alone explains the ~34ms p50,
and with `pgxpool.MaxConns=10` (matching the real per-replica pool), Little's
Law puts the throughput ceiling at ~10 conns / 0.038s ≈ 263/s — matching the
observed achieved_rate almost exactly. That's the signature of a client-pool/
RTT bottleneck, not a server-saturation one (contrast with §1's in-pod fsync
number, ~1.8ms — nowhere near 33ms).

**Run B — in-cluster, same node as `pg-1` (the design's actual assumption)
— the authoritative measurement.** Cross-compiled the soak binary for
linux/amd64, ran it from a scratch debug pod pinned to `algovn-w1` via
`nodeSelector`, against `pg-rw.postgres.svc.cluster.local:5432` — i.e. the
same node/network path the-button-service itself uses in production:

```
target_rate=1000 duration=1m0s ok=58877 fail=0 achieved_rate=981/s
commit_latency p50=2.268161ms p95=3.462124ms p99=5.340885ms max=15.634252ms
```

**achieved_rate ≈ 981/s, fail=0, p50=2.27ms, p95=3.46ms, p99=5.34ms** — this
lines up with spec §12's ~3ms/txn model (p50/p95 both sit right around the
3ms mark) and comfortably clears the 750 batch-txn/s engineered ceiling with
margin, at the real transaction shape (2-table write + `ON CONFLICT` upsert +
achievement insert) and real contention (5,000 cycled `user_sub` values).

This also resolves the apparent §1 vs §2 tension: with `MaxConns=10` and many
backends committing close together, PostgreSQL's group commit lets several
commits share one WAL flush — so the transaction-level ceiling (~980/s here)
is well above the serialized single-writer fsync rate (~550-570/s from §1).
The fsync number is real and worth keeping an eye on (see recommendation
below), but it is not, by itself, the transaction throughput ceiling.

**Supplementary probe (informational, not authoritative)**: pushed the target
to 2000/s for 30s from the same in-cluster pod. Achieved only 1328/s, but
**commit latency stayed flat** (p50=2.23ms, p95=3.44ms, p99=5.45ms — same as
the 1000/s run) — i.e. no sign of server-side saturation; the shortfall looks
like the harness's own rate-pacing ticker (Go's `time.Ticker` at a 500µs
period is close to typical scheduler/timer-resolution limits) rather than a
Postgres ceiling. Left unresolved — a good candidate for T21's k6 ramp, which
paces load independently of this harness.

**Verdict on the capacity model**: the measured ceiling is **not** materially
below the assumed 750 batch-txn/s — real evidence (in-cluster, same-node,
real txn shape) supports sustaining **at least ~980/s** at low, stable
latency. Recommend **keeping the existing 750/s engineered ceiling and T22
alert thresholds as-is** (they now have a demonstrated ~30% margin rather
than being a pure derivation from an assumed 3ms figure). Recommend also
alerting on **PG commit p95 trending toward ~5-10ms** as an early warning,
since §1 shows storage fsync latency has less headroom than hoped and is
worth watching under real load (T21/T22).

Cleanup performed: scratch DB `the_button_soak` dropped
(`DROP DATABASE the_button_soak;`), debug pod `soak-runner` deleted. The live
`the_button` DB was never touched.

### 3. Solver H/s → `POW_W0` calibration

**Desktop baseline (measured, real)**: imported the SPA's actual solver code
(`web/apps/the-button/src/worker/solver.ts`'s exported `bench()` — the same
hash-wasm SHA-256 loop the Web Worker runs) under Node 26 on this machine
(Apple M4 Pro, arm64), via a driver script that polyfills `globalThis.self`
so the worker's module-load side effect doesn't throw, then dynamic-imports
the file directly (no source changes). Three 4-second runs:

```
run 1: 1,936,988 H/s
run 2: 1,875,206 H/s
run 3: 1,815,328 H/s
average: 1,875,841 H/s
```

**Mid-phone estimate (derived, not measured)**: applying a divisor to the
desktop number. Grounded via public Geekbench 6 single-core scores rather
than a bare guess: M4 Pro ≈3,860, a current (2026) mid-range Android
chipset (Snapdragon 6 Gen 5) ≈1,090 → **~3.5x** raw single-core compute gap.
On top of that, real mobile browsers add overhead a Node benchmark doesn't
capture — thermal throttling under several seconds of sustained hashing, and
Web Worker threads sometimes scheduled on efficiency ("little") cores rather
than the fastest core Geekbench measures — estimated conservatively at
another **~2.2x**. Combined: **~8x**, which we also deliberately round to the
upper-middle of the stated 3-10x range rather than the low end, because the
two failure modes are asymmetric: underestimating phone speed (picking a
lower `W0`) at worst makes a batch resolve a bit faster than the 1.0s target
— mildly less "work," never dangerous. Overestimating phone speed (picking a
higher `W0`) risks the actual failure mode this task exists to avoid: a
multi-second stall.

```
H_s_midphone_est = 1,875,841 / 8 ≈ 234,480 H/s   (≈2.3×10^5 H/s — ESTIMATE)
```

**Decision rule** (spec §5, task brief): expected hashes for a batch =
`W0 × n × L`; pin the design point `n=100, L=1`, target 1.0s:

```
W0_ideal = H_s_midphone_est × 1.0 / 100 ≈ 2,345
```

Nearest power of two: **2048** (2^11). Sanity check at `n=100, L=1`:

```
solve_time(W0=2048) = 2048 × 100 × 1 / 234,480 ≈ 0.87s   — inside [0.5s, 1.5s] ✓
```

**The currently-deployed default, 16384, checked against this same estimate**:

```
solve_time(W0=16384) = 16384 × 100 × 1 / 234,480 ≈ 7.0s   — far OUTSIDE the band
```

Seven seconds for a routine ~100-click batch reads as a stall, not "fun."
**Decision: change `POW_W0` from 16384 to 2048.**

**Uncertainty, stated plainly**: the 3-10x phone-slowdown range spans a wide
enough band that no single power-of-two value keeps solve time in
`[0.5s, 1.5s]` across the *entire* range simultaneously (at n=100: divisor=3
→ H≈625k → needs W0≥3126; divisor=10 → H≈188k → needs W0≤2814 — those two
constraints conflict). 2048 is this task's best point estimate, deliberately
biased toward the safe failure mode (a quick solve, not a stall) — it is not
a substitute for a real device reading.

**Get the real number**: on the actual phone, open
`https://algovn.com/the-button/?bench` and read the `[bench] N H/s —
calibration input for POW_W0` line from the browser console (~4s after load).
If that real number implies 2048 lands outside `[0.5s, 1.5s]` at `n=100,L=1`,
recompute `W0_ideal = H_real × 1.0 / 100`, round to the nearest power of two,
and re-patch `iac/apps/the-button/deployment.yaml`'s `POW_W0` env — it's a
one-line env change, safe to iterate on.

### 4. `max_batch` (10,000) worst case — linear cost, stated explicitly

Solve cost is **linear** in batch size (`W0 × n × L`), so the protocol's
outer bound (`max_batch = 10,000`, independent of the SPA's typical n≈100)
is far more expensive than the typical case. At the chosen **W0=2048**:

| L | hashes (n=10,000) | mid-phone est. | desktop measured |
|---|---|---|---|
| 1 (normal load) | 20,480,000 | ≈87.3s (~1.5 min) | ≈10.9s |
| 16 (max controller difficulty) | 327,680,000 | ≈1,397s (~23.3 min) | ≈174.7s (~2.9 min) |

**This is absurd** — even at L=1, a minute and a half of continuous hashing
for a single batch is a stall by the product's own "fun, not stall" bar; at
L=16 it's nearly 25 minutes and completely unusable. (For reference, the old
default W0=16384 was worse still: ≈698.7s at L=1, ≈11,180s / ~3.1h at L=16 —
lowering `W0` shrinks this tail but does not fix it; the tail is a batch-size
problem, not a difficulty-constant problem.)

**Recommended mitigation (not implemented — out of this task's file scope,
lives in the `web` repo)**: `web/apps/the-button/src/lib/batcher.ts` already
flushes near-immediately (`schedule()` fires a zero-delay timer as soon as
any click is pending and nothing is in flight), which keeps *typical* batches
small under normal mashing. But `flush()`'s `count = Math.min(this.pending,
active.maxBatch ?? DEFAULT_MAX_BATCH)` has no independent client-side ceiling
below the protocol's 10,000 — the file's own `DEFAULT_FLUSH_AT = 300`
constant is defined but, per its comment, no longer gates flush size or
timing. Recommend clamping `count` to a small SPA-side ceiling (e.g. folding
`this.flushAt` back into that `Math.min(...)`) so pending-click accumulation
from a long solve, an offline queue, or deliberate mashing can never trigger
a near-`max_batch` solve. Flagging for whoever next touches the SPA /
for T22's launch checklist.

### Summary

| Item | Value | Source |
|---|---|---|
| `fdatasync` (serialized, single-writer) | ~548-570 ops/sec (~1.75-1.8ms/op) | measured, in-pod `pg_test_fsync` |
| Soak achieved rate (in-cluster, same-node, target 1000/s) | 981/s, fail=0 | measured |
| Commit latency p50/p95/p99 (in-cluster) | 2.27ms / 3.46ms / 5.34ms | measured |
| Safe engineered PG ceiling | 750 batch-txn/s stands, ~30% measured margin | derived from above |
| Desktop solver H/s (Node, M4 Pro) | 1,875,841 H/s avg | measured |
| Mid-phone solver H/s | ≈234,480 H/s | **estimate** (8x divisor, see §3) |
| `POW_W0` | 2048 (was 16384) | decision, patched live |
| max_batch=10,000 worst case @ W0=2048, L=16 | ≈23.3 min (mid-phone est.) | derived — flagged as absurd, mitigation recommended |

## Load test results (k6/SSE)

Date: 2026-07-14. Scope: the two anonymous, no-credential scenarios from T21 —
the SSE capacity ramp and the rollout drill. The authenticated click-soak
(gRPC, forged bearers, genuine PoW) is **deferred pending a user decision on
credential handling** and was not attempted; no secret material was touched.

### Tooling decision

Stock k6 cannot observe per-frame SSE timing (`http.get` blocks until the
response completes, which an SSE stream never does — you can hold the socket
but not see individual frames). Rather than build the `xk6-sse` extension, we
used a small dependency-free Go client
(`the-button-service/load/sseclient/main.go`, stdlib only) with two modes:

- `-mode=ramp`: opens connections in stages at a paced rate, holds each stage,
  and prints a per-stage summary (open count, frame-gap percentiles, connect
  failures) with a coded abort rule (5xx seen, connect-failure rate > 2%,
  frame-gap p95 over threshold, or open count short of target by >2%).
- `-mode=hold`: opens N connections and holds them, auto-reconnecting on drop
  with the SPA's actual full-jitter exponential backoff (mirrors
  `web/apps/the-button/src/lib/liveCounter.ts`: cap starts at 5s, doubles per
  consecutive failure, ceilinged at 60s; resets to 5s on every successful
  open) — used for the rollout drill.

Connect pacing was fixed at 12-15 new connections/sec throughout, safely
under Kong's `rl-events` plugin limits confirmed in
`iac/apps/api-control-plane/rl-events-plugin.yaml` (`second: 50, minute:
1000, limit_by: ip`) — 12/s sustained is 720/min, comfortably under both the
burst and per-minute caps. All runs originated from a single LAN machine/IP;
**an external, multi-IP-origin repeat was not performed in this dispatch**
(see Unverified, below) — this matters most for the reconnect-storm numbers
in the rollout drill, which are inflated by 2000 simulated clients sharing
one source IP.

**Real-tick caveat (important):** the `the-button.counter` channel was idle
throughout testing — no organic click traffic (`GetCounter` returned an
empty/zero total before, during, and after the runs). The server therefore
never emitted a real counter-changing `data:` frame; the only frames observed
were the server's periodic `: ping` keep-alive comment, confirmed by manual
`curl` observation before the load test to arrive roughly every 20-25s per
connection. We used this heartbeat's inter-arrival gap as a fan-out-health
proxy metric (labelled "frame-gap" below) instead of the spec's literal 1s
tick latency — this is the honest substitute available without the
authenticated click path, but it means we did **not** verify the literal
"does the 1s tick reach everyone" claim, only "does *a* periodic server frame
keep reaching every held-open connection." The first ramp attempt used an
abort threshold (`p95<3000ms`) calibrated for a real 1s tick, which
false-aborted the ramp at the very first stage (heartbeat p95 ≈25,076ms is
merely the heartbeat's own 20-25s period, not distress) — corrected to a
45s threshold (~2 heartbeat cycles) for all runs reported below.

### Scenario A: SSE ramp

| Stage target | Reached | Frame-gap p50/p95/max (ms) | Connect fails | 5xx | acp RSS (both pods) |
|---|---|---|---|---|---|
| 500 | 500/500 | 25000 / 25076 / 25657 | 0 | 0 | ~19-22Mi |
| 2000 | 2000/2000 | 25000 / 25069 / 25423 | 0 | 0 | ~46-47Mi |
| 5000 | 5000/5000 | 25000 / 25068 / 25601 | 0 | 0 | ~92-94Mi |
| 10000 | **broke at ~7,300-7,500** | n/a — mass disconnect | 29 (502) | 29 (502) | ~111-125Mi at break |

**Where it broke, precisely:** at 2026-07-14T15:45:57Z, with the ramp client
holding ~7,382 open connections (paced at 12/s toward the 10,000 target),
`kubectl describe pod` on `cloudflared-76554948dd-8dlrj` shows:

```
Last State:  Terminated
  Reason:    OOMKilled
  Exit Code: 137
Limits:
  memory:    512Mi
```

That single cloudflared pod (of 2 replicas, `128Mi request / 512Mi limit`
each per `iac/platform/cloudflared/deployment.yaml`) was OOM-killed. The
client-observed open count crashed from 7,382 to 85 within seconds (a mass
drop of essentially every connection that pod was proxying), plus 29
in-flight new-connect attempts got `502 Bad Gateway` during the ~1s pod
restart window. The *other* cloudflared replica (`z5mm8`) never restarted, so
the tunnel wasn't fully down — but the ramp did not stabilize afterward
(`open` hovered around 1,200-1,900 while connect attempts kept climbing
toward 10,000, i.e. connections kept dying roughly as fast as new ones
landed), so per the brief's stop rule we manually killed the ramp client
rather than continue grinding against an already-broken component.

**What did NOT break:** `api-control-plane` (0 restarts throughout both
pods; RSS peaked at only ~125Mi of its 1Gi limit at the moment of the
crash — nowhere near saturated) and `kong-gateway` (0 restarts) were
healthy the entire time. **The binding capacity constraint today is
cloudflared's 512Mi memory limit, not Kong's 32768 worker-connection budget
and not acp's configured `SSE_MAX_CONNS=15000` cap** — the real ceiling
(~7,300-7,500) sits at under half of acp's own advertised design cap.
Recommend raising cloudflared's memory limit and/or replica count before
trusting the 15,000 SSE_MAX_CONNS figure as a real, safe operating ceiling.

Site health during the whole ramp (apex, `/ui-showcase`, `/the-button/`,
anonymous `GetCounter`, polled every ~15-17s): 200 the entire time, including
through the crash window, except one incidental `getcounter` probe failure
recorded at 15:45:51Z (six seconds before the OOM) — inconclusive on its own,
flagged rather than asserted as a leading indicator. After the ramp client
was stopped, the site returned to fully idle/healthy within the next poll.

### Scenario B: rollout drill

Both runs held 2,000 SSE connections (paced at 15/s), well under the ~7,300
ceiling found in Scenario A, so cloudflared was never at risk here.

**Run 1 — `api-control-plane` restart.** First attempt used a flat 0-5s
reconnect jitter (no backoff) and produced a self-sustaining retry storm: all
2,000 simulated clients shared one test IP, so their simultaneous reconnects
blew through Kong's per-IP `50/s, 1000/min` limit every retry cycle, in an
unbroken loop that never recovered (open plateaued at ~883, with a handful
of genuine 5xx appearing from the sheer request volume). This was a **test
tool artifact**, not a real system fault — fixed by implementing the SPA's
actual full-jitter exponential backoff (see Tooling decision) and re-run:

- Restart triggered 2026-07-14T16:00:51Z; `kubectl rollout status` reported
  success at 16:01:14Z (**~23s** rollout).
- Drop: essentially all 2,000 connections dropped (2,256 total disconnect
  events, including some early reconnects that dropped again during the
  storm).
- Reconnect storm: the initial wave still hit Kong's per-IP limit (final
  429 count 6,043) — again a single-test-IP artifact; 2,000 *real* users on
  2,000 real IPs would not compete for one IP's rate-limit budget. With
  exponential backoff, new-attempt volume per 10s window shrank cleanly
  (1878→1783→747→627→457→454→325→219→173→140→112→73→54→31→7), confirming
  the backoff de-synchronized the storm exactly as designed.
- **Full recovery to 2,000/2,000 by 16:03:58Z — ~127s from restart trigger
  to every connection back.** A small number of genuine 5xx appeared during
  the storm (11 total, all within a 20s window, ~0.1% of ~10,300 connection
  attempts) and stopped growing once backoff spread the load out.
- `api-control-plane`: 0 unplanned restarts (only the deliberate rollout
  pod replacement). Kong, cloudflared, `the-button-service`: unaffected.
- Site health (apex/showcase/the-button/GetCounter): **200 throughout the
  entire drill**, despite the SSE reconnect storm.
- **Caveat:** the ~127s figure and the 429/5xx counts are inflated by the
  single-IP methodology described above. Real distributed users would likely
  recover in well under 30s (bounded mostly by the SPA's first-attempt 0-5s
  jitter plus the ~23s rollout itself) — unverified without a genuinely
  multi-IP-origin repeat.

**Run 2 — `the-button-service` restart.** Restart triggered 16:08:24Z,
rollout success reported at 16:08:48Z (**~24s**).

- **Zero SSE impact**: 0 disconnects, 0 reconnects, open held at 2,000/2,000
  through the entire restart — confirming the-button-service sits outside
  the SSE/gateway path, exactly as designed.
- Tick-leader failover, from pod logs: old pod logged `"tick leadership
  released"` at `16:08:48.5737251Z`; new pod logged `"tick leadership
  acquired"` at `16:08:48.585531356Z` — **~12ms** failover. (Could not
  confirm actual counter-tick resumption with real data, since the channel
  was idle throughout — this log-based leadership handoff timing is the
  available direct evidence and is well inside the "a few seconds"
  expectation from `candidateInterval=2s` / `leaderCallTimeout=3s`.)
- acp/Kong/cloudflared: untouched, 0 restarts. Site health: 200 throughout.

### Results table

| Scenario | Origin | Target | Key result |
|---|---|---|---|
| sse-ramp | LAN (1 IP) | 500 → 10k | held cleanly to 5,000 (0 failures); broke at ~7,300-7,500 (cloudflared OOMKilled, 512Mi limit) — acp/Kong never distressed |
| rollout-drill | LAN (1 IP) | 2k SSE + acp restart | ~127s to full 2,000/2,000 recovery (single-IP rate-limit-inflated); 11 real 5xx (~0.1%); site stayed 200 throughout |
| rollout-drill | LAN (1 IP) | 2k SSE + the-button-service restart | 0 SSE disruption; tick-leader failover ~12ms; site stayed 200 throughout |
| click-soak | — | — | **deferred** pending credential decision; not attempted (no secrets touched) |

click-soak is deferred by explicit instruction for this dispatch (needs
`POW_SECRET` and forged in-cluster bearers) — not run, not to be confused
with the T21 brief's original LAN/service-direct design rationale.

### Unverified / left for a follow-up dispatch

- **Authenticated click-soak** (gRPC direct to `the-button-service`,
  forged bearers, genuine PoW) — deferred pending a user decision on
  credential handling for this dispatch; the 750 batch-txn/s PG ceiling
  from the Calibration section above remains unexercised under real k6 load.
- **External-origin repeat** (sse-ramp and rollout-drill from outside the
  LAN, through the full Cloudflare edge, from a genuinely different IP) —
  not run. This would give a real, non-single-IP reconnect-storm number for
  the rollout drill, and confirm whether the ~7,300-7,500 SSE ceiling holds
  (or differs) when connections don't all originate from one LAN machine.
- **Real 1s tick-latency** — not measurable without organic click traffic;
  the heartbeat-based proxy metric used here answers a related but weaker
  question (fan-out keeps reaching everyone) than the spec's literal claim.
- **Sub-second user impact during the cloudflared OOM** — health polling
  ran every ~15-17s, too coarse to characterize exactly how many concurrently
  connected real users would see a dropped stream in that specific ~1s
  restart window (only that health recovered by the next poll).
