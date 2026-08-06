# Stateful services on dedicated VMs

All stateful workloads are migrating off k3s onto two Proxmox VMs. Design:
`~/the-algovn/archive/iac/specs/2026-08-04-stateful-services-vm-migration-design.md`
(archive is local-only, not in git).

| VM | VMID | IP | vCPU | RAM | disk | holds |
|---|---|---|---|---|---|---|
| algovn-data | 114 | 192.168.102.114 | 16 | 32G | 100G | postgres, redis, minio, redpanda, tempo |
| algovn-obs | 115 | 192.168.102.115 | 4 | 8G | 64G | victoria-metrics, loki, uptime-kuma |

## PV reclaim policy — do not revert

Every `local-path` PV was patched from `Delete` to `Retain` on 2026-08-04. This is
the ONLY safety net protecting cluster data: there are no backups, and the Phase 3
Postgres cutover deletes the CNPG `Cluster` CR, which cascades to its PVC. With
`Delete`, that cascade destroys the database.

`local-path` provisions new PVs with `Delete` (it is the StorageClass default and
is not configurable per-claim), so **any newly created PVC must be patched by
hand**:

    kubectl --context algovn-remote patch pv <name> \
      -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

Audit that none have drifted back:

    kubectl --context algovn-remote get pv -o json \
      | jq -r '[.items[] | select(.spec.storageClassName=="local-path")
               | select(.spec.persistentVolumeReclaimPolicy!="Retain")] | length'

Expected: `0`. Anything else means a PV is unprotected.

⚠️ `Retain` means deleting a PVC leaves the PV `Released` and the data on disk,
but the PV will NOT rebind to a new claim of the same name — it must be deleted
and recreated, or its `claimRef` cleared. That is the intended trade: manual work
instead of silent destruction.

## Build (or rebuild) the VMs

Cloned from template 9000, which already supplies `agent: enabled=1`, `ciuser: ducle`,
`cpu: host`, `ciupgrade: 1` and the operator SSH key — do not set those again.

    ssh pve '
      qm clone 9000 114 --name algovn-data --full 1 --storage local-lvm &&
      qm set 114 --cores 16 --memory 32768 \
        --ipconfig0 ip=192.168.102.114/24,gw=192.168.102.1 \
        --onboot 1 --cpuunits 2048 --startup order=1 &&
      qm resize 114 scsi0 100G && qm start 114
    '

`algovn-obs` is the same with VMID 115, 4 cores, 8192 MB, `.115`, 64G,
`--cpuunits 1024`, `--startup order=5`.

**Startup order is deliberate:** algovn-data is order 1 so Postgres/MinIO are
listening before k3s (algovn=2, w1=3, w2=4) starts scheduling pods that connect to
them. algovn-obs is order 5 — nothing depends on it.

These VMs are NOT k3s nodes and must never be added to the `agents` inventory group
(that group is what runs the `k3s_agent` role).

After boot, confirm the guest filesystem grew — `qm resize` only grows the virtual
disk, cloud-init's growpart grows the partition on first boot:

    ssh data 'df -h /'   # expect ~98G, not the template's 3.5G

