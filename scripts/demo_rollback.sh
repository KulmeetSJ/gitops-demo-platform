#!/usr/bin/env bash
# Live, terminal-friendly view of ONE automated canary rollback, for recording (docs/rollback-demo.gif).
#
#   scripts/demo_rollback.sh [fault_rate=0.2]
#
# Commits a bad release to dev through Git (same image, FAULT_RATE set), redraws the Rollout,
# its pods and the canary's AnalysisRun every 2 s until the canary is gone, then reverts the commit.
# Record it with:  asciinema rec -c scripts/demo_rollback.sh demo.cast && agg --speed 6 demo.cast docs/rollback-demo.gif
set -euo pipefail
FAULT="${1:-0.2}"
NS=dev
cd "$(dirname "$0")/.."
VALUES="envs/$NS/values.yaml"

B=$'\e[1m'; D=$'\e[2m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
ro() { kubectl -n "$NS" get rollout gitops-demo-app -o jsonpath="$1"; }
push_main() { for a in 1 2 3; do git push -q origin HEAD:main && return; git pull -q --rebase --autostash origin main; done; return 1; }

[[ "$(yq '.faultRate' "$VALUES")" == "0" ]] || { echo "dev faultRate is not 0" >&2; exit 1; }
STABLE=$(ro '{.status.stableRS}')
yq -i ".faultRate = \"$FAULT\"" "$VALUES"
git commit -q -m "dev: DEMO bad release (FAULT_RATE=$FAULT)" -m "Recorded by scripts/demo_rollback.sh; reverted automatically." -- "$VALUES"
push_main
COMMIT=$(git log -1 --format='%h %s')
T0=$(date -u +%s); SINCE=$(date -u -r "$T0" +%FT%TZ 2>/dev/null || date -u -d "@$T0" +%FT%TZ)
done_at=""

draw() {
  local el=$(( $(date -u +%s) - T0 )) rj phase msg idx nsteps canary
  rj=$(kubectl -n "$NS" get rollout gitops-demo-app -o json)
  phase=$(jq -r '.status.phase // "-"' <<<"$rj"); msg=$(jq -r '.status.message // ""' <<<"$rj")
  idx=$(jq -r '.status.currentStepIndex // 0' <<<"$rj"); nsteps=$(jq -r '.spec.strategy.canary.steps | length' <<<"$rj")
  canary=$(jq -r '.status.currentPodHash' <<<"$rj")
  local pc="$Y"; [[ "$phase" == Healthy ]] && pc="$G"; [[ "$phase" == Degraded ]] && pc="$R"

  printf '\e[H\e[2J'
  printf "%sGitOps canary auto-rollback%s  %st+%02d:%02d%s  %spersonal-project demo, local kind cluster%s\n\n" \
    "$B" "$N" "$C" $((el / 60)) $((el % 60)) "$N" "$D" "$N"
  printf "git push  %s%s%s\n" "$Y" "$COMMIT" "$N"
  printf "          %sArgo CD pulls it within 60 s; nobody runs kubectl%s\n\n" "$D" "$N"
  printf "%sRollout%s %s/gitops-demo-app   phase: %s%s%s   step %s/%s\n" "$B" "$N" "$NS" "$pc" "$phase" "$N" "$idx" "$nsteps"
  [[ -n "$msg" ]] && printf "  %s%s%s\n" "$D" "${msg:0:110}" "$N"
  echo
  printf "  %-8s %-11s %-16s %s\n" ROLE HASH FAULT_RATE "READY PODS"
  kubectl -n "$NS" get rs -l app.kubernetes.io/component=api -o json | jq -r --arg s "$STABLE" --arg c "$canary" '
    .items[] | (.metadata.labels["rollouts-pod-template-hash"]) as $h
    | select($h == $s or $h == $c)
    | [ (if $h == $s then "stable" else "canary" end), $h,
        ((.spec.template.spec.containers[0].env // []) | map(select(.name=="FAULT_RATE")) | .[0].value // "0"),
        (.status.readyReplicas // 0 | tostring) ] | @tsv' \
  | while IFS=$'\t' read -r role h f r; do
      local col="$G"; [[ "$role" == canary ]] && col="$R"
      printf "  %s%-8s%s %-11s %-16s %s\n" "$col" "$role" "$N" "$h" "$f" "$r"
    done
  echo
  printf "%sAnalysis%s %s(Prometheus, canary pods only, every 30 s; 2 failures = abort)%s\n" "$B" "$N" "$D" "$N"
  kubectl -n "$NS" get analysisrun -l rollouts-pod-template-hash="$canary" -o json | jq -r --arg since "$SINCE" '
    [.items[] | select(.metadata.creationTimestamp >= $since)] | .[0].status.metricResults // [] | .[]
    | [ .name, ([.measurements[]? | ((.value // "[]" | fromjson? // [] | .[0] // "n/a") | tostring | .[0:5]) + (if .phase=="Failed" then " FAIL" elif .phase=="Successful" then " ok" else " ?" end)] | join("  ")) ] | @tsv' \
  | while IFS=$'\t' read -r name vals; do
      local thr="≥ 0.99"; [[ "$name" == p95* ]] && thr="≤ 0.5 s"
      vals=${vals//FAIL/${R}FAIL${N}}; vals=${vals//ok/${G}ok${N}}
      printf "  %-13s %-8s %s\n" "$name" "$thr" "${vals:-waiting for first measurement (initial delay 60 s)}"
    done
  echo
  if [[ -n "$done_at" ]]; then
    printf "%s✔ Bad canary removed at t+%02d:%02d with no human action. Stable pods served throughout.%s\n" "$G" $((done_at / 60)) $((done_at % 60)) "$N"
    printf "%s  Reverting the commit so Git matches the cluster…%s\n" "$D" "$N"
  fi
}

while :; do
  draw
  if [[ -z "$done_at" && "$(ro '{.status.abort}')" == "true" ]]; then
    r=$(kubectl -n "$NS" get rs -l rollouts-pod-template-hash="$(ro '{.status.currentPodHash}')" -o jsonpath='{.items[0].status.readyReplicas}')
    [[ -z "$r" || "$r" == 0 ]] && done_at=$(( $(date -u +%s) - T0 ))
  fi
  [[ -n "$done_at" ]] && break
  sleep 2
done
sleep 3
git revert --no-edit HEAD >/dev/null
git commit -q --amend -m "Revert DEMO bad release: canary was auto-aborted by analysis"
push_main
draw; printf "%s  Reverted: %s%s\n" "$G" "$(git log -1 --format='%h %s')" "$N"
sleep 4
