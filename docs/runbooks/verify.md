# Verify (run after bootstrap, rebuild, or platform change)
Run from the Mac: k8s-tunnel up, `kubectl config use-context algovn-remote`.
1. `argocd app list --core` → every app Synced + Healthy.
2. `kubectl get nodes` → all Ready. `kubectl get pods -A | grep -Ev 'Running|Completed'` → empty.
3. Public path: `curl -s -o /dev/null -w '%{http_code}' https://algovn.com/` → 200.
4. Argo CD: no longer Access-gated — `curl -s -o /dev/null -w '%{http_code}' https://argocd.algovn.com/` → `200`; SSO checked in the AuthN/Z section below.
5. LAN TLS: `curl -s --resolve x.algovn.com:443:192.168.102.112 https://x.algovn.com -o /dev/null -w '%{http_code}'` → 404 from Kong, valid cert (no cert error).
   Must target the node running the kong-gateway pod (w1): cross-node LB traffic is
   masqueraded into the pod CIDR, which the kong NetworkPolicy deliberately blocks
   (it's the CF-Connecting-IP anti-spoofing boundary — trusted_ips is 10.42.0.0/16).
5b. Secrets: `kubectl get externalsecrets -A` → all Ready=True; `kubectl get clustersecretstore bao` → Valid.
5a. No Traefik: `kubectl get pods -A | grep -iE 'traefik'` → empty; `svclb-kong-gateway-proxy` owns node 80/443.
6. Grafana: dashboards show live node metrics; Explore→Loki `{namespace="argocd"}` returns lines.
7. Alert rules: vmalert evaluates platform-custom rules (Telegram delivery skipped by decision
   2026-07-12 — alerts visible in Grafana/vmalert only). Check: no ArgoAppNotSynced/Unhealthy firing.
8. Drift test: `kubectl -n landing scale deploy landing --replicas=3`; within ~5 min replicas back to 1.
9. `free -h` → available ≥ 400Mi (Kong-era budget, spec §7.6 of the kong design).
10. uptime-kuma monitors all green.
11. Legacy tunnel `algovn` (15675449-…, old Pi production: portainer/the-button-api/
    the-song-api/ssh) is DEFUNCT since 2026-07-15 — hostnames dead pending cleanup;
    just confirm nobody re-created it.
12. cloudflared host tunnels: `ssh cp "systemctl is-active cloudflared-algovn-cp"` /
    `ssh w1 "systemctl is-active cloudflared-algovn-w1"` → active; after Access apps
    exist, each of ssh-cp/ssh-w1/k8s.algovn.com must curl → 302.
Note: the algovn-remote context's default namespace is `argocd` — ad-hoc `kubectl run` pods land there unless you pass `-n`.

## AuthN/Z (spec 2026-07-13)
- `curl -s https://id.algovn.com/.well-known/openid-configuration | jq -r .issuer` → `https://id.algovn.com`
- Login page renders: https://id.algovn.com/ui/v2/login (passkey/social only — no password field)
- Edge gate: any `konghq.com/plugins: jwt-auth` route → 401 bare / 200 with fresh JWT-type token
- OpenFGA: in-cluster grpcurl health check == SERVING (needs bearer for reflection; see authnz-conventions.md)
- Grafana dashboard "AuthN/Z" renders with live data; `up{namespace=~"zitadel|openfga"}` all 1
- Grafana SSO: `curl -s -o /dev/null -w '%{redirect_url}' https://grafana.algovn.com/login/generic_oauth` starts with `https://id.algovn.com/oauth/v2/authorize`; passkey login lands as Admin; `/login?disableAutoLogin` + grafana-admin = break-glass
- Argo CD SSO: `curl -s https://argocd.algovn.com/api/v1/settings | jq -r .oidcConfig.issuer` → `https://id.algovn.com`; UI "Log in via AlgoVN ID" → passkey → admin; local admin login = break-glass; `argocd login argocd.algovn.com --sso --grpc-web` works