Reach them with `ssh data` / `ssh obs`. The laptop is not on the cluster LAN, so
both jump through `cp` — append to `~/.ssh/config` on the Mac (this is what makes
the `ssh data 'df -h /'` check above work, and what ansible's `-J cp` relies on):

    Host data
      HostName 192.168.102.114
      User ducle
      ProxyJump cp

    Host obs
      HostName 192.168.102.115
      User ducle
      ProxyJump cp

## Ansible

    cd ansible
    ansible-galaxy collection install -r requirements.yml   # once per controller
    ansible-playbook site.yml --limit data,obs --check --diff   # dry run
    ansible-playbook site.yml --limit data,obs

The collection install is not optional on a fresh controller: with bare
`ansible-core` the firewall role dies on `community.general.ufw` with a
"couldn't resolve module/action" error that does not name the missing collection.

Every host is reached via `-J cp` (set once in `inventory.yml` under `all.vars`),
including `algovn` itself — no `~/.ssh/config` stanza matches the bare
`192.168.102.x` addresses, so without the jump a `hosts: all` play fails
UNREACHABLE.

The `--check` run is the safety gate that proves the k3s roles do not target these
VMs: expect `PLAY [k3s server]` and `PLAY [k3s agents]` to report
`skipping: no hosts matched`.

## Firewall

ufw is ansible-managed on these VMs (unlike the k3s nodes, where it is hand-managed
because it must exist before the agent joins). Rules come from
`ansible/group_vars/{data,obs}.yml`:

- `firewall_node_ports` — reachable ONLY from the three k3s node IPs. Pods SNAT to
  their node, so those are the only legitimate in-cluster sources.
- `firewall_lan_ports` — reachable from the whole LAN. Currently 5432 (the
  deliberate psql/DBeaver admin path from postgres.md) and 9001 (MinIO console).

To OPEN a port, add it to the group var and re-run
`ansible-playbook site.yml --limit data,obs --tags firewall`.

⚠️ **The role is additive only — it never reconciles.** `community.general.ufw`
issues `ufw allow`; it does not diff the live rule set against the group vars. Two
consequences:

- **Removing a port from `firewall_node_ports` does NOT close it.** The rule
  survives every subsequent play. Close it by hand, once per source IP:

      ssh data 'sudo ufw delete allow from <ip> to any port <n> proto tcp'

  For a `firewall_node_ports` entry that is all three k3s node IPs
  (`.111`, `.112`, `.113`); for a `firewall_lan_ports` entry it is
  `from 192.168.102.0/24`. Then confirm with `sudo ufw status | grep <n>`.
- **A hand-added rule is NOT reverted on the next play.** It persists until
  deleted with the same command. Keeping the group vars authoritative is a
  convention, not something the tooling enforces.

Redpanda has no authentication, so the node-IPs-only rule is the entirety of its
access control. If it ever needs wider reach, enable SASL first rather than
widening the ufw rule. **This holds only because the quadlets use `Network=host`** —
see "ufw does not govern published ports" below before changing any container's
networking mode.

Locked out? Recover from the Proxmox serial console — **114 is data, 115 is obs**,
and you cannot SSH in to find out which you broke:

    ssh pve 'qm terminal 114'    # algovn-data
    ssh pve 'qm terminal 115'    # algovn-obs

then log in and `sudo ufw disable`. (`qm terminal` exits with `Ctrl-O`.)

## Containers (quadlets)

MinIO, Redpanda, VictoriaMetrics, Loki, Tempo and uptime-kuma run as podman
**quadlets** — `*.container` files in `/etc/containers/systemd/` that
`podman-system-generator` turns into real systemd units at `daemon-reload`. So
`systemctl status loki` and `journalctl -u loki` work normally, and upgrades are a
pinned-tag bump in the role, matching how the Helm values pinned them before.

Postgres and Redis are NOT containers — they are native apt packages (PGDG and
redis.io repos), because the database benefits from `pg_upgradecluster`, unattended
security updates and the standard /etc/postgresql layout.

### Smoke-test the generator after a podman upgrade

    sudo tee /etc/containers/systemd/quadlet-smoke.container >/dev/null <<EOF
    [Unit]
    Description=Quadlet smoke test
    [Container]
    Image=docker.io/library/busybox:1.37
    Exec=sleep 600
    [Install]
    WantedBy=multi-user.target
    EOF
    sudo systemctl daemon-reload && sudo systemctl start quadlet-smoke.service
    sudo systemctl is-active quadlet-smoke.service   # expect: active

Tear it down completely — stopping a quadlet whose container is already gone leaves
a phantom `not-found failed` unit that `systemctl --failed` reports forever (both VMs
carried one from the Phase 1 smoke test until 2026-08-04):

    sudo systemctl stop quadlet-smoke.service
    sudo rm -f /etc/containers/systemd/quadlet-smoke.container
    sudo systemctl daemon-reload
    sudo systemctl reset-failed quadlet-smoke.service
    sudo podman rm -f quadlet-smoke
    sudo podman rmi docker.io/library/busybox:1.37
    sudo systemctl --failed --no-legend    # expect: no output

⚠️ Name the probe explicitly, as above. Never `podman rm -af && podman rmi -a` here:
since Phase 2 algovn-obs runs Loki, uptime-kuma and VictoriaMetrics as quadlets (Phase 3
adds Tempo, and gives algovn-data MinIO and Redpanda), `rm -af` force-removes RUNNING
containers, and quadlet units default to `Restart=no` — so a blanket teardown takes
every service on that VM down until someone restarts them by hand and re-pulls every
image.

## Cutover mechanics

Everything in this section applies to **every** service that moves onto these VMs, not
just the one it was first learned from. Phase 3 — Postgres, Redis, MinIO, Redpanda, then
Tempo — repeats all of it, and Postgres in particular breaks logins cluster-wide for the
length of its window. Read this section before starting a cutover; the per-service
sections below record only what is specific to one service.

### Keeping the in-cluster DNS name — selector-less Service + Endpoints

A service that moves to a VM keeps its cluster DNS name by leaving behind a Service with
**no `spec.selector`** plus a hand-written `Endpoints` object holding the VM's IP.
Nothing that consumed the name has to change: alloy still pushes to
`loki.logging.svc:3100`, Kong's Ingress still targets `uptime-kuma` by name. Phase 3 does
the same for `redis`, `minio`, `redpanda` and `pg-rw`. (VictoriaMetrics is the exception —
the chart resolves its own URLs, so it is a values change instead; see its section.)

Three consequences, each of which has already cost time:

- **Argo excludes `Endpoints` from sync by default.**
  `platform/argocd/patches/exclusions-cm.yaml` is what re-includes them. Without that
  patch the Endpoints object is silently skipped while the Application still reports
  Synced — the Service exists, resolves, and blackholes.
- **`kubectl port-forward svc/<name>` stops working**, permanently:

      error: cannot attach to *v1.Service: invalid service 'loki': Service is defined without a selector

  port-forward resolves a Service to a pod through `spec.selector`, and there is none.
  The apiserver service proxy is not a workaround either — `no endpoints available for
  service`. The laptop is not on the cluster LAN, so the access path is an SSH tunnel:

      ssh -o ExitOnForwardFailure=yes -N -L 8428:localhost:8428 obs

  `scripts/obs` carries a `service_host()` table for exactly this reason. **When a
  service moves, update that table in the same commit** — Phase 2 did not, and the
  production log-reading path the `algovn-prod-debug` skill points at was dead until
  2026-08-05. Tempo moved to algovn-data 2026-08-05.
- **A stale EndpointSlice survives the cutover.** The EndpointSlice controller stops
  reconciling a Service the moment its selector is removed and does not garbage-collect
  slices it already created, so the pre-cutover slice is frozen in place indefinitely.
  `logging/loki-k2tg2` (→ `10.42.1.130`) and `uptime-kuma/uptime-kuma-hp5zk`
  (→ `10.42.1.151`) both outlived Phase 2 and were deleted by hand on 2026-08-05.
  Traffic was never split — kube-proxy only uses `ready: true` endpoints and both stale
  entries were `ready: false` — but a Service showing two backends is exactly what an
  operator chasing a Kong 503 will latch onto. **Expect one per cutover in Phase 3 and
  delete it:**

      kubectl --context algovn-remote delete endpointslice -n <ns> <stale-slice>

Check backends through **EndpointSlice, not Endpoints**. `v1 Endpoints` is deprecated
(the cluster answers with `Warning: v1 Endpoints is deprecated in v1.33+; use
discovery.k8s.io/v1 EndpointSlice` — it is on v1.36) and, more importantly, a stale
slice is invisible through the old API:

    kubectl --context algovn-remote get endpointslice -n <ns> -l kubernetes.io/service-name=<svc>

Expect exactly ONE slice, holding the VM's IP. If traffic, logs or metrics stop while the
Argo app reads Synced/Healthy, look here first.

### Argo prunes chart-managed PVCs

A **chart-managed PVC is pruned by Argo when the chart source is removed** — this is how
`storage-loki-0` disappeared along with its StatefulSet. Every cutover that follows the
"remove the chart source, let Argo prune" pattern (Postgres, MinIO, Redis, Redpanda)
shares the behaviour. The PV survives only because of the `Retain` patch at the top of
this runbook; without it the prune would have destroyed the data.

### Argo hard-refresh after source changes

When the set of sources in an Argo Application changes (remove one chart, add a `path`
source), Argo may report `Synced/Healthy` while old resources from the removed chart are
still present. A `hard` refresh forces re-evaluation:

```bash
kubectl --context algovn-remote -n argocd annotate app <app> \
  argocd.argoproj.io/refresh=hard
```

Once pruning completes, remove the annotation — a persistent `refresh` annotation makes
Argo report perpetual OutOfSync even when nothing drifted:

```bash
kubectl --context algovn-remote -n argocd annotate app <app> \
  argocd.argoproj.io/refresh-
```

This is especially load-bearing when cutting over a database: a green app with the old
in-cluster instance still running means the old instance is still taking writes, which
for Postgres is a split brain.

### Rollback — rebind the surviving `Retain` PV

Reverting a cutover is NOT a one-line git revert. The PVC was pruned; its PV survives
with data intact, but in status `Released` — and **a `Released` PV will not bind a new
PVC even one with the identical name.** The StatefulSet then sits Pending forever with
nothing explaining why. Clearing `claimRef` is the step that makes rollback possible at
all, and it applies to every service in this runbook:

```bash
# 1. Restore the chart source in clusters/algovn/platform/<app>.yaml and push.
# 2. Clear the PV's claimRef so a new PVC of the same name can bind it:
kubectl --context algovn-remote patch pv <pv> -p '{"spec":{"claimRef":null}}'
# 3. Hard-refresh, per the section above — Argo may otherwise report Synced/Healthy
#    without syncing the restored chart:
kubectl --context algovn-remote -n argocd annotate app <app> argocd.argoproj.io/refresh=hard
# 4. Verify the new PVC bound the existing PV — expect STATUS=Bound, VOLUME=<pv>:
kubectl --context algovn-remote -n <ns> get pvc <pvc>
# 5. Remove the annotation so Argo does not report perpetual drift:
kubectl --context algovn-remote -n argocd annotate app <app> argocd.argoproj.io/refresh-
```

The per-service `<app>` / `<pv>` / `<pvc>` values are in the sections below. Confirm the
PV name against `kubectl get pv` before patching — the claim column still shows which
service each `Released` volume belonged to.

### ufw does not govern published ports — use `Network=host`

**Every quadlet on these VMs MUST use `Network=host` and bind its real port
directly. Do not use `PublishPort`.** Measured 2026-08-04; this is not a style
preference.

A published port is DNAT'd in `nat/PREROUTING` (`NETAVARK-HOSTPORT-DNAT` →
`DNAT --to-destination 10.88.0.x`) *before* the routing decision. The packet's
destination is then the container, not the host, so it is **forwarded, not
delivered locally** — it never traverses `filter/INPUT`, where the entire
`firewall_node_ports` rule set lives. It lands in `FORWARD`, which jumps
`NETAVARK_FORWARD` **before** every ufw chain:

    -A FORWARD -m comment --comment "netavark firewall plugin rules" -j NETAVARK_FORWARD
    -A FORWARD -j ufw-before-forward
    ...

