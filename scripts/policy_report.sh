#!/usr/bin/env bash
# Admission-policy scorecard against the LIVE cluster (Kyverno must be running).
#
#   scripts/policy_report.sh
#
# 1. Sends every manifest in policy-tests/resources to the API server with --dry-run=server.
#    bad-*  must be denied (and by which policy is printed); good-* must be admitted.
# 2. Sends the app's real Helm chart, rendered for each environment, the same way: real
#    workloads must be admitted (false-positive check).
# 3. Summarises Kyverno's background PolicyReports for what is already running in dev/staging/prod.
# Nothing is created: dry-run requests go through admission webhooks but are never persisted.
set -euo pipefail
cd "$(dirname "$0")/.."

blocked=0; bad=0; fp=0; good=0
row() { printf "| %s | %s | %s | %s |\n" "$@"; }

echo "### Admission results (live cluster, server-side dry run)"
echo
row "Manifest" "Expected" "Result" "Denied by"
row "---" "---" "---" "---"
for f in policy-tests/resources/*.yaml; do
  name=$(basename "$f" .yaml)
  if out=$(kubectl apply --dry-run=server -f "$f" 2>&1); then result=admitted; by=""; else
    result=denied
    by=$(echo "$out" | grep -oE '(disallow|require)-[a-z-]+' | sort -u | paste -sd, -)
  fi
  if [[ "$name" == bad-* ]]; then
    expected=denied; bad=$((bad + 1)); [[ "$result" == denied ]] && blocked=$((blocked + 1))
  else
    expected=admitted; good=$((good + 1)); [[ "$result" == denied ]] && fp=$((fp + 1))
  fi
  row "$name" "$expected" "$result" "${by:--}"
done

for env in dev staging prod; do
  good=$((good + 1))
  if out=$(helm template gitops-demo-app charts/gitops-demo-app -n "$env" -f "envs/$env/values.yaml" \
           | kubectl apply --dry-run=server -n "$env" -f - 2>&1); then result=admitted; by=""; else
    result=denied; fp=$((fp + 1))
    by=$(echo "$out" | grep -oE '(disallow|require)-[a-z-]+' | sort -u | paste -sd, -)
  fi
  row "app chart ($env)" admitted "$result" "${by:--}"
done

echo
echo "- Non-compliant manifests blocked: **$blocked/$bad** ($((100 * blocked / bad))%)"
echo "- Compliant manifests wrongly blocked: **$fp/$good**"
echo
echo "### Background scan of running resources (Kyverno PolicyReports)"
echo
row "Namespace" "Pass" "Fail" "Error"
row "---" "---" "---" "---"
for ns in dev staging prod; do
  read -r p f e < <(kubectl get policyreports -n "$ns" -o json \
    | jq -r '[.items[].summary] | "\(map(.pass // 0) | add // 0) \(map(.fail // 0) | add // 0) \(map(.error // 0) | add // 0)"')
  row "$ns" "$p" "$f" "$e"
done
