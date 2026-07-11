#!/usr/bin/env bash
# Usage: kubectl create secret generic NAME -n NS --from-... --dry-run=client -o yaml | scripts/seal.sh
set -euo pipefail
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets --format yaml
