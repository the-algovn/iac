---
name: algovn-prod-debug
description: Use when investigating anything that might be wrong in the algovn production cluster - "prod is broken", "why is X failing", a 500 or other error report, a pasted trace ID, a user complaint, or a service behaving oddly. Also use before reaching for `kubectl logs` on any algovn service. Provides the log and trace query path via `iac/scripts/obs`.
---

# Debugging algovn production

Production logs are centralized in Loki. `kubectl logs` shows one pod's slice of
a story that can span several processes — reach for it last, not first, and only
for pod *state* (see "When to leave the logs" below).

Distributed tracing (Tempo, `trace_id`/`span_id` on every request-scoped log line)
is built but **not live yet** — it ships once this branch merges. Until then,
`namespace`/`container`/`pod` and plain-text search are what you have, and that's
normal, not broken.

## The loop

Run everything through `iac/scripts/obs`. It port-forwards to Loki (and Tempo,
once deployed) and cleans up after itself on exit.

**1. If you have a trace ID, start there.**

    iac/scripts/obs trace <trace_id>

This prints every log line across every namespace for that request, then the
span tree from Tempo. Today (pre-merge) this will reliably print
`(no matching lines)` for the logs and `(spans unavailable — could not reach
Tempo)` for the spans — Tempo isn't deployed and nothing emits `trace_id` yet.
That is the correct, expected output right now, not a sign the tool is broken.
Once tracing ships, a real ID will show the full request path here.

**2. If you don't have one, find recent errors and take a trace ID from them.**

    iac/scripts/obs errors --since 1h

Errors across `api-control-plane`, `the-button`, `radio-service`, and `console`.
An empty result means no `level="ERROR"` lines in that window — genuinely good
news, not a query failure (confirmed live: currently returns
`(no matching lines)`, matching a healthy cluster with no errors in the last
hour).

**3. Narrow with raw LogQL when you know what you're looking for.** The query
is a plain LogQL string as the first argument; `--since` comes after it:

    iac/scripts/obs grep '{namespace="api-control-plane"} | json | level="ERROR"' --since 6h
    iac/scripts/obs grep '{namespace="api-control-plane"} | json | status>=500' --since 1h

Verified live against api-control-plane: logs are JSON with `level` (upper-case,
e.g. `"INFO"`, so filter on `level="ERROR"` not `level="error"`) and numeric
`status`, so both filters above run cleanly (currently empty — no errors, no
5xxs, matching the healthz-only traffic seen at query time).

**4. Follow a namespace live** while reproducing, optionally scoped to one
container:

    iac/scripts/obs tail the-button the-button-worker

Verified live: this blocks and prints a `tailing {...} (ctrl-c to stop)` header,
then streams matching lines as they arrive — nothing prints until there's
traffic, which is expected on an idle namespace. Ctrl-C to stop.

## When to leave the logs

Loki holds 7 days; Tempo (once deployed) holds 72 hours. Anything older is
gone — say so rather than guessing.

Logs cannot answer questions about pod *state*: CrashLoopBackOff, pending pods,
OOMKills, image pull failures, or Argo sync status. Use
`kubectl --context algovn-remote` for those. A pod that never started produced
no logs, so an empty `obs` result there is expected, not evidence of anything.

## Reading the output

- `duration_ms` on a `request` line is that hop's latency.
- `service_name` is a Loki LABEL Alloy derives from the pod — query it in the
  stream selector, e.g. `{service_name="the-button-service"}`. Once an
  instrumented service is deployed, `obs.Setup` (in `gopkg/obs`) additionally
  stamps `service`, `version`, and `env` as FIELDS inside every JSON body
  (`env` will be `"prod"`, per `DEPLOY_ENV` in the deployment manifests) —
  query those after `| json`, e.g. `| json | service="the-button-service"`.
  Right now (pre-merge) no body carries them yet, because the instrumented
  services haven't deployed — that's a merge-ordering fact, not a permanent
  one.
- No `trace_id` on a line is expected everywhere right now (pre-merge), and
  will remain expected on background/startup work even after tracing ships,
  since that work has no originating request.
- `radio-service` and `demo-service` are not instrumented for tracing (that's a
  separate piece of work) — their log lines will never carry `trace_id`, even
  after tracing ships elsewhere. Find them by namespace and time instead.

## Gotchas

- Once tracing is live: OTLP span export is fire-and-forget, and a
  NetworkPolicy blocking egress to `tracing/tempo:4317` fails it silently. If
  logs show a `trace_id` but `obs trace` finds no spans, suspect the policy
  before the code.
- `obs trace`'s span half degrades gracefully when Tempo is unreachable — it
  prints `(spans unavailable — could not reach Tempo)` and still shows you the
  log half. It does not error out the whole command.
