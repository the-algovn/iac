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
margin, at a representative transaction shape (2-table write + `ON CONFLICT`
upsert + achievement insert) and real contention (5,000 cycled `user_sub`
values).

**Correction (launch-hardening review): this bench's transaction is LIGHTER
than production's real batch shape — the 750/s ceiling below is EXTRAPOLATED
for production, not directly measured.** `oneTxn` (`load/soak/main.go`) commits
2 writes: the `user_clicks` upsert and a `user_achievements` insert. Production's
`clicks.Submit` (`internal/clicks/clicks.go`) commits 3 writes in that same
transaction — the same upsert and achievement insert, **plus a `counter_outbox`
insert** (the transactional-outbox row) — and then, once the Redis apply lands,
issues a **separate post-commit `DELETE FROM counter_outbox`**: a second, distinct
commit per batch. So this bench measured roughly 1 commit/batch of a 2-write
transaction, while production is effectively **~2 commits/batch** (one 3-write
commit plus one 1-statement delete commit). 981/s and the latency numbers above
are real and were genuinely measured — just for a lighter shape than what ships.

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
below the assumed 750 batch-txn/s for the *lighter* shape this bench actually
ran — real evidence (in-cluster, same-node) supports sustaining **at least
~980/s** of a 2-write/1-commit transaction, at low, stable latency. That
number does **not** directly carry over to production's heavier shape (see
correction above: effectively ~2 commits/batch there, not 1) — treat the
750/s ceiling as **EXTRAPOLATED** for production, with the same-node fsync
headroom (§1) as the reason to stay cautious rather than assume the ~30%
margin measured here holds unchanged. Recommend **keeping the existing 750/s
engineered ceiling and T22 alert thresholds as-is** for now (nothing here
argues for lowering it), but re-measuring with the real production
transaction shape before leaning on that margin. Recommend also alerting on
**PG commit p95 trending toward ~5-10ms** as an early warning, since §1 shows
storage fsync latency has less headroom than hoped and is worth watching
under real load (T21/T22).

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
| Safe engineered PG ceiling | 750 batch-txn/s stands — **EXTRAPOLATED** for production's ~2-commits/batch shape (the ~30% margin above was measured on a lighter 1-commit/batch bench) | derived from above |
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

**SUPERSEDED by later re-tests below.** Raising the memory limit (512Mi ->
1536Mi) did fix this specific OOM, but raising replica count did not buy
capacity: 3->6 replicas *lowered* the observed ceiling (8,235 -> 5,536) with
half the pods sitting idle (see "Re-test 2: tunnel stream capacity"). The
ceiling is at the Cloudflare edge, not a function of cloudflared's own
replica count or memory. 768Mi (6 replicas) is the settled, evidence-backed
size going forward — see "Configuration left in place, and why" — not a
step toward a still-larger memory/replica configuration.

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

## Re-test after cloudflared sizing fix

Date: 2026-07-14. Purpose: re-run the anonymous SSE ramp after raising
cloudflared's memory limit, to confirm the OOM ceiling is gone and to find
the *next* bottleneck. Same tool and method as the section above
(`the-button-service/load/sseclient/main.go`, `-mode=ramp`, single LAN
source IP, connect pacing 15/s — under Kong's `rl-events` `50/s, 1000/min`
per-IP caps).

### The fix

`platform/cloudflared/deployment.yaml`:

| | before | after |
|---|---|---|
| memory limit | 512Mi | **1536Mi** |
| memory request | 128Mi | 256Mi |
| replicas | 2 | **3** |

### Result: the OOM ceiling is gone; a NEW, different ceiling binds at ~8.2k

Stages 2,000 → 5,000 → 8,000 → 10,000, holding each 60s:

| Stage target | Reached | Frame-gap p50/p95/max (ms) | Connect fails | 5xx | 429 |
|---|---|---|---|---|---|
| 2000 | 2000/2000 | 25000 / 25013 / 25838 | 0 | 0 | 0 |
| 5000 | 5000/5000 | 25000 / 25010 / 25589 | 0 | 0 | 0 |
| 8000 | 8000/8000 | 25000 / 25010 / 25603 | 0 | 0 | 0 |
| 10000 | **8,235 — did not reach 10k** | 25000 / 25034 / 26959 | 1,747 | 1,747 (503) | 0 |

