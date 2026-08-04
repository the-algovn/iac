# Remote access — SSH + kubectl over internet (cloudflared host tunnels)

One host-level tunnel per node VM, ansible-managed (`ansible/roles/cloudflared`,
tag `cloudflared`), independent of the cluster — SSH keeps working when k3s is down.
⚠️ Distinct from BOTH the in-cluster `algovn-k8s` tunnel (HTTP apps) and the legacy
tunnel `algovn` (DEFUNCT since the Pi was retired 2026-07-15; hostnames dead pending
cleanup) — never reuse either name.

| Hostname            | Tunnel     | Unit (on node)                 | Target                   |
|---------------------|------------|--------------------------------|--------------------------|
| ssh-cp.algovn.com   | algovn-cp  | cloudflared-algovn-cp.service  | algovn VM localhost:22   |
| k8s.algovn.com      | algovn-cp  | cloudflared-algovn-cp.service  | algovn VM localhost:6443 |
| ssh-w1.algovn.com   | algovn-w1  | cloudflared-algovn-w1.service  | w1 VM localhost:22       |
| ssh-w2.algovn.com   | algovn-w2  | cloudflared-algovn-w2.service  | w2 VM localhost:22       |
| pve.algovn.com      | algovn-pve | cloudflared-algovn-pve.service | PVE host :8006 (web UI)  |
| ssh-pve.algovn.com  | algovn-pve | cloudflared-algovn-pve.service | PVE host localhost:22    |
| (hostnames TBD)     | algovn-nas | (unknown — see below)          | TrueNAS VM 125 (.18)     |

`algovn-pve` runs on the Proxmox HOST and is hand-managed (the host is outside the
ansible inventory): config `/etc/cloudflared/algovn-pve.yml`, unit
`cloudflared-algovn-pve.service`. ⚠️ Its hostnames MUST stay behind Cloudflare Access
(the PVE web UI is root on everything) — if the Access app is ever missing, stop the
unit first, fix the app, then start it.

`algovn-nas` (ID `8ae0b768-4b07-4869-9342-a412e9febca4`, created 2026-08-01) is a
THIRD hand-managed tunnel, and it is **not on the PVE host and not in the ansible
inventory** — it runs inside the **TrueNAS VM** (VMID 125, `192.168.102.18`). Verified
2026-08-04 from `cloudflared tunnel info`: the connector's origin IP
`2405:…:be24:11ff:fe8a:6515` is EUI-64-derived from MAC `bc:24:11:8a:65:15`, which
`qm config 125` confirms is that VM's `net0`. Its hostnames, config path and unit name
are NOT recorded here because TrueNAS has no QEMU guest agent (`qm guest exec` fails)
and nothing in this repo manages it — fill them in from the TrueNAS side. Until then,
treat this row as a known documentation gap, not as an absent tunnel.

⚠️ Access gate PENDING (as of 2026-07-13): the three Access apps (email OTP,
admin-only) are not yet created — until then the endpoints rely on SSH key auth /
k8s client certs alone. Create them per cloudflare-access.md, then verify each
hostname 302-redirects to the Access login.

## Client (Mac)
- `ssh cp` / `ssh w1` / `ssh w2` — ProxyCommand via `cloudflared access ssh` in ~/.ssh/config;
  first use per 24h session pops a browser OTP (once the Access apps exist; until
  then it connects directly).
- kubectl: run `k8s-tunnel` (fish function, local listener 127.0.0.1:16443), then
  `kubectl --context algovn-remote ...` in another terminal.

## Provisioning / rebuild
1. Credentials: `~/.secrets/cloudflared/{algovn-cp,algovn-w1,algovn-w2}.json` on the MAC (the
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
- Account view: `cloudflared tunnel list` / `cloudflared tunnel info <t>` (on the Pi).
- OTP email not arriving → cloudflare-access.md.
- `curl https://<host>/` → must 302 to the Access login; 200 = gate missing.
