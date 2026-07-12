# Secrets
## Seal a new secret
kubectl create secret generic NAME -n NS --from-literal=k=v --dry-run=client -o yaml | scripts/seal.sh > <dir>/name-sealed.yaml
Plaintext staging: ~/.secrets/ (chmod 700), `shred -u` after. NEVER commit plaintext (gitleaks enforces;
`.gitleaks.toml` allowlists only `*-sealed.yaml` — keep that naming convention).
⚠️ Strip trailing newlines from token files before sealing (`tr -d "[:space:]"`) — cert-manager
rejects Cloudflare tokens containing a newline, and `curl` verification won't catch it.
## Backup sealing key (after install or key rotation)
kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > ~/.secrets/key.yaml
→ password manager (secure note "algovn sealed-secrets key") → `shred -u ~/.secrets/key.yaml`
## Restore sealing key (during bootstrap step 3)
Save the password-manager note to ~/.secrets/key.yaml, then:
kubectl create namespace sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ~/.secrets/key.yaml && shred -u ~/.secrets/key.yaml
kubectl -n sealed-secrets delete pod -l app.kubernetes.io/name=sealed-secrets 2>/dev/null || true
## Argo CD admin password rotation
Do NOT use `argocd login` via port-forward (gRPC breaks the forward on this box).
Use `~/rotate-argocd-pw.sh` on the Pi: bcrypts locally, patches argocd-secret,
verifies via REST /api/v1/session. Source of the script: plan Task 5 §7 deviation notes.
## Not sealed (password manager only)
Argo CD admin pw, Grafana admin pw (sealed grafana-admin secret holds it, but keep a copy),
uptime-kuma admin, Cloudflare account creds.
## Inventory of sealed secrets
cert-manager/cloudflare-api-token · external-dns/cloudflare-api-token · cloudflared/tunnel-credentials ·
monitoring/grafana-admin (alertmanager-config not sealed — Telegram alerting skipped 2026-07-12)
