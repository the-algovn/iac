# Stateful services on dedicated VMs

All stateful workloads are migrating off k3s onto two Proxmox VMs. Design:
`~/the-algovn/archive/iac/specs/2026-08-04-stateful-services-vm-migration-design.md`
(archive is local-only, not in git).

| VM | VMID | IP | vCPU | RAM | disk | holds |
|---|---|---|---|---|---|---|---|
| algovn-data | 114 | 192.168.102.114 | 16 | 32G | 100G | postgres, redis, minio, redpanda |
| algovn-obs | 115 | 192.168.102.115 | 4 | 8G | 64G | victoria-metrics, loki, tempo, uptime-kuma |

## PV reclaim policy -- do not revert

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
but the PV will NOT rebind to a new claim of the same name -- it must be deleted
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

Reach them with `ssh data` / `ssh obs` (ProxyJump through `cp`; the laptop is not
on the cluster LAN).

## Firewall

ufw is ansible-managed on these VMs (unlike the k3s nodes, where it is hand-managed
because it must exist before the agent joins). Rules come from
`ansible/group_vars/{data,obs}.yml`:

- `firewall_node_ports` -- reachable ONLY from the three k3s node IPs. Pods SNAT to
  their node, so those are the only legitimate in-cluster sources.
- `firewall_lan_ports` -- reachable from the whole LAN. Currently 5432 (the
  deliberate psql/DBeaver admin path from postgres.md) and 9001 (MinIO console).

To open a port for a new service, add it to the group var and re-run
`ansible-playbook site.yml --limit data,obs --tags firewall`. Do not run `ufw` by
hand -- it will be reverted on the next play.

Redpanda has no authentication, so the node-IPs-only rule is the entirety of its
access control. If it ever needs wider reach, enable SASL first rather than
widening the ufw rule.

Locked out? Recover from the Proxmox serial console: `ssh pve 'qm terminal 114'`,
then `sudo ufw disable`.

## Containers (quadlets)

MinIO, Redpanda, VictoriaMetrics, Loki, Tempo and uptime-kuma run as podman
**quadlets** — `*.container` files in `/etc/containers/systemd/` that
`podman-system-generator` turns into real systemd units at `daemon-reload`. So
`systemctl status loki` and `journalctl -u loki` work normally, and upgrades are a
pinned-tag bump in the role, matching how the Helm values pinned them before.

Postgres and Redis are NOT containers — they are native apt packages (PGDG and
redis.io repos), because the database benefits from `pg_upgradecluster`, unattended
security updates and the standard /etc/postgresql layout.

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

Then remove the file and `daemon-reload` again.