and that chain accepts only traffic already ESTABLISHED toward `10.88.0.0/16` or
sourced *from* it. A new inbound connection matches neither, so it falls through to
`-P FORWARD DROP`.

Net effect: a `PublishPort` service is unreachable from the k3s nodes **even with an
explicit ufw ALLOW for that port**, and adding the rule does nothing. The failure is
a silent 8-second connect timeout with no log line anywhere — expensive to debug.

`Network=host` sidesteps all of it: the container binds the host address, so traffic
is delivered locally, hits `filter/INPUT`, and the already-proven ufw rules apply
unchanged — exactly as they do for the native `node_exporter`. These are
single-tenant VMs running one instance of each service, so container network
isolation buys nothing to offset the cost.

Rejected alternatives: `DEFAULT_FORWARD_POLICY=ACCEPT` + `ufw route allow` (netavark's
chain runs first, so the route rules may never be consulted) and binding
`PublishPort` to a host IP (still DNAT, still forwarded).

**Two-source check** — rerun this whenever a quadlet's networking changes. `w1` is a
k3s node (in `firewall_node_ports`' allow list); `pve` is on the LAN but is not:

    # from a k3s node — expect code=200/404, exit=0, sub-second
    ssh w1 'curl -s -o /dev/null -m 8 -w "code=%{http_code} time=%{time_total}\n" http://192.168.102.114:<port>/'
    # from a non-node LAN host — expect code=000, exit=28, ~8s (dropped)
    ssh pve 'curl -s -o /dev/null -m 8 -w "code=%{http_code} time=%{time_total}\n" http://192.168.102.114:<port>/'

The timing discriminates: ~8 s with exit 28 is a **drop**; sub-second exit 7 is a
**refusal** (reached the host, nothing listening); a response code means it got
through. Two 8-second timeouts where the k3s node should have succeeded is the
signature of the `PublishPort` trap above — check `sudo iptables -t nat -S | grep <port>`
for a DNAT rule.

## Monitoring

Both VMs run `node_exporter` (ansible role `node_exporter`, tag `node_exporter`) on
**:9100**, opened to the k3s node IPs only. They are not cluster members, so there is
no Service or Pod for the operator to discover — targets are listed statically in
`platform/monitoring/manifests/vmstaticscrape-stateful-vms.yaml`, a `VMStaticScrape`
CR under Argo, job name **`stateful-vms`**. Phase 3 appends `postgres_exporter`
(9187), `redis_exporter` (9121) and Tempo (3200) to the same CR.

**A service that moves onto a VM must be added to that CR in the same commit.** Its
in-cluster `VMServiceScrape`/`VMPodScrape` dies with the workload, and nothing replaces
it automatically. Phase 2 initially missed this for VictoriaMetrics itself: `vm_rows`,
`vm_free_disk_space_bytes` and `vm_slow_inserts_total` simply stopped existing, so a
metrics store filling its disk would have gone unnoticed until it stopped answering.
`192.168.102.115:8428` (VictoriaMetrics) and `:3100` (Loki) were added on 2026-08-05.

Check the targets are up:

    ssh obs 'curl -sG http://localhost:8428/api/v1/query \
      --data-urlencode "query=up{job=\"stateful-vms\"}" | jq ".data.result"'

Expect four series, all `"1"`: `192.168.102.114:9100`, `192.168.102.115:9100`,
`192.168.102.115:8428` and `192.168.102.115:3100`.

Raw check from a k3s node, bypassing the cluster entirely:

    ssh w1 'curl -s -o /dev/null -w "%{http_code}\n" http://192.168.102.114:9100/metrics'   # 200

**If the targets never appear at all** (no series, not even `0`), the likely cause is
vmagent not selecting the CR rather than anything on the VMs:

    kubectl --context algovn-remote -n monitoring get vmagent -o jsonpath='{.items[*].spec.selectAllByDefault}'

If that is not `true`, vmagent only picks up CRs matching its explicit selectors and
this one is ignored silently — the VMs stay invisible with no error anywhere.

### Known gap: no host metrics for cp and w1

`up{job="node-exporter"}` is `0` for `192.168.102.111` (cp) and `.112` (w1), and `1`
only for `.113` (w2) — measured 2026-08-05, and true since long before the VM
migration. ufw is active on all three k3s nodes, hand-managed (see
docs/runbooks/add-node.md), and neither cp nor w1 allows **9100** from the other nodes;
vmagent therefore only ever reaches the exporter on the node it happens to run on.

So CPU, memory, disk and network for two of the three k3s nodes have **never** been
collected. That matters for Phase 3 in one specific way: `postgres.md` tells you to
watch w1's disk fill, and w1 is one of the two nodes you cannot see.

This is deliberately **not fixed here** — it predates the migration and changing a k3s
node's firewall is outside a stateful-services change. The fix, when someone takes it,
is `ufw allow from 192.168.102.0/24 to any port 9100 proto tcp` on cp and w1, by hand
on each node, plus adding 9100 to the port list in add-node.md's step 2 (already
listed there as what a node should allow).

