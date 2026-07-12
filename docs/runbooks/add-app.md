# Add an app/service
See templates/README.md (full onboarding incl. CI + image automation).
Quick version (public image): copy apps/homepage/ → apps/<name>/, edit names/image/host,
add clusters/algovn/apps/<name>.yaml, `scripts/validate.sh`, push.
Ingresses use `ingressClassName: kong`; protect routes via `konghq.com/plugins` annotations
(see `docs/runbooks/kong.md`, Task 7).
DNS + tunnel + TLS are automatic from the Ingress host (external-dns routes every host to the
algovn-k8s tunnel via --force-default-targets). `argocd app wait <name> --core`.
