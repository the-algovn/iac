#!/usr/bin/env bash
# Repo-wide validation: kustomize builds, schema checks, secret scan, workflow lint.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> kustomize build (all kustomizations)"
while IFS= read -r f; do
  d=$(dirname "$f")
  kustomize build "$d" > /dev/null || { echo "FAIL: kustomize build $d"; exit 1; }
  echo "ok: $d"
done < <(find . -name kustomization.yaml -not -path './.git/*')

echo "==> kubeconform (rendered kustomizations + raw manifest dirs)"
# ./schemas/ holds local overrides for CRDs where the community catalog (tracking
# upstream main) doesn't match our installed CRD version, e.g. ImageUpdater
# v1alpha1 (chart argocd-image-updater 1.2.4 lacks the catalog's spec.namespace).
# Checked in first so it wins over the catalog fallback for those Kinds only.
SCHEMAS=(-schema-location default
         -schema-location './schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
         -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')
while IFS= read -r f; do
  kustomize build "$(dirname "$f")" | kubeconform "${SCHEMAS[@]}" -ignore-missing-schemas -strict - \
    || { echo "FAIL: kubeconform $(dirname "$f")"; exit 1; }
done < <(find . -name kustomization.yaml -not -path './.git/*')
for dir in clusters; do
  [ -d "$dir" ] && find "$dir" -name '*.yaml' -not -name kustomization.yaml -print0 \
    | xargs -0 -r kubeconform "${SCHEMAS[@]}" -ignore-missing-schemas -strict
done

echo "==> actionlint"
if [ -d .github/workflows ]; then actionlint; fi
if [ -d templates ]; then
  find templates -maxdepth 1 -name 'github-actions-*.yaml' -print0 | xargs -0 -r actionlint
fi

echo "==> gitleaks"
gitleaks detect --no-banner --redact

echo "PASS"
