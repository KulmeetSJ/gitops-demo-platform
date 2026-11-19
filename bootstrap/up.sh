#!/usr/bin/env bash
# Bootstraps the local platform. After this, everything else is reconciled by Argo CD from Git.
set -euo pipefail

CLUSTER=gitops-demo
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARGOCD_CHART_VERSION=10.18.1
KEY_BACKUP="${SEALED_SECRETS_KEY_BACKUP:-$HOME/.config/gitops-demo/sealed-secrets-key.yaml}"

for t in docker kind kubectl helm; do
  command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --config "$ROOT/bootstrap/kind-config.yaml"
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

# Committed SealedSecrets are encrypted to the controller's key. Restore it (if we have one) BEFORE the
# controller starts, so a rebuilt cluster can still decrypt what is in Git.
if [[ -f "$KEY_BACKUP" ]]; then
  echo "Restoring Sealed Secrets key from $KEY_BACKUP"
  kubectl apply -n kube-system -f "$KEY_BACKUP" >/dev/null
fi

echo "Installing Argo CD $ARGOCD_CHART_VERSION"
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_CHART_VERSION" -n argocd --create-namespace \
  -f "$ROOT/bootstrap/values/argocd.yaml" --wait --timeout 10m >/dev/null

# App of apps: from here on, Git is the only way anything gets into the cluster.
kubectl apply -f "$ROOT/argocd/root.yaml" >/dev/null

echo "Waiting for platform components to become Healthy (first run pulls images, ~5-10 min)..."
platform_apps=(argo-rollouts kube-prometheus-stack kyverno sealed-secrets)
deadline=$((SECONDS + 1200))
for app in "${platform_apps[@]}"; do
  until [[ "$(kubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)" == "Synced/Healthy" ]]; do
    (( SECONDS > deadline )) && { echo "timed out waiting for $app" >&2; kubectl -n argocd get applications; exit 1; }
    sleep 10
  done
  echo "  $app: Synced/Healthy"
done

# First run on this machine: back up the generated key (outside the repo, never committed).
if [[ ! -f "$KEY_BACKUP" ]]; then
  until kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o name 2>/dev/null | grep -q .; do sleep 3; done
  mkdir -p "$(dirname "$KEY_BACKUP")"
  umask 077
  kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
    | grep -vE '^\s+(uid|resourceVersion|creationTimestamp):' > "$KEY_BACKUP"
  echo "Backed up Sealed Secrets key to $KEY_BACKUP (keep it safe; never commit it)"
fi

kubectl -n argocd get applications
cat <<MSG

Platform is up.
  Argo CD UI:   kubectl -n argocd port-forward svc/argocd-server 8080:80   ->  http://localhost:8080
  Login:        admin / $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  Rollouts UI:  kubectl -n argo-rollouts port-forward svc/argo-rollouts-dashboard 3100:3100
  Prometheus:   kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
MSG
