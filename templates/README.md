# Onboarding an app to the cluster (push-to-deploy)

1. **App repo**: copy `github-actions-build-push.yaml` to `.github/workflows/build.yaml`.
   Ensure a `Dockerfile` exists. Push a `vX.Y.Z` tag → image at `ghcr.io/<org>/<repo>`.
2. **Make the GHCR package public** (repo → Packages → settings) or seal a pull secret.
3. **This repo**: create `apps/<name>/` (Deployment/Service/Ingress + kustomization —
   copy `apps/homepage/` as the model) and `clusters/algovn/apps/<name>.yaml`
   Application. Host `<name>.algovn.com` gets DNS + tunnel automatically.
4. **Auto-update on new images**: add to the Application `metadata.annotations`:
       argocd-image-updater.argoproj.io/image-list: app=ghcr.io/<org>/<repo>
       argocd-image-updater.argoproj.io/app.update-strategy: semver
       argocd-image-updater.argoproj.io/write-back-method: git
   One-time (first app only): give image-updater push access — create a GitHub
   fine-grained PAT (this repo, Contents RW), then:
       kubectl create secret generic git-creds -n argocd \
         --from-literal=username=mduclehcm --from-literal=password=<PAT> \
         --dry-run=client -o yaml | scripts/seal.sh > platform/image-updater/git-creds-sealed.yaml
   Add it to a kustomization synced by the image-updater Application, and set
   `config.gitCredentials` in `platform/image-updater/values.yaml` per chart docs.
5. Merge. `argocd app wait <name> --core` → live at `https://<name>.algovn.com`.
