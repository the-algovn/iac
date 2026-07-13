# api-control-plane (api.algovn.com)

Public API gateway for every algovn product. Spec: the-algovn/api-control-plane repo,
`docs/superpowers/specs/2026-07-13-api-control-plane-design.md`. Conventions:
`docs/api-conventions.md`. Auth exception: `docs/authnz-conventions.md`.

## Acceptance transcript (2026-07-14, against the live cluster)

```
# anonymous route
$ curl -s https://api.algovn.com/demo/algovn.demo.v1.DemoService/Ping \
    -H 'content-type: application/json' -d '{"message":"hello"}'
{"message":"pong: hello"}                                          (200, confirmed)

# authenticated route without token
$ curl -s -o /dev/null -w '%{http_code}\n' \
    https://api.algovn.com/demo/algovn.demo.v1.DemoService/WhoAmI -d '{}'
401                                                                 (confirmed)
body: {"code":"unauthenticated","message":"missing or invalid bearer token"}

# authenticated route with a garbage (non-JWT) token
$ BAD_TOKEN='garbage.not.a.jwt'
$ curl -s -o /dev/null -w '%{http_code}\n' \
    https://api.algovn.com/demo/algovn.demo.v1.DemoService/WhoAmI \
    -H "Authorization: Bearer $BAD_TOKEN" -d '{}'
401                                                                 (confirmed)
body: {"code":"unauthenticated","message":"missing or invalid bearer token"}

# SSE end-to-end: terminal 1 stays open, terminal 2 triggers a Ping
$ curl -N --max-time 20 https://api.algovn.com/events/demo.ping        # terminal 1
$ curl -s https://api.algovn.com/demo/algovn.demo.v1.DemoService/Ping \
    -H 'content-type: application/json' -d '{"message":"sse"}'        # terminal 2
{"message":"pong: sse"}
terminal 1 -> data: {"message":"pong: sse"}                        (confirmed)
```

### Pending manual run (token-dependent checks)

The `e2e-test` Zitadel service user (project `platform-e2e`) used for authnz-foundation
acceptance was deliberately deleted for good in that project's Task 15 fixture cleanup
(see `.superpowers/sdd/task-15-report.md` §7 — both the project and the service user
now 404). No non-interactive credential-issuing path remains in the cluster: the only
surviving PAT (`zitadel-iam-admin-sa-pat`) is the IAM-admin management-API token, not a
suitable end-user/M2M access token for these routes, and it lives only in the password
manager. Per convention, no new Zitadel service user/project was created ad hoc to
produce a token for this runbook — that is a deliberate console action, not a
gateway-acceptance step. Run the following manually once a token is available (any app
or service user with **Access Token Type: JWT**, see `docs/runbooks/zitadel.md`):

```bash
# mint a token (client credentials, service user with Access Token Type: JWT)
TOKEN='<zitadel access token>'

# WhoAmI 200 + sub
curl -s https://api.algovn.com/demo/algovn.demo.v1.DemoService/WhoAmI \
  -H "Authorization: Bearer $TOKEN" -d '{}'
# expect: {"sub":"<your user id>"}                                  (200)

# AdminPing 403 with a non-admin token
curl -s -o /dev/null -w '%{http_code}\n' \
  https://api.algovn.com/demo/algovn.demo.v1.DemoService/AdminPing \
  -H "Authorization: Bearer $TOKEN" -d '{}'
# expect: 403
```

Expected: every command returns the annotated result. If SSE stalls, check Kong response
buffering annotation and `kubectl -n api-control-plane logs` for `rabbitmq connected`.

## Operational notes

- **Route changes** — edit `apps/api-control-plane/registrations/*.yaml`, PR, Argo sync;
  the pod hot-reloads within ~1 min (kubelet ConfigMap sync), no restart. A broken file
  keeps the last good config and increments `acp_config_reload_errors_total`.
- **New upstream after deploy** — descriptors retry every 30s; a spike in
  `acp_requests_total{code="502"}` means the upstream is down or lacks reflection.
- **RabbitMQ credential rotation** — the default user is only created on first boot; to
  rotate: `kubectl -n rabbitmq exec rabbitmq-0 -- rabbitmqctl change_password events '<new>'`,
  then reseal `amqp-creds` in both the `api-control-plane` and `demo-service` namespaces
  and update the password manager entry (`rabbitmq-events`).
- **Metrics** — `acp_*` series in VictoriaMetrics; SSE gauge is `acp_sse_clients`.
