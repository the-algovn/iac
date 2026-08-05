# Stateful services on dedicated VMs

All stateful workloads are migrating off k3s onto two Proxmox VMs. Design:
`~/the-algovn/archive/iac/specs/2026-08-04-stateful-services-vm-migration-design.md`
(archive is local-only, not in git).

| VM | VMID | IP | vCPU | RAM | disk | holds |
|---|---|---|---|---|---|---|
| algovn-data | 114 | 192.168.102.114 | 16 | 32G | 100G | postgres, redis, minio, redpanda |
| algovn-obs | 115 | 192.168.102.115 | 4 | 8G | 64G | victoria-metrics, loki, tempo, uptime-kuma |

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

Smoke-test the mechanism after any podman upgrade:

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
from Phase 2 this VM runs MinIO, Redpanda, VictoriaMetrics, Loki, Tempo and
uptime-kuma as quadlets, `rm -af` force-removes RUNNING containers, and quadlet units
default to `Restart=no` — so a blanket teardown takes all six down until someone
restarts them by hand and re-pulls every image.

## Monitoring

Both VMs run `node_exporter` (ansible role `node_exporter`, tag `node_exporter`) on
**:9100**, opened to the k3s node IPs only. They are not cluster members, so there is
no Service or Pod for the operator to discover — targets are listed statically in
`platform/monitoring/manifests/vmstaticscrape-stateful-vms.yaml`, a `VMStaticScrape`
CR under Argo, job name **`stateful-vms`**. Phase 3 appends `postgres_exporter`
(9187) and `redis_exporter` (9121) to the same CR.

Check the targets are up:

    kubectl --context algovn-remote -n monitoring port-forward svc/vmsingle-vm 8428:8428
    # in another terminal:
    curl -sG 'http://localhost:8428/api/v1/query' \
      --data-urlencode 'query=up{job="stateful-vms"}' | jq '.data.result'

Expect two series, both `"1"`, for `192.168.102.114:9100` and `192.168.102.115:9100`.

Raw check from a k3s node, bypassing the cluster entirely:

    ssh w1 'curl -s -o /dev/null -w "%{http_code}\n" http://192.168.102.114:9100/metrics'   # 200

**If the targets never appear at all** (no series, not even `0`), the likely cause is
vmagent not selecting the CR rather than anything on the VMs:

    kubectl --context algovn-remote -n monitoring get vmagent -o jsonpath='{.items[*].spec.selectAllByDefault}'

If that is not `true`, vmagent only picks up CRs matching its explicit selectors and
this one is ignored silently — the VMs stay invisible with no error anywhere.

## Loki

Runs on algovn-obs as a podman quadlet (ansible role `loki`, tag `loki`), config at
`/etc/loki/loki.yaml`, data at `/var/lib/loki`, listening on **:3100**. Filesystem
storage, 168 h retention — same settings the Helm chart had.

In-cluster, `loki.logging.svc:3100` is a **selector-less Service + Endpoints**
(`platform/logging/manifests/`) pointing at `192.168.102.115`. That is why
`alloy`'s push URL and Grafana's Loki datasource were never edited — the name still
resolves. The loki Helm chart source was removed from
`clusters/algovn/platform/logging.yaml`; alloy remains a chart.

If logs stop flowing while the `logging` app reads Synced/Healthy, check
`kubectl get endpoints -n logging loki` FIRST. Argo excludes Endpoints by default and
`platform/argocd/patches/exclusions-cm.yaml` is what re-includes them.

Existing history was NOT migrated (168 h retention, and copying a live TSDB index
risks corrupting it).

### Argo prunes chart-managed PVCs

The PVC `storage-loki-0` was pruned by Argo along with the StatefulSet — a
**chart-managed PVC is pruned by Argo when the chart source is removed**. The later
cutovers (Postgres, MinIO, Redis) all follow the same "remove chart source, let Argo
prune" pattern and share this behaviour.

PV `pvc-819f5e0e-d1a0-4324-90a2-869219f8d80a` survives with
`persistentVolumeReclaimPolicy: Retain`, status `Released`, and 131 MB of data intact
at `/var/lib/rancher/k3s/storage/pvc-819f5e0e-d1a0-4324-90a2-869219f8d80a_logging_storage-loki-0`
on algovn-w1.

### Rollback

Reverting is NOT a one-line revert. The PVC must be recreated and bound to the
surviving PV before Argo can recreate the StatefulSet:

```bash
# 1. Restore the loki chart source in clusters/algovn/platform/logging.yaml and push.
# 2. Clear the PV's claimRef so a new PVC of the same name can bind it:
kubectl --context algovn-remote patch pv pvc-819f5e0e-d1a0-4324-90a2-869219f8d80a \
  -p '{"spec":{"claimRef":null}}'
# 3. Trigger a hard refresh — Argo may report Synced/Healthy without pruning
#    the manifests source or syncing the restored chart (see below):
kubectl --context algovn-remote -n argocd annotate app logging \
  argocd.argoproj.io/refresh=hard
# 4. Verify the new PVC bound the existing PV:
kubectl --context algovn-remote -n logging get pvc storage-loki-0
# Expected: STATUS=Bound, VOLUME=pvc-819f5e0e-…
# 5. Remove the annotation so Argo does not report perpetual drift:
kubectl --context algovn-remote -n argocd annotate app logging \
  argocd.argoproj.io/refresh-
```

The `claimRef` clear is the critical step — without it, the PV is `Released` and
cannot bind a new PVC even one with the same name; the StatefulSet sits Pending
forever.

### Argo hard-refresh after source changes

When the set of sources in an Argo Application changes (remove one chart, add a
`path` source), Argo may report `Synced/Healthy` while old resources from the
removed chart are still present. A `hard` refresh forces re-evaluation:

```bash
kubectl --context algovn-remote -n argocd annotate app logging \
  argocd.argoproj.io/refresh=hard
```

Once pruning completes, remove the annotation — a persistent `refresh` annotation
makes Argo report perpetual OutOfSync even when nothing drifted:

```bash
kubectl --context algovn-remote -n argocd annotate app logging \
  argocd.argoproj.io/refresh-
```

This is especially load-bearing when cutting over a database: a green app with
the old in-cluster instance still running means the old instance is still taking
writes, which for Postgres is a split brain.

Debug: `systemctl status loki` and `journalctl -u loki -n 50` on the VM;
`curl localhost:3100/ready` there; from a k3s node,
`curl http://192.168.102.115:3100/ready`.

## uptime-kuma

Runs on algovn-obs as a podman quadlet (ansible role `uptime_kuma`, tag
`uptime_kuma`), data at `/var/lib/uptime-kuma`, listening on **:3001**.

In-cluster, `uptime-kuma.uptime-kuma.svc:80` is a selector-less Service + Endpoints
(`apps/uptime-kuma/`) targeting `192.168.102.115:3001`. The `uptime.algovn.com`
Kong Ingress was not edited — it still points at that Service by name.

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
