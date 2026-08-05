# Remote access — SSH + kubectl over internet (cloudflared host tunnels)

**Exactly three tunnels exist** (consolidated 2026-08-04). Two are host-level and
independent of the cluster, so SSH keeps working when k3s is down; the third is the
in-cluster tunnel that fronts every public HTTP hostname via Kong.

| Hostname            | Tunnel     | Unit / workload                 | Target                    |
|---------------------|------------|---------------------------------|---------------------------|
| ssh-cp.algovn.com   | algovn-cp  | cloudflared-algovn-cp.service   | algovn VM localhost:22    |
| k8s.algovn.com      | algovn-cp  | cloudflared-algovn-cp.service   | algovn VM localhost:6443  |
| pve.algovn.com      | algovn-pve | cloudflared-algovn-pve.service  | PVE host :8006 (web UI)   |
| ssh-pve.algovn.com  | algovn-pve | cloudflared-algovn-pve.service  | PVE host localhost:22     |
| algovn.com + *.algovn.com | algovn-k8s | Deployment cloudflared/cloudflared (2 replicas) | Kong gateway |

`algovn-cp` is ansible-managed (`ansible/roles/cloudflared`, tag `cloudflared`); the
role only runs for a host that defines `cloudflared_tunnel` in `ansible/inventory.yml`.

`algovn-pve` runs on the Proxmox HOST and is hand-managed (the host is outside the
ansible inventory): config `/etc/cloudflared/algovn-pve.yml`, unit
`cloudflared-algovn-pve.service`. ⚠️ Its hostnames MUST stay behind Cloudflare Access
(the PVE web UI is root on everything) — if the Access app is ever missing, stop the
unit first, fix the app, then start it.

## Worker nodes have NO tunnel — jump through the control plane
`algovn-w1` and `algovn-w2` tunnels were deleted 2026-08-04, along with the
`ssh-w1`/`ssh-w2` hostnames. Reach the workers by jumping through `cp`, which works
identically on and off the cluster LAN:

    Host w1
      HostName 192.168.102.112
      User ducle
      ProxyJump cp

Do NOT re-add `cloudflared_tunnel` to the agents in `ansible/inventory.yml` — that
host var is the only thing that makes the cloudflared role run, so its absence is
what keeps the tunnels gone.

## TrueNAS services go through Kong, not their own tunnel
The `algovn-nas` tunnel (which ran inside the TrueNAS VM) was deleted 2026-08-04 and
`nas.algovn.com` was removed from the `algovn-pve` config. Everything TrueNAS-hosted
now enters through `algovn-k8s` → Kong, using a selector-less Service plus a manual
`Endpoints` object pointing at `192.168.102.18`:

| Hostname          | App dir       | Origin                    |
|-------------------|---------------|---------------------------|
| photos.algovn.com | `apps/photos` | Immich, `.18:30041`       |
| xvideo.algovn.com | `apps/xvideo` | Jellyfin, `.18:30013`     |
| nas.algovn.com    | `apps/nas`    | TrueNAS UI, `.18:443` (HTTPS upstream — needs `konghq.com/protocol: https` on the Service) |

⚠️ This makes Kong (currently `replicaCount: 1`) a single point of failure for the
NAS UI. Break-glass is the Proxmox console at `pve.algovn.com`, on the separate
hand-managed tunnel.

⚠️ Argo CD excludes `Endpoints`/`EndpointSlice` by default, which silently skips these
objects and leaves Kong answering 503 while the Application still reads Synced —
`platform/argocd/patches/exclusions-cm.yaml` re-includes them. Don't drop that patch.

## Access gating (verified 2026-08-04)
`pve`, `ssh-pve`, `ssh-cp`, `k8s` all 302 to `the-thing-universe.cloudflareaccess.com`.
`nas.algovn.com` and `photos.algovn.com` are NOT Access-gated — they rely on the
TrueNAS and Immich logins respectively. See cloudflare-access.md.

## Client (Mac)
- `ssh cp` / `ssh pve` — ProxyCommand via `cloudflared access ssh` in ~/.ssh/config.
- `ssh w1` / `ssh w2` — ProxyJump through `cp` (no tunnel of their own).
- kubectl: run `k8s-tunnel` (fish function, local listener 127.0.0.1:16443), then
  `kubectl --context algovn-remote ...` in another terminal.

## Provisioning / rebuild
1. Credentials: `~/.secrets/cloudflared/{algovn-cp,algovn-pve}.json` on the MAC (the
   ansible controller; the cloudflared role copies them to nodes) — NOT in git. If
   lost: delete + recreate tunnels (`cloudflared tunnel delete <t>`, `create <t>`,
   re-copy JSON) — recreating yields a NEW tunnel ID, so plain `route dns` fails
   ("record already exists"); re-point existing hostnames with
   `cloudflared tunnel route dns --overwrite-dns <t> <hostname>`. Needs
   `~/.cloudflared/cert.pem`; if that's lost too: `cloudflared tunnel login`.
2. `cd ~/the-algovn/iac/ansible && ansible-playbook site.yml --tags cloudflared`
3. Re-check Access apps (cloudflare-access.md) — they live only in Cloudflare.

## Debugging
- Node side: `systemctl status cloudflared-<tunnel>`, `journalctl -u cloudflared-<tunnel> -n 50`
  — healthy log shows ≥1 "Registered tunnel connection".
- Account view: `cloudflared tunnel list` / `cloudflared tunnel info <t>` from the Mac.
  `tunnel info` prints each connector's ORIGIN IP — on this LAN those are EUI-64 IPv6
  addresses, so `2405:…:be24:11ff:feXX:YYZZ` decodes to MAC `bc:24:11:XX:YY:ZZ`, which
  `qm config <vmid>` matches to a VM. That is how a tunnel's host is identified.
- `curl https://<host>/` → 302 to the Access login means gated; 200 = no gate.
- Kong route not working? Check the EndpointSlices for the Service
  (`kubectl get endpointslice -n <ns> -l kubernetes.io/service-name=<svc>`); a 503
  with a Synced Application means there is no ready backend. Use `endpointslice`,
  not the deprecated `endpoints` — a stale slice left by a cutover is invisible
  through the old API.
