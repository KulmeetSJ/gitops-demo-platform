#!/usr/bin/env bash
# Rollback drill: ships a deliberately bad release to dev N times, through Git, and times the
# automated rollback each time. No human acts during a run; the script only commits, observes, reverts.
#
#   scripts/measure_rollback.sh [runs=5] [fault_rate=0.2]
#
# The bad release is the SAME image with FAULT_RATE set, so /api/** returns 500 for that share of
# requests while health probes stay green: only the metric analysis can catch it.
#
# Per run it records (all from cluster state, UTC):
#   push        - bad commit pushed to main
#   canary_up   - canary ReplicaSet has a ready pod (bad code is serving traffic)
#   first_fail  - first failed success-rate measurement (AnalysisRun)
#   aborted     - Rollout status.abort became true (first time the script saw it)
#   canary_gone - canary ReplicaSet has 0 ready pods (all traffic back on stable)
# and derives:
#   detect_to_rollback = canary_gone - first_fail   (what failureLimit/interval cost us)
#   bad_exposure       = canary_gone - canary_up    (how long bad code served users)
#   push_to_restored   = canary_gone - push
#
# Then it reverts the commit in Git (so Git matches what runs) and waits for Healthy before the next run.
# Appends rows to measurements/rollback.csv. Personal-project benchmark on a local kind cluster.
set -euo pipefail

RUNS="${1:-5}"
FAULT="${2:-0.2}"
NS=dev
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALUES="envs/$NS/values.yaml"
CSV="$ROOT/measurements/rollback.csv"
POLL=1
TIMEOUT=900
cd "$ROOT"

now()       { date -u +%s; }
iso()       { date -u -r "$1" +%FT%TZ 2>/dev/null || date -u -d "@$1" +%FT%TZ; }
iso2epoch() { date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s; }
log()       { echo "[$(date -u +%T)] $*" >&2; }
ro()        { kubectl -n "$NS" get rollout gitops-demo-app -o jsonpath="$1"; }

wait_for() {
  local what="$1"; shift
  local start; start=$(now)
  until "$@"; do
    (( $(now) - start > TIMEOUT )) && { log "timed out waiting for: $what"; exit 1; }
    sleep "$POLL"
  done
}

healthy()        { local o; o=$(ro '{.status.phase}|{.status.abort}|{.status.stableRS}|{.status.currentPodHash}')
                   IFS='|' read -r p a s c <<<"$o"; [[ "$p" == Healthy && "$a" != true && -n "$s" && "$s" == "$c" ]]; }
canary_started() { local c; c=$(ro '{.status.currentPodHash}'); [[ -n "$c" && "$c" != "$STABLE" ]]; }
aborted()        { [[ "$(ro '{.status.abort}')" == "true" ]]; }
ready_pods()     { kubectl -n "$NS" get rs -l rollouts-pod-template-hash="$1" -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null; }
canary_ready()   { local r; r=$(ready_pods "$CANARY"); [[ "${r:-0}" -ge 1 ]]; }
canary_gone()    { local r; r=$(ready_pods "$CANARY"); [[ -z "$r" || "$r" == 0 ]]; }

push_main() {
  for attempt in 1 2 3 4 5; do
    git push -q origin HEAD:main && return 0
    log "push rejected (attempt $attempt), rebasing"; sleep $((attempt * 2)); git pull -q --rebase --autostash origin main
  done
  return 1
}

median() { sort -n | awk '{a[NR]=$1} END {if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2}'; }

[[ -z "$(git status --porcelain -- "$VALUES")" ]] || { log "$VALUES has local changes; aborting"; exit 1; }
git pull -q --rebase --autostash origin main
[[ "$(yq '.faultRate // "0"' "$VALUES")" == "0" ]] || { log "dev faultRate is not 0; fix that first"; exit 1; }
mkdir -p "$(dirname "$CSV")"
[[ -f "$CSV" ]] || echo "run,push_utc,canary_up_s,first_fail_s,aborted_s,canary_gone_s,detect_to_rollback_s,bad_exposure_s,push_to_restored_s,failed_measurements" >"$CSV"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT

