# Onboarding an app to the cluster (push-to-deploy)

1. **App repo**: copy `github-actions-build-push.yaml` to `.github/workflows/build.yaml`.
   Ensure a `Dockerfile` exists. Push a `vX.Y.Z` tag → image at `ghcr.io/<org>/<repo>`.
2. **Make the GHCR package public** (repo → Packages → settings) or seal a pull secret.
3. **This repo**: create `apps/<name>/` (Deployment/Service/Ingress + kustomization —
   copy `apps/showcase/` as the model) and `clusters/algovn/apps/<name>.yaml`
   Application. Host `<name>.algovn.com` gets DNS + tunnel automatically.
4. **Auto-update on new images**: the installed updater (chart >=1.x) is CR-based —
   the legacy `argocd-image-updater.argoproj.io/*` Application annotations are inert.
   Add an `ImageUpdater` CR instead; model it on
   `platform/image-updater/showcase-updater.yaml`.
   One-time (first app only): give image-updater push access — create a GitHub
   fine-grained PAT (this repo, Contents RW), seal it, add the sealed git-creds file to
   `platform/image-updater/kustomization.yaml`, and reference it from the ImageUpdater CR's
   `writeBackConfig.method: git:secret:argocd/git-creds` (see `platform/image-updater/showcase-updater.yaml` for the pattern).
5. Merge. `argocd app wait <name> --core` → live at `https://<name>.algovn.com`.

**Rollback (digest-tracked apps)**: A git revert of an automatic digest-bump commit does NOT roll back
   the image — the updater re-commits the same digest within one poll cycle, and reverting to the bare
   `main` tag points at the same bad image. Real rollback: (a) revert the offending commit in the app repo
   and let CI roll forward (~5–10 min); or (b) to pin to a known digest, pause the updater first (remove
   the app's updater CR from `platform/image-updater/kustomization.yaml`), then set the desired digest
   in the app's kustomization `images:` entry. Both steps are git commits—never kubectl.

# Onboarding an internal gRPC service

1. Contracts first: add `algovn.<name>.v1` protos to `the-algovn/protos`, PR through its
   buf lint/breaking CI, tag; `go get github.com/the-algovn/protos/gen/go@<tag>`.
2. Copy `templates/grpc-service/` → `apps/<name>/`, replace NAME/NAMESPACE/IMAGE,
   add `clusters/algovn/apps/<name>.yaml` Application (same as any app).
3. Conventions (ports, health, deadlines, metrics): docs/grpc-conventions.md.
4. No Ingress, no DNS, no Kong — internal callers dial the headless service directly.