## Loki

Runs on algovn-obs as a podman quadlet (ansible role `loki`, tag `loki`), config at
`/etc/loki/loki.yaml`, data at `/var/lib/loki`, listening on **:3100**. Filesystem
storage, 168 h retention — same settings the Helm chart had.

In-cluster, `loki.logging.svc:3100` is a **selector-less Service + Endpoints**
(`platform/logging/manifests/`) pointing at `192.168.102.115`. That is why
`alloy`'s push URL and Grafana's Loki datasource were never edited — the name still
resolves. The loki Helm chart source was removed from
`clusters/algovn/platform/logging.yaml`; alloy remains a chart.

If logs stop flowing while the `logging` app reads Synced/Healthy, check the
EndpointSlice first — see "Keeping the in-cluster DNS name" under Cutover mechanics:

    kubectl --context algovn-remote get endpointslice -n logging -l kubernetes.io/service-name=loki

Existing history was NOT migrated (168 h retention, and copying a live TSDB index
risks corrupting it).

**Rollback** — app `logging`, PV `pvc-819f5e0e-d1a0-4324-90a2-869219f8d80a`, PVC
`storage-loki-0` in ns `logging`; follow "Rollback — rebind the surviving `Retain` PV"
under Cutover mechanics. The PV is `Released` with 131 MB of data intact at
`/var/lib/rancher/k3s/storage/pvc-819f5e0e-d1a0-4324-90a2-869219f8d80a_logging_storage-loki-0`
on algovn-w1. Step 1 is restoring the loki chart source in
`clusters/algovn/platform/logging.yaml`.

Debug: `systemctl status loki` and `journalctl -u loki -n 50` on the VM;
`curl localhost:3100/ready` there; from a k3s node,
`curl http://192.168.102.115:3100/ready`.

## uptime-kuma

Runs on algovn-obs as a podman quadlet (ansible role `uptime_kuma`, tag
`uptime_kuma`), data at `/var/lib/uptime-kuma`, listening on **:3001**.

