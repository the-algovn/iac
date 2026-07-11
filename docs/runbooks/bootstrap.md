# Bootstrap (fresh cluster from this repo)
Pre-req: node provisioned (`ansible/`), kubeconfig at ~/.kube/config (`export KUBECONFIG=$HOME/.kube/config` — the k3s kubectl shim otherwise wants root's /etc/rancher/k3s/k3s.yaml), kubeseal + argocd CLIs.
1. `kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -`
2. `kubectl apply -k bootstrap/ --server-side` — then wait for CRDs and apply AGAIN (the
   Application CRs need the CRDs established; plain client-side apply fails on the
   applicationsets CRD annotation size):
   `kubectl wait --for condition=established crd/applications.argoproj.io crd/applicationsets.argoproj.io --timeout=60s && kubectl apply -k bootstrap/ --server-side`
3. RESTORE SEALING KEY (docs/runbooks/secrets.md §restore) — do this BEFORE waves need secrets.
4. `kubectl -n argocd rollout status deploy/argocd-server --timeout=300s`
5. Watch convergence: `argocd app list --core` until all Synced/Healthy (sealed-secrets first, waves -5→1).
   Always use `--core`: gRPC logins through kubectl port-forward do NOT work on this box
   (pod RSTs kill the forward). Plain HTTP through a port-forward is fine.
6. Run docs/runbooks/verify.md.