- **Max concurrent SSE held: 8,235** (client-observed); `acp_sse_clients`
  gauge peaked at **8,237**, agreeing.
- **10,000 was NOT reached.** Past ~8.2k, new connections were refused with
  **HTTP 503** — 1,747 of the final stage's 2,000 attempts (87% error rate),
  which tripped the ramp's `5xx > 0` abort rule. The run was then stopped;
  no load was left running.
- **429 = 0 throughout** — Kong's per-IP rate limit was never hit, so this is
  not a connect-pacing artifact.
- Frame-gap p50 ≈ 25,000ms is the server's ~25s SSE keep-alive period (the
  channel was idle again — no organic clicks), used as a fan-out-health proxy,
  not the spec's literal 1s tick. It stayed flat right through saturation.

### The memory fix worked — memory is no longer the constraint

| | old (512Mi limit) | new (1536Mi limit) |
|---|---|---|
| cloudflared peak mem/pod | **OOMKilled at 512Mi** (~7.4k conns) | **339Mi / 285Mi / 22Mi** (22% of limit) |
| cloudflared restarts | 1 (exit 137) | **0** |
| ceiling | ~7,300–7,500 (OOM) | ~8,235 (503, not memory) |

Zero restarts, zero OOMKilled events, `lastState` empty on all three pods.
`api-control-plane` peaked at **145–147Mi of its 1Gi** limit (0 restarts);
Kong at **640Mi of 2Gi** (0 restarts). Neither was distressed.

### Where the 503 comes from (evidenced): upstream of the origin

The refusals **never reached the origin**. During the 300s window covering
the 1,747 failures, `api-control-plane` logged only **19** `/events` requests
— *all 200*. Kong's access log shows no 503s. The failures are HTTP 503
*status codes* (the edge accepted the stream and answered), not dial errors
or timeouts, so this is a server-side refusal at the **Cloudflare edge ↔
cloudflared tunnel layer**, before Kong and acp.

**Per-stream memory, corrected.** ~646Mi of cloudflared RSS held ~8,235
streams ⇒ **~80KB per QUIC stream** — not the ~140KB estimated previously.
The old estimate assumed an even 2-pod split; in reality **load distribution
across replicas is very uneven** (339Mi / 285Mi / **22Mi** — the third pod
was barely used). The old 512Mi OOM is better explained by streams
concentrating on one pod than by a high per-stream cost.

**Hypothesis for the ~8.2k wall (inference, not proven).** Each cloudflared
replica registers 4 QUIC connections to the edge (`connIndex` 0–3). With
effectively **two** pods carrying load, 2 × 4 = 8 edge connections; at a
~1024-concurrent-stream limit per QUIC connection that is **8,192** — within
0.5% of the observed 8,235. This fits the data but was not confirmed against
cloudflared's configured stream limit; it needs verification before being
relied on.

### Collateral finding: at saturation, normal API traffic 503s too

Site health was polled every ~15s throughout. `algovn.com` apex,
`/ui-showcase` and `/the-button/` returned **200 in all 96 polls** (static,
Cloudflare-served). But **`api.algovn.com/healthz` returned 503 in 5 polls**,
all of them inside the saturation window (16:41:55–16:43:56Z, exactly while
`acp_sse_clients` was pinned at 8,236). So once the tunnel's stream capacity
is exhausted, the 503s are **not confined to `/events`** — they hit the whole
`api.algovn.com` hostname, i.e. real API users are affected. This is the most
operationally important result of the re-test.

### Verdict

The sizing fix did what it was meant to do: cloudflared no longer OOMs, and
the ~7,300–7,500 OOM ceiling is gone. But **10,000 concurrent SSE is still
not reachable** — a *different* limit (edge/tunnel concurrent-stream
capacity) binds at **~8,235**, with memory at only 22% of the new limit.
`SSE_MAX_CONNS=15000` remains well above anything demonstrated.

Raising the memory limit further will **not** move this ceiling. If 10k is a
real target, the lever is more edge connections — more cloudflared replicas
(note the third replica was barely used, so edge distribution is uneven and
adding replicas may not scale linearly) and/or cloudflared's per-connection
stream limit. Either way, re-measure; do not assume.

### Unverified / left open