In-cluster, `uptime-kuma.uptime-kuma.svc:80` is a selector-less Service + Endpoints
(`apps/uptime-kuma/`) targeting `192.168.102.115:3001` — see "Keeping the in-cluster
DNS name" under Cutover mechanics. The `uptime.algovn.com` Kong Ingress was not
edited — it still points at that Service by name, so a `503` from Kong means the
Endpoints/EndpointSlice, not the Ingress.

Nothing was migrated because nothing existed: the in-cluster deployment mounted its
PVC at `/app/data`, but the image of the day (the `2.4.0` tag at its May 2026 digest)
wrote `kuma.db` to `/app/db/` in the container's **ephemeral layer** — every pod
restart silently discarded the configuration. The 16 K-empty PVC on w1
(`pvc-dfd7f0a7-…`) is the evidence. This migration therefore **fixed** a latent
data-loss bug rather than merely relocating the service.

Data now lives at `/var/lib/uptime-kuma` on obs and is genuinely persistent
(bind-mounted to `/app/data` by the quadlet; `kuma.db` plus `old_migrations/`,
~844 K). The `/app/db` → `/app/data` path change between the old and new image
digests is why this was broken before and why the quadlet pins the image by digest
rather than by tag.

If a rebuild is ever needed, copy `/var/lib/uptime-kuma` with the container stopped,
since SQLite must be quiescent for a consistent copy.

## VictoriaMetrics

The STORAGE half runs on algovn-obs as a podman quadlet (ansible role
`victoria_metrics`, tag `victoria_metrics`), data at `/var/lib/victoria-metrics`,
listening on **:8428**, 15 d retention.

`vmagent` deliberately stays IN the cluster — that is what keeps the 19
`VMServiceScrape`/`VMPodScrape` CRs working. It scrapes as before and remote-writes
outward to the VM. Moving vmagent too would mean hand-writing a `promscrape.yml`
with `kubernetes_sd_configs` and abandoning every scrape CR.

This is NOT an Endpoints case. The chart resolves its own URLs, so
`platform/monitoring/values.yaml` sets `vmsingle.enabled: false` plus
`external.vm.read.url` / `external.vm.write.url` — which repoints vmagent's remote
write, Grafana's VictoriaMetrics datasource and vmalert's routing together.

Verify chart-behaviour changes here with `helm template` before pushing. A broken
remote write silently drops every metric in the cluster:

    helm template vm vm/victoria-metrics-k8s-stack --version 0.86.0 \
      -f platform/monitoring/values.yaml | grep -A3 'remoteWrite:'

History migration was attempted with `vmctl vm-native` run as a one-off in-cluster
pod, but was killed by an Argo prune of the source `vmsingle-vm` Deployment after
~3% progress. The 15 d of history in the old vmsingle was therefore **not
recovered** — do not try to get it back, it is gone.

### Rollback

The pre-cutover PVC `vmsingle-vm` was pruned along with the Deployment; its `Retain`
PV survives on algovn-w1 with data intact. Confirm the name before patching — it is
the `Released` PV whose claim reads `monitoring/vmsingle-vm`:

    kubectl --context algovn-remote get pv | grep vmsingle
    # pvc-f73f0fd9-e95d-424c-999c-1c586a37cc9b  20Gi  RWO  Retain  Released  monitoring/vmsingle-vm

The generic procedure is "Rollback — rebind the surviving `Retain` PV" under Cutover
mechanics, with app `monitoring`, PV `pvc-f73f0fd9-e95d-424c-999c-1c586a37cc9b`, PVC
`vmsingle-vm` in ns `monitoring`. **Step 1 differs from Loki's**: there is no chart
source to restore. Revert `platform/monitoring/values.yaml` instead — set
`vmsingle.enabled: true` and remove `external.vm.read.url` / `external.vm.write.url`,
which repoints vmagent's remote write, Grafana's datasource and vmalert's routing back
together. Then:

```bash
kubectl --context algovn-remote patch pv pvc-f73f0fd9-e95d-424c-999c-1c586a37cc9b \
  -p '{"spec":{"claimRef":null}}'
kubectl --context algovn-remote -n argocd annotate app monitoring \
  argocd.argoproj.io/refresh=hard
kubectl --context algovn-remote -n monitoring get pvc vmsingle-vm
# Expect STATUS=Bound, VOLUME=pvc-f73f0fd9-…
kubectl --context algovn-remote -n argocd annotate app monitoring \
  argocd.argoproj.io/refresh-
```

Clearing `claimRef` is as load-bearing here as it is for Loki: without it the PV stays
`Released`, refuses to bind a PVC of the same name, and the VMSingle pod sits Pending
with nothing saying why. Rolling back also loses everything written to the VM since the
cutover — the two stores never replicated to each other.

### `-search.latencyOffset=30s`

VictoriaMetrics defaults `-search.latencyOffset=30s`: an **instant query**
(`/api/v1/query`) cannot see a sample written less than ~30 seconds ago. This is by
design — it prevents queries from returning partial results while the most recent
scrape is still in flight. It applies to instant queries only; `/api/v1/query_range`
is not affected.

The practical consequence: after a cutover or restart, `count(up)` or any instant
query will return 0 or empty until at least 35-40 seconds have passed since the
first write. Do not conclude ingestion is broken until you have waited that long, or
verified via `query_range`:

    ssh obs 'curl -sG "http://localhost:8428/api/v1/query_range" \
      --data-urlencode "query=count(up)" \
      --data-urlencode "start=$(date -u -v-5M +%s)" \
      --data-urlencode "end=$(date -u +%s)" \
      --data-urlencode "step=60" | jq -r ".data.result[].values[-1][1]"'