for i in $(seq 1 "$RUNS"); do
  log "=== run $i/$RUNS ==="
  wait_for "dev Healthy before the run" healthy
  STABLE=$(ro '{.status.stableRS}')

  yq -i ".faultRate = \"$FAULT\"" "$VALUES"
  git commit -q -m "dev: rollback drill $i/$RUNS (FAULT_RATE=$FAULT)" \
    -m "Deliberately bad release, reverted automatically by scripts/measure_rollback.sh" -- "$VALUES"
  push_main
  T_PUSH=$(now); log "pushed bad release $(git rev-parse --short HEAD)"

  wait_for "canary to start" canary_started
  CANARY=$(ro '{.status.currentPodHash}')
  wait_for "canary pod ready" canary_ready;  T_UP=$(now);    log "canary $CANARY serving"
  wait_for "rollout abort"     aborted;       T_ABORT=$(now); log "rollout aborted"
  wait_for "canary scaled down" canary_gone;  T_GONE=$(now);  log "canary gone, traffic on stable"

  # First failed success-rate measurement, from the AnalysisRun for this canary hash.
  # Every drill produces the same pod hash, so keep only the AnalysisRun(s) created by THIS run.
  kubectl -n "$NS" get analysisrun -l rollouts-pod-template-hash="$CANARY" -o json \
    | jq --arg since "$(iso "$T_PUSH")" '.items |= map(select(.metadata.creationTimestamp >= $since))' >"$TMP"
  FIRST_FAIL_ISO=$(jq -r '[.items[].status.metricResults[]? | select(.name=="success-rate")
      | .measurements[]? | select(.phase=="Failed") | .finishedAt] | sort | .[0] // empty' "$TMP")
  FAILED_VALUES=$(jq -r '[.items[].status.metricResults[]? | select(.name=="success-rate")
      | .measurements[]? | select(.phase=="Failed") | (.value | fromjson? | .[0]? // .) ] | map(tostring) | join(";")' "$TMP")
  [[ -n "$FIRST_FAIL_ISO" ]] || { log "no failed measurement found (aborted for another reason?)"; FIRST_FAIL_ISO=$(iso "$T_ABORT"); }
  T_FAIL=$(iso2epoch "$FIRST_FAIL_ISO")

  echo "$i,$(iso "$T_PUSH"),$((T_UP - T_PUSH)),$((T_FAIL - T_PUSH)),$((T_ABORT - T_PUSH)),$((T_GONE - T_PUSH)),$((T_GONE - T_FAIL)),$((T_GONE - T_UP)),$((T_GONE - T_PUSH)),$FAILED_VALUES" >>"$CSV"
  log "detect->rollback $((T_GONE - T_FAIL))s | bad exposure $((T_GONE - T_UP))s | push->restored $((T_GONE - T_PUSH))s | failed: $FAILED_VALUES"

  git revert --no-edit HEAD >/dev/null
  git commit -q --amend -m "Revert dev rollback drill $i/$RUNS: canary was auto-aborted by analysis"
  push_main
  log "reverted in Git"
  wait_for "dev Healthy after revert" healthy
  sleep 20   # let the stable pod's request-rate window settle before the next bad release
done

# ---- summary over all runs recorded in the CSV for this session ----
{
  echo
  echo "### Rollback drill: last $RUNS runs (personal-project benchmark, local kind cluster)"
  echo
  echo "| Metric | Median | Min | Max |"
  echo "|---|---|---|---|"
  for col in 7:detect_to_rollback 8:bad_exposure 9:push_to_restored; do
    n=${col%%:*}; name=${col#*:}
    vals=$(tail -n "$RUNS" "$CSV" | cut -d, -f"$n")
    echo "| ${name//_/ } (s) | $(echo "$vals" | median) | $(echo "$vals" | sort -n | head -1) | $(echo "$vals" | sort -n | tail -1) |"
  done
}
