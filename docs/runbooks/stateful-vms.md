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
