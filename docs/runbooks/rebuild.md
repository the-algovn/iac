# Full rebuild (dead Pi / fresh OS) — target < 1 hour
Needs from password manager: sealed-secrets key, Argo admin pw, Grafana admin pw.
1. Flash Ubuntu Server (arm64), hostname algovn, static IP 192.168.102.200, user ducle.
2. Clone this repo to ~/iac. Install ansible: `sudo apt install -y ansible`.
3. `cd ~/iac/ansible && ansible-playbook site.yml` — Traefik is disabled in the k3s config (`disable: [traefik]`); Kong is the gateway. Argo installs Kong; its default cert is the `Certificate` in namespace `kong`.
4. kubeconfig: `sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown ducle: ~/.kube/config && chmod 600 ~/.kube/config`
5. Follow docs/runbooks/bootstrap.md (includes key restore).
6. cloudflared account cert is NOT in git: if ~/.cloudflared/cert.pem lost, `cloudflared tunnel login`
   again (tunnel + its sealed credentials in git stay valid; login only re-authorizes the CLI).
   ⚠️ The cluster tunnel is **algovn-k8s** (cb033e8e-8bae-42b0-b0f7-858d35daec9c). The tunnel named
   `algovn` is a SEPARATE pre-existing production tunnel (host systemd cloudflared.service, serves
   apex/portainer/ssh/the-button-api/the-song-api) — never delete or reuse it for the cluster.
7. Re-check Cloudflare Access apps (docs/runbooks/cloudflare-access.md).
8. Accepted losses: metrics history, Loki logs, uptime-kuma history (recreate admin+monitors, Task 16 §3).