Debug: `systemctl status victoria-metrics` / `journalctl -u victoria-metrics` on the
VM; `curl localhost:8428/health` there; `kubectl -n monitoring logs deploy/vmagent-vm`
for write failures.

## MinIO

Runs on algovn-data as a podman quadlet (ansible role `minio`, tag `minio`), data at
`/var/lib/minio`, listening on **:9000** (S3) and **:9001** (console). Root credentials
come from OpenBao and must match the cluster's `minio-root` ExternalSecret — if they
drift, the two in-cluster provisioning Jobs fail and consumers cannot authenticate.

In-cluster, `minio.minio.svc:9000` is a **selector-less Service + Endpoints**
(`platform/minio/manifests/`) pointing at `192.168.102.114`. The StatefulSet was
deleted; the two provisioning Jobs (`minio-bucket-radio-lab` and
`minio-provision-the-race`) still run in-cluster as PostSync hooks and are what
recreate the `the-race` IAM user — **IAM lives in MinIO's IAM store, not in bucket
data, so `mc mirror` does not carry it across.** Without that Job, every race goes out
silent while the AI still writes the lines.

### Rollback

App `minio`, PV `pvc-f3c0cdc9-70cf-4619-a99e-09a8716b991c`, PVC `data-minio-0` in ns
`minio`. Follow "Rollback — rebind the surviving `Retain` PV" under Cutover mechanics.
Step 1 is restoring `statefulset.yaml` and reverting the Service (put `selector: {
app: minio }` back), plus removing `endpoints.yaml` from `kustomization.yaml`. The PV
survived the pruning (hand-written volumeClaimTemplates behave differently from
chart-managed ones), so `claimRef` clearing may not be needed — but verify the PVC
state before assuming.

Debug: `systemctl status minio` / `journalctl -u minio -n 50` on the VM;
`curl localhost:9000/minio/health/live` there; from a k3s node,
`curl http://192.168.102.114:9000/minio/health/live`.

## Redpanda

Runs on algovn-data as a podman quadlet (ansible role `redpanda`, tag `redpanda`), data at
`/var/lib/redpanda`, listening on **:9092** (Kafka) and **:9644** (admin). `dev-container`
mode with relaxed durability — same flags the StatefulSet passed. The image's
`/entrypoint.sh` delegates to `rpk`; the quadlet uses `Exec=redpanda start ...` (no
`Entrypoint=` — quadlet 4.9 does not support that key).

In-cluster, `redpanda.redpanda.svc:9092` / `:9644` is a **selector-less Service +
Endpoints** (`platform/redpanda/manifests/`) pointing at `192.168.102.114`. All
consumers (the-button service and worker, radio-service) reach it unchanged.

Redpanda has no authentication — the node-IPs-only ufw rule is its entire access
control. Topics are provisioned by two PreSync Jobs (`the-button/the-button-topics`
and `radio-service/radio-topics`) which are idempotent. `auto_create_topics_enabled`
is `false` — nothing can produce until those Jobs have run.

**No data migration was needed** — `dev-container` mode has relaxed durability, and
the spec records that a lost Kafka record is safe to drop because Redis is
authoritative and Postgres snapshots. The six topics were recreated by the
provisioning Jobs on the new broker (see below).

### Recreating topics after a broker rebuild

A new broker starts with no topics and `auto_create_topics_enabled=false`. Until
the provisioning Jobs run, producers fail silently — the-button's clicks simply stop
being recorded with nothing erroring loudly. This applies to every rebuild, whether
from a lost data directory, an image upgrade that wipes state, or a re-cloned VM.

The two PreSync Jobs (`the-button/the-button-topics` and
`radio-service/radio-topics`) are idempotent, but **Argo hook Jobs do not re-run on
an already-synced app.** A `kubectl annotate app ... refresh=hard` will report
Synced/Healthy without triggering the hooks. The procedure below is the actual
sequence:

```bash
# 1. Delete both Jobs so Argo does not fight a replacement.
kubectl --context algovn-remote -n the-button delete job the-button-topics
kubectl --context algovn-remote -n radio-service delete job radio-topics

# 2. Create non-hook copies — these run once, immediately, and do not interfere
#    with the Argo-managed originals.
kubectl --context algovn-remote create -n the-button -f -o yaml <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: the-button-topics
  namespace: the-button
spec:
  backoffLimit: 3
  activeDeadlineSeconds: 600
  template:
    metadata: { labels: { app: the-button-topics } }
    spec:
      restartPolicy: Never
      containers:
        - name: topics
          image: docker.redpanda.com/redpandadata/redpanda:v24.2.7
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              B=redpanda.redpanda.svc.cluster.local:9092
              until rpk cluster info --brokers $B >/dev/null 2>&1; do
                echo "waiting for redpanda..."; sleep 5
              done
              rpk topic create clicks -p 1 -r 1 -c retention.ms=300000 --brokers $B || true
              rpk topic create sse.counter sse.leaderboard sse.user -p 1 -r 1 -c retention.ms=60000 --brokers $B || true
              rpk topic describe clicks sse.counter sse.leaderboard sse.user --brokers $B
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { memory: 128Mi }
YAML

kubectl --context algovn-remote create -n radio-service -f -o yaml <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: radio-topics
  namespace: radio-service
spec:
  backoffLimit: 3
  activeDeadlineSeconds: 600
  template:
    metadata: { labels: { app: radio-topics } }
    spec:
      restartPolicy: Never
      containers:
        - name: topics
          image: docker.redpanda.com/redpandadata/redpanda:v24.2.7
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              B=redpanda.redpanda.svc.cluster.local:9092
              until rpk cluster info --brokers $B >/dev/null 2>&1; do
                echo "waiting for redpanda..."; sleep 5
              done
              rpk topic create sse.radio.nowplaying sse.radio.queue -p 1 -r 1 -c retention.ms=60000 --brokers $B || true
              rpk topic describe sse.radio.nowplaying sse.radio.queue --brokers $B
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { memory: 128Mi }
YAML

# 3. Wait for both to complete, then verify all six topics:
kubectl --context algovn-remote wait job -n the-button the-button-topics --for=condition=Complete --timeout=120s
kubectl --context algovn-remote wait job -n radio-service radio-topics --for=condition=Complete --timeout=120s
kubectl --context algovn-remote -n the-button run verify --rm -i --restart=Never \
  --image=docker.redpanda.com/redpandadata/redpanda:v24.2.7 --command \
  -- rpk topic list --brokers redpanda.redpanda.svc:9092

# 4. After verifying, delete the non-hook Jobs and let Argo reconcile the
#    originals on the next sync:
kubectl --context algovn-remote -n the-button delete job the-button-topics
kubectl --context algovn-remote -n radio-service delete job radio-topics
kubectl --context algovn-remote -n argocd annotate app the-button argocd.argoproj.io/refresh=hard
kubectl --context algovn-remote -n argocd annotate app radio-service argocd.argoproj.io/refresh=hard
# Remove annotations after Argo syncs:
kubectl --context algovn-remote -n argocd annotate app the-button argocd.argoproj.io/refresh-
kubectl --context algovn-remote -n argocd annotate app radio-service argocd.argoproj.io/refresh-
```