- **Is ~8,235 a global tunnel ceiling or a per-source-IP edge limit?** All
  8k+ connections came from **one source IP**. A per-IP concurrency limit at
  the Cloudflare edge would produce exactly this signature, and a single-IP
  test cannot distinguish the two. **An external, multi-IP-origin run is
  required before treating ~8.2k as the system's true capacity** — the real
  number could be higher.
- **The 8,192-stream hypothesis** above is arithmetic that fits, not a
  confirmed mechanism.
- **Authenticated click-soak** — still not run (needs `POW_SECRET` + forged
  in-cluster bearers); the 750 batch-txn/s PG ceiling remains unexercised
  under real load.
- **Real 1s tick-latency** — still not measurable (channel idle; heartbeat
  gap used as a proxy).

## Re-test 2: tunnel stream capacity

Date: 2026-07-14. Purpose: test the hypothesis that the ~8,235 wall from the
previous section was per-QUIC-connection stream exhaustion, and that adding
cloudflared replicas (each registering 4 QUIC connections to the edge) would
raise it. **The hypothesis was falsified.** The run was stopped early by the
operator because `api.algovn.com/healthz` was 503ing under the load; the data
below is what was measured before the stop, and it is decisive on its own.

### What was changed

`platform/cloudflared/deployment.yaml`:

| | before | after |
|---|---|---|
| replicas | 3 | **6** |
| memory limit | 1536Mi | **768Mi** |
| registered edge QUIC connections | 3 x 4 = 12 | **6 x 4 = 24** |

The 4-connections-per-pod figure is confirmed, not assumed: every pod logs
exactly `Registered tunnel connection connIndex=0..3` at startup. This
cloudflared build (2026.7.1) exposes **no `--ha-connections` flag**, so
replica count is the only lever we have over edge connection count.

The memory limit was *lowered* because the previous re-test proved memory was
never the constraint (peak 339Mi against a 1536Mi limit). 6 x 768Mi is the
same total memory budget as 3 x 1536Mi.

### Result: the ceiling did NOT move up. It moved DOWN.

Stages 5,000 -> 8,000 -> 10,000, 60s holds, connect pacing 15/s, single LAN
source IP:

| Stage target | Reached | Connect fails | 5xx | 429 |
|---|---|---|---|---|
| 5000 | 5000/5000, frame-gap p50/p95 25001/25078ms | 0 | 0 | 0 |
| 8000 | **5,536 — hard wall** | 2,443+ | 2,443+ (503) | 0 |
| 10000 | not attempted (aborted at stage 8000) | — | — | — |

- **Max concurrent SSE held: 5,536** (client-observed). The `acp_sse_clients`
  gauge read ~2,767 per acp pod x 2 pods = **~5,534**, agreeing to within 2.
- **Doubling the tunnel's registered edge connections (12 -> 24) did not raise
  the ceiling — the measured number fell from 8,235 to 5,536.**
- The wall was absolute, not gradual: `open` pinned at *exactly* 5,536 and
  stayed there for 3+ minutes while **every single new connection got a 503**
  (100% failure on ~2,400 attempts, zero recovery). Not a soft degradation.
- **429 = 0** throughout — Kong's per-IP rate limit was never involved.
- 5,000 held perfectly clean, as in every previous run.

### Why more replicas bought nothing: half the pods were never used

Peak cloudflared memory per pod, 6 replicas (memory is a proxy for streams
carried, ~80KB/stream):

| pod | peak | carried load? |
|---|---|---|
| mfb79 | **251Mi** | yes |
| 9lfsn | **137Mi** | yes |
| dm4bj | 61Mi | a little |
| zjvdw | 18Mi | **no — idle baseline** |
| kckzp | 18Mi | **no — idle baseline** |
| 2wrtl | 18Mi | **no — idle baseline** |

**Three of the six pods never received a single stream.** The Cloudflare edge
routed this client's connections onto a subset of the 24 registered
connections and left the rest idle — exactly the same pattern as the 3-replica
run (339Mi / 285Mi / 22Mi: one of three pods barely used). Registering more
edge connections does not make the edge *use* them for a given client.

This also means the replicas **cannot have caused** the drop from 8,235 to
5,536 — the added pods were sitting idle. The two numbers are run-to-run
*variance in the same edge-side wall*, not a capacity regression.

### The mechanism, stated only as far as the evidence supports

What is established:

1. The refusals happen **upstream of our origin**. HTTP 503 status codes (the
   edge answered), no corresponding entries in Kong or api-control-plane
   access logs, and both were idle at the time (acp peak RSS **110Mi of 1Gi**;
   cloudflared peak **251Mi of 768Mi**, 0 restarts, 0 OOMKills). Nothing we
   run was under stress when the wall hit.
2. It is **not** a memory limit (33% utilization at the wall).
3. It is **not** Kong's rate limit (429 = 0) and **not** `SSE_MAX_CONNS=15000`.
4. It is **not** a simple `registered_connections x 1024 streams` cap: doubling
   registered connections did not raise it, and the previous section's neat
   `8 x 1024 = 8,192 ~= 8,235` arithmetic must now be treated as **coincidence**,
   not mechanism. It did not predict this run.
5. The binding constraint is at the **Cloudflare edge**, is **not a function of
   any configuration we control**, and **varies between runs** (8,235 then
   5,536 under identical conditions apart from replica count).

The most plausible remaining explanation — consistent with all of the above but
**not proven** — is a **per-source-IP concurrency cap at the Cloudflare edge**.
It would produce exactly this signature: a hard wall, indifferent to our
replica count, with a value that shifts run to run depending on which edge
colos/servers a given client's connections land on.

### The number is a FLOOR, not a proven ceiling

**A single-source-IP load test cannot distinguish a global tunnel ceiling from
a per-source-IP edge cap.** All 5,536 (and previously 8,235) connections came
from one machine on one IP. If the wall is per-IP, then real users on thousands
of distinct IPs would never collectively hit it, and the system's true capacity
is **unknown and probably substantially higher** than any number in this
document.

So the honest statement of capacity is:

- **Proven to hold, repeatedly and cleanly: 5,000 concurrent SSE connections**
  (zero failures, zero 5xx, flat frame-gaps, every run).
- **From a single source IP, a hard 503 wall appears somewhere between ~5.5k
  and ~8.2k**, varying by run, caused by something at the Cloudflare edge that
  we do not control and cannot raise by scaling.
- **10,000 concurrent has never been reached and is not demonstrated.**
- Whether 10,000 is reachable from many distinct IPs is **untested**. It cannot
  be settled from one machine. A genuinely distributed, multi-IP origin test is
  the *only* way to answer it.

### Operationally critical: at saturation, the whole API host degrades

`api.algovn.com/healthz` — an endpoint with nothing to do with SSE — returned
**503 in 2 of 39 health polls**, both inside the saturation window
(17:08:36Z and 17:09:14Z, while `open` was pinned at 5,536). The apex,
`/ui-showcase` and `/the-button/` stayed **200 in all 39 polls** (they are
static and Cloudflare-served, so they never touch the tunnel).

**Tunnel saturation is not confined to the `/events` path — it takes down every
route on `api.algovn.com`, including health checks and the click path.** A
large enough SSE crowd degrades the API for everyone, including users who are
not watching the counter. This is the single most important operational finding
of the re-test, and it is why the run was stopped. The site recovered to 200
immediately once load stopped, with zero pod restarts anywhere.

### Configuration left in place, and why

Left at **6 replicas x 768Mi**:

- **768Mi is well-evidenced.** Observed peaks: 251Mi (this run), 339Mi (3-replica
  run at a higher connection count). >2x headroom over anything measured, and
  the total budget (6 x 768 = 4608Mi) is unchanged from 3 x 1536Mi.
- **6 replicas is NOT justified as a capacity fix — it demonstrably did not
  raise the single-IP ceiling, and 3 of the 6 pods sat idle.** It is retained
  only because it is nearly free (an idle pod costs ~18Mi) and because *for the
  multi-IP case we cannot test*, more registered edge connections plausibly give
  the edge more paths to spread distinct clients across. That is a hypothesis,
  not a result. It should not be cited as proven headroom.

### Unverified / left open

- **The actual capacity of this system is still unknown**, because every test to
  date has been single-origin. This is now the single biggest gap.
- **The per-IP-edge-cap explanation is inference**, not a confirmed mechanism.
  It fits all five established facts above; it has not been proven.
- **Authenticated click-soak** — still not run.
- **Real 1s tick-latency** — still not measurable (channel idle; heartbeat gap
  used as a proxy).
