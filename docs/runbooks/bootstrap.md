# Bootstrap (fresh cluster from this repo)
Run from the Mac: nodes provisioned (`ansible/`), k8s-tunnel up, `kubectl config use-context algovn-remote`, argocd CLI installed. OpenBao (LXC 124 on the Proxmox host) must be up and unsealed.
1. `kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -`
2. `kubectl apply -k bootstrap/ --server-side` — then wait for CRDs and apply AGAIN (the
   Application CRs need the CRDs established; plain client-side apply fails on the
   applicationsets CRD annotation size):
   `kubectl wait --for condition=established crd/applications.argoproj.io crd/applicationsets.argoproj.io --timeout=60s && kubectl apply -k bootstrap/ --server-side`
3. CREATE THE ESO APPROLE SECRET (docs/runbooks/secrets.md §bootstrap) — do this BEFORE
   waves need secrets; it is the only manual secret step.
4. `kubectl -n argocd rollout status deploy/argocd-server --timeout=300s`
5. Watch convergence: `argocd app list --core` until all Synced/Healthy (external-secrets first, waves -5→1).
   Always use `--core`: gRPC logins through kubectl port-forward do NOT work
   (pod RSTs kill the forward). Plain HTTP through a port-forward is fine.
   Note: CNPG managed roles can miss ESO-created password secrets that appear after its
   first reconcile — if roles sit in `pending-reconciliation`, nudge with:
   `kubectl -n postgres annotate cluster pg algovn.com/reconcile-nudge=$(date +%s) --overwrite`
   (same trick for a stale ClusterIssuer: annotate it).
6. Run docs/runbooks/verify.md.
