# Full rebuild (dead VM / fresh Proxmox) — target < 1 hour
Host: Proxmox VE at 192.168.102.100. Root of trust: OpenBao in LXC 124 (`bao`, .124) —
if IT is gone too, restore its vzdump backup first (or re-run the populate flow; see
the OpenBao design doc in the archive). Needs from password manager: openbao init.json
copy, Argo admin pw, zitadel-iam-admin-sa-pat.
1. Clone VMs from template 9000 (`ubuntu-noble-tpl`, ciuser ducle): `algovn`
   (VMID 111, .111, 4c/8G/40G) and `algovn-w1` (VMID 112, .112, 8c/16G/150G),
   `--cpuunits 2048 --onboot 1`; start.
2. Rebuild the stateful-service VMs too — `algovn-data` (VMID 114, .114) and
   `algovn-obs` (VMID 115, .115) — per "Build (or rebuild) the VMs" in
   docs/runbooks/stateful-vms.md, including the `~/.ssh/config` stanzas that give
   `ssh data` / `ssh obs` their ProxyJump. They must exist before step 4:
   `site.yml` is `hosts: all`, so the same run provisions them, and it fails
   UNREACHABLE if they do not answer. **algovn-obs is not optional.** Argo will
   recreate selector-less Services for `loki` and `uptime-kuma` whose Endpoints
   point at 192.168.102.115, and a Service with no live backend still reports
   Synced/Healthy — skip this and logging, uptime monitoring and metrics are
   silently dead with nothing red anywhere to say so.
3. ufw on BOTH k3s VMs first (hand-managed, NOT ansible — agents silently fail to
   join without it): allow 6443/tcp, 10250/tcp, 8472/udp from 192.168.102.0/24,
   limit 22/tcp, allow 80,443/tcp, enable. (ufw on the two stateful VMs is
   ansible-managed instead — see stateful-vms.md.)
4. On the Mac: `cd ~/the-algovn/iac/ansible && ansible-playbook site.yml --skip-tags cloudflared`
   — Traefik is disabled in the k3s config; Kong is the gateway.
5. kubeconfig on server VM: `sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown ducle: ~/.kube/config && chmod 600 ~/.kube/config`.
6. Host tunnels (docs/runbooks/remote-access.md): creds
   `~/.secrets/cloudflared/{algovn-cp,algovn-w1}.json` on the MAC (ansible controller);
   if lost, recreate tunnels + `route dns --overwrite-dns`. Then
   `ansible-playbook site.yml --tags cloudflared`.
7. Refresh Mac kubeconfig (new cluster CA): extract ca/cert/key from the server's
   k3s.yaml into context `algovn-remote` (server https://127.0.0.1:16443).
8. Bootstrap: docs/runbooks/bootstrap.md — run from the Mac over the k8s-tunnel;
   the ESO approle secret is the only manual secret step.
9. Zitadel content is NOT backed up — re-bootstrap per docs/runbooks/zitadel.md
   (bootstrap admin password: bao `algovn/zitadel/bootstrap-admin`), incl. §11:
   new OIDC client ids → update platform/monitoring/values.yaml +
   platform/argocd/patches/oidc-cm.yaml, write the new grafana client secret to bao
   `algovn/monitoring/grafana-oauth`. Also incl. §12: new `internal-tool` /
   `redisinsight` client id → update `--client-id` in
   platform/redisinsight/manifests/oauth2-proxy-deployment.yaml, write the new
   client secret to bao `algovn/redisinsight/oauth`.
10. Re-check Cloudflare Access apps (docs/runbooks/cloudflare-access.md).
11. Stateful volumes are split since phase 2. Postgres, Redis, MinIO, Redpanda and
    Tempo still hold `local-path` volumes on algovn-w1, and a full rebuild recreates
    the `pg` cluster EMPTY — see docs/runbooks/postgres.md. Loki, uptime-kuma and
    VictoriaMetrics do NOT: their data lives on algovn-obs (step 2) and survives a
    k3s rebuild untouched. Phase 3 moves the remaining five to algovn-data/-obs and
    empties this list.
12. Run docs/runbooks/verify.md.