### All rpk topic commands must run in-cluster, not on the VM

`rpk` follows the broker's advertised listener
(`redpanda.redpanda.svc.cluster.local`) for every topic subcommand — `list`,
`describe`, `consume`, `produce`, and `create` alike — and that name does not
resolve on the data VM (it is not a k3s node). The listener deliberately advertises
an in-cluster name because Kafka clients bootstrap to the Service, then follow the
advertised address; pointing it at the VM's IP would break every in-cluster consumer.
A one-off pod in the cluster is the workaround:

    kubectl --context algovn-remote -n the-button run rpk --rm -i --restart=Never \
      --image=docker.redpanda.com/redpandadata/redpanda:v24.2.7 --command \
      -- rpk topic list --brokers redpanda.redpanda.svc:9092

**Rollback** — app `redpanda`, PV `pvc-bcc4c7cf-dbdf-4eb8-9d0c-3972accc0ee7`, PVC
`data-redpanda-0` in ns `redpanda`. Follow "Rollback — rebind the surviving `Retain` PV"
under Cutover mechanics. Step 1 is restoring `statefulset.yaml`, reverting the Service
(put `selector: { app: redpanda }` back) and removing `endpoints.yaml` from
`kustomization.yaml`. The PV survived the prune (hand-written volumeClaimTemplates
survive chart-managed pruning).

Debug: `systemctl status redpanda` / `journalctl -u redpanda -n 50` on the VM;
`curl localhost:9644/v1/status/ready` there; from a k3s node,
`curl http://192.168.102.114:9644/v1/status/ready`.

## Redis

Runs on algovn-data as a native apt package from the redis.io repo (ansible role
`redis_server`, tag `redis`), data at `/var/lib/redis`, listening on **:6379**.
`redis_exporter` listens on **:9121**. Both are native systemd units, not containers.

In-cluster, `redis.redis.svc:6379` / `:9121` is a **selector-less Service +
Endpoints** (`platform/redis/manifests/`) pointing at `192.168.102.114`. The-button's
`REDIS_URL` secret (`redis://***@redis.redis.svc:6379`) stayed valid unchanged.

`maxmemory-policy noeviction` is load-bearing: `counter:global` and `applied:<id>` keys
make the-button's click accounting exactly-once, and evicting one under memory pressure
would silently corrupt the public counter exactly as data loss would. Verify with
`config get maxmemory-policy`, not by reading the config file.

### Migrating data from the in-cluster instance

This is a data-bearing migration — the dataset is small (~22 keys, ~312 K) but the
counter value is publicly visible. The procedure is a guarded SAVE-then-copy.

**The AOF silently wins over dump.rdb.** With `appendonly yes`, removing the AOF files
is NOT enough: Redis then creates a fresh empty AOF on startup and loads that instead
of `dump.rdb`, coming up with `dbsize 0` and no error at all. The working sequence
temporarily disables AOF, loads the RDB, verifies, then re-enables AOF:

