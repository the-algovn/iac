# Onboarding an app to the cluster (push-to-deploy)

1. **App repo**: copy `github-actions-build-push.yaml` to `.github/workflows/build.yaml`.
   Ensure a `Dockerfile` exists. Push a `vX.Y.Z` tag → image at `ghcr.io/<org>/<repo>`.
2. **Make the GHCR package public** (repo → Packages → settings) or seal a pull secret.
3. **This repo**: create `apps/<name>/` (Deployment/Service/Ingress + kustomization —
   copy `apps/homepage/` as the model) and `clusters/algovn/apps/<name>.yaml`
   Application. Host `<name>.algovn.com` gets DNS + tunnel automatically.
4. **Auto-update on new images**: the installed updater (chart >=1.x) is CR-based —
   the legacy `argocd-image-updater.argoproj.io/*` Application annotations are inert.
   Add an `ImageUpdater` CR instead; model it on
   `platform/image-updater/showcase-updater.yaml`.
   One-time (first app only): give image-updater push access — create a GitHub
   fine-grained PAT (this repo, Contents RW), then:
       kubectl create secret generic git-creds -n argocd \
         --from-literal=username=mduclehcm --from-literal=password=<PAT> \
         --dry-run=client -o yaml | scripts/seal.sh > platform/image-updater/git-creds-sealed.yaml
   Add it to a kustomization synced by the image-updater Application, and set
   `config.gitCredentials` in `platform/image-updater/values.yaml` per chart docs.
5. Merge. `argocd app wait <name> --core` → live at `https://<name>.algovn.com`.

# Onboarding an internal gRPC service

1. Contracts first: add `algovn.<name>.v1` protos to `the-algovn/protos`, PR through its
   buf lint/breaking CI, tag; `go get github.com/the-algovn/protos/gen/go@<tag>`.
2. Copy `templates/grpc-service/` → `apps/<name>/`, replace NAME/NAMESPACE/IMAGE,
   add `clusters/algovn/apps/<name>.yaml` Application (same as any app).
3. Conventions (ports, health, deadlines, metrics): docs/grpc-conventions.md.
4. No Ingress, no DNS, no Kong — internal callers dial the headless service directly.
