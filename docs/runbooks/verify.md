# Verify (run after bootstrap, rebuild, or platform change)
Run on the Pi with `export KUBECONFIG=$HOME/.kube/config`.
1. `argocd app list --core` → every app Synced + Healthy.
2. `kubectl get nodes` → all Ready. `kubectl get pods -A | grep -Ev 'Running|Completed'` → empty.
3. Public path: `curl -s -o /dev/null -w '%{http_code}' https://homepage.algovn.com/` → 200.
4. Access: `curl -s -o /dev/null -w '%{http_code}' https://argocd.algovn.com/` → 302 (challenge).
5. LAN TLS: `curl -s --resolve x.algovn.com:443:192.168.102.200 https://x.algovn.com -o /dev/null -w '%{http_code}'` → 404 from Kong, valid cert (no cert error).
5a. No Traefik: `kubectl get pods -A | grep -iE 'traefik'` → empty; `svclb-kong-gateway-proxy` owns node 80/443.
6. Grafana: dashboards show live node metrics; Explore→Loki `{namespace="argocd"}` returns lines.
7. Alert rules: vmalert evaluates platform-custom rules (Telegram delivery skipped by decision
   2026-07-12 — alerts visible in Grafana/vmalert only). Check: no ArgoAppNotSynced/Unhealthy firing.
8. Drift test: `kubectl -n homepage scale deploy homepage --replicas=3`; within ~5 min replicas back to 1.
9. `free -h` → available ≥ 400Mi (Kong-era budget, spec §7.6 of the kong design).
10. uptime-kuma monitors all green.
11. Existing production tunnel untouched: `portainer.algovn.com`, `ssh.algovn.com`,
    `the-button-api.algovn.com`, `the-song-api.algovn.com` still CNAME to tunnel
    15675449-… (NOT the cluster tunnel cb033e8e-…).
Note: the Pi kubeconfig's default namespace is `argocd` — ad-hoc `kubectl run` pods land there unless you pass `-n`.