```bash
# 1. Stop the writers — the-button uses selfHeal: true, so work quickly.
#    Argo restores replicas within its reconcile window.
kubectl --context algovn-remote -n the-button scale deploy the-button-service --replicas=0
kubectl --context algovn-remote -n the-button scale deploy the-button-worker --replicas=0

# 2. Record the authoritative counter:global from the in-cluster Redis, then SAVE
#    and copy dump.rdb to the VM.
kubectl --context algovn-remote -n redis exec redis-0 -c redis -- \
  sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning get counter:global'
# → 79 (record this number)
kubectl --context algovn-remote -n redis exec redis-0 -c redis -- \
  sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning save'
kubectl --context algovn-remote -n redis cp redis-0:/data/dump.rdb /tmp/redis-dump.rdb -c redis
scp /tmp/redis-dump.rdb data:/tmp/dump.rdb

# 3. Load on the VM — this is the sequence that actually works.
#    Stopping first avoids the conflict between systemd's Type=notify and a DB swap.
ssh data 'sudo systemctl stop redis-server'
ssh data 'sudo rm -rf /var/lib/redis/appendonlydir /var/lib/redis/appendonly.aof'
ssh data 'sudo cp /tmp/dump.rdb /var/lib/redis/dump.rdb && sudo chown redis:redis /var/lib/redis/dump.rdb'
ssh data 'sudo sed -i "s/^appendonly yes/appendonly no/" /etc/redis/redis.conf'
ssh data 'sudo systemctl start redis-server'

# 4. Verify — this is the gate. A mismatch means redo the copy.
ssh data 'sudo redis-cli -a "$(sudo grep ^requirepass /etc/redis/redis.conf | cut -d" " -f2)" --no-auth-warning get counter:global'
# → must match the recorded value exactly
ssh data 'sudo redis-cli -a "$(sudo grep ^requirepass /etc/redis/redis.conf | cut -d" " -f2)" --no-auth-warning dbsize'
# → 22

# 5. Re-enable AOF — write the AOF from the in-memory dataset, then persist in config.
ssh data 'sudo redis-cli -a "$(sudo grep ^requirepass /etc/redis/redis.conf | cut -d" " -f2)" --no-auth-warning config set appendonly yes'
ssh data 'sudo sed -i "s/^appendonly no/appendonly yes/" /etc/redis/redis.conf'
```

The RDB load takes under a second. The counter verification is the safety net — if
Argo restarted the writers mid-copy, the counter will differ.

### Cutover

Strip the selector from `platform/redis/manifests/service.yaml` (leave both ports —
6379 named `redis` and 9121 named `metrics`, since the exporter now runs on the VM),
add `endpoints.yaml` against `192.168.102.114`, delete `statefulset.yaml`, update
`kustomization.yaml`, and add `192.168.102.114:9121` to
`platform/monitoring/manifests/vmstaticscrape-stateful-vms.yaml`. Push, hard-refresh
Argo, verify `redis-0` is gone and the Service has no selector.

Expect a stale EndpointSlice from the pre-cutover pod — delete it:

```bash
kubectl --context algovn-remote delete endpointslice -n redis -l kubernetes.io/service-name=redis
# Wait for Argo to recreate it with the VM's IP, then verify only one:
kubectl --context algovn-remote get endpointslice -n redis -l kubernetes.io/service-name=redis
```

The in-cluster `VMServiceScrape` still selects the Service by its `app: redis` label
and discovers the VM's exporter through the manual Endpoints — so metrics keep flowing
without editing the scrape CR.

Restore the-button writers (Argo's selfHeal does this, but force it):

```bash
kubectl --context algovn-remote -n argocd annotate app the-button argocd.argoproj.io/refresh=hard
# Wait for sync, then remove the annotation:
kubectl --context algovn-remote -n argocd annotate app the-button argocd.argoproj.io/refresh-
kubectl --context algovn-remote -n the-button get deploy  # expect the-button-service 2/2, the-button-worker 1/1
```

**Rollback** — app `redis`, PV `pvc-4257dfb4-f4cc-4428-ba8f-413d21bf82a0`, PVC
`data-redis-0` in ns `redis`. Follow "Rollback — rebind the surviving `Retain` PV"
under Cutover mechanics. Step 1 is restoring `statefulset.yaml`, reverting the Service
(put `selector: { app: redis }` back) and removing `endpoints.yaml` from
`kustomization.yaml`. The PVC survived the cutover (volumeClaimTemplates PVCs are not
deleted with the StatefulSet); the PV was already patched to `Retain`.

A rollback to the in-cluster instance loses any writes made since the cutover.
`counter:global` will be behind — there is no replication between the two.

Debug: `systemctl status redis-server` / `journalctl -u redis-server -n 50` on the VM;
`redis-cli -a "$PW" --no-auth-warning ping` there; from a k3s node,
`redis-cli -h 192.168.102.114 -a "$PW" --no-auth-warning ping`.

## Tempo

Runs on algovn-data as a podman quadlet (ansible role `tempo`, tag `tempo`), config at
`/etc/tempo/tempo.yaml`, WAL at `/var/tempo`, listening on **:3200** (HTTP query),
**:4317** (OTLP gRPC) and **:4318** (OTLP HTTP). S3-backed against the VM's own MinIO
at `localhost:9000`, bucket `tempo`, 72 h retention — same settings the Helm chart had.

In-cluster, `tempo.tracing.svc:3200` / `:4317` / `:4318` is a **selector-less Service +
Endpoints** (`platform/tracing/manifests/`) pointing at `192.168.102.114`. Grafana's
Tempo datasource and every service's OTLP exporter keep working unchanged.

Moved to algovn-data rather than algovn-obs because it is S3-backed against MinIO and a
VM-hosted Tempo cannot resolve cluster DNS or reach a ClusterIP. With both on the same VM
and `Network=host`, the S3 endpoint is `localhost:9000`.

**No data migration was needed** — blocks live in the `tempo` bucket, which the MinIO
cutover mirrored. Existing history was preserved.

Tempo reads the same OpenBao entry as MinIO's root credentials (`algovn/radio-lab/minio`,
properties `username`/`password`), so it authenticates as root — matching radio-service
and tts-service (the-race is the only one with its own MinIO identity).

**Rollback** — app `tracing`, PV and PVC are chart-managed. Follow "Rollback — rebind
the surviving `Retain` PV" under Cutover mechanics if the PVC was pruned. Step 1 is
restoring the tempo chart source in `clusters/algovn/platform/tracing.yaml`.

Debug: `systemctl status tempo` / `journalctl -u tempo -n 50` on the VM;
`curl localhost:3200/ready` there; from a k3s node,
`curl http://192.168.102.114:3200/ready`.
