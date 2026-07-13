# Remote access — SSH + kubectl over internet (cloudflared host tunnels)

Two host-level tunnels, one per node, ansible-managed (`ansible/roles/cloudflared`,
tag `cloudflared`), independent of the cluster — SSH keeps working when k3s is down.
⚠️ Distinct from BOTH the in-cluster `algovn-k8s` tunnel (HTTP apps) and the Pi's
pre-existing production tunnel `algovn` / `cloudflared.service` (apex/portainer/ssh/…)
— never touch that one.

| Hostname            | Tunnel     | Unit (on node)                 | Target            |
|---------------------|------------|--------------------------------|-------------------|
| ssh-pi.algovn.com   | algovn-pi  | cloudflared-algovn-pi.service  | Pi localhost:22   |
| k8s.algovn.com      | algovn-pi  | cloudflared-algovn-pi.service  | Pi localhost:6443 |
| ssh-w1.algovn.com   | algovn-w1  | cloudflared-algovn-w1.service  | w1 localhost:22   |

⚠️ Access gate PENDING (as of 2026-07-13): the three Access apps (email OTP,
admin-only) are not yet created — until then the endpoints rely on SSH key auth /
k8s client certs alone. Create them per cloudflare-access.md, then verify each
hostname 302-redirects to the Access login.

## Client (Mac)
- `ssh pi` / `ssh w1` — ProxyCommand via `cloudflared access ssh` in ~/.ssh/config;
  first use per 24h session pops a browser OTP (once the Access apps exist; until
  then it connects directly).
- kubectl: run `k8s-tunnel` (fish function, local listener 127.0.0.1:16443), then
  `kubectl --context algovn-remote ...` in another terminal.
- Note: w1's OS hostname is ducle-pc (k3s node name algovn-w1) — ssh w1 hostname
  prints ducle-pc.

## Provisioning / rebuild
1. Credentials: `~ducle/.secrets/cloudflared/{algovn-pi,algovn-w1}.json` on the Pi —
   NOT in git. If lost: delete + recreate tunnels (`cloudflared tunnel delete <t>`,
   `create <t>`, re-copy JSON, re-run `route dns` for the hostnames above).
2. `cd ~/iac/ansible && ansible-playbook site.yml --tags cloudflared`
3. Re-check Access apps (cloudflare-access.md) — they live only in Cloudflare.

## Debugging
- Node side: `systemctl status cloudflared-<tunnel>`, `journalctl -u cloudflared-<tunnel> -n 50`
  — healthy log shows ≥1 "Registered tunnel connection".
- Account view: `cloudflared tunnel list` / `cloudflared tunnel info <t>` (on the Pi).
- OTP email not arriving → cloudflare-access.md.
- `curl https://<host>/` → must 302 to the Access login; 200 = gate missing.
