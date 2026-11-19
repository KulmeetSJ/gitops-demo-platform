#!/usr/bin/env bash
# Generates a random DB password for one environment and writes it as a SealedSecret.
# Only the encrypted form is ever written to disk; the plaintext lives in a pipe.
set -euo pipefail
ENV="${1:?usage: seal-db-secret.sh <dev|staging|prod>}"
[[ "$ENV" =~ ^(dev|staging|prod)$ ]] || { echo "unknown env: $ENV" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/envs/$ENV/secrets/db-sealedsecret.yaml"

PASSWORD="$(openssl rand -hex 24)"
kubectl create secret generic gitops-demo-app-db --namespace "$ENV" \
    --from-literal=username=accounts --from-literal=password="$PASSWORD" \
    --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system \
      --scope strict --format yaml > "$OUT"
echo "wrote $OUT"
