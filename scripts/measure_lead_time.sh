#!/usr/bin/env bash
# Measures deploy lead time for ONE app commit, live, from push to "Healthy in prod".
#
#   scripts/measure_lead_time.sh <app-commit-sha> [--promote]
#
# Without --promote it stops once dev is Healthy. With --promote it also dispatches the
# promote workflow for staging, then prod, and waits while a human approves prod.
# Human approval wait is reported SEPARATELY, so the machine part of the pipeline is visible.
#
# "Healthy" = the Argo Rollout in that namespace runs the commit's image, the canary has
# finished (stableRS == currentPodHash) and phase == Healthy. That is later than "Argo synced".
#
# Appends one row to measurements/lead_time.csv. Personal-project benchmark on a local kind cluster.
set -euo pipefail

APP_REPO="KulmeetSJ/gitops-demo-app"
PLATFORM_REPO="KulmeetSJ/gitops-demo-platform"
SHA="${1:?usage: $0 <40-char app commit sha> [--promote]}"
PROMOTE="${2:-}"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "need the full 40-char SHA" >&2; exit 1; }
POLL=5
TIMEOUT=$((90 * 60))   # prod waits for a human, so be generous
CSV="$(cd "$(dirname "$0")/.." && pwd)/measurements/lead_time.csv"

now()       { date -u +%s; }
iso()       { date -u -r "$1" +%FT%TZ 2>/dev/null || date -u -d "@$1" +%FT%TZ; }
iso2epoch() { date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s; }
dur()       { printf "%dm%02ds" $(($1 / 60)) $(($1 % 60)); }
log()       { echo "[$(date -u +%T)] $*" >&2; }

wait_for() {  # wait_for "<description>" <command...>; returns when the command succeeds
  local what="$1"; shift
  local start; start=$(now)
  until "$@"; do
    (( $(now) - start > TIMEOUT )) && { log "timed out waiting for: $what"; exit 1; }
    sleep "$POLL"
  done
}

rollout_healthy() {  # rollout_healthy <namespace>
  local out
  out=$(kubectl -n "$1" get rollout gitops-demo-app -o \
    jsonpath='{.spec.template.spec.containers[0].image} {.status.phase} {.status.stableRS} {.status.currentPodHash}' 2>/dev/null) || return 1
  read -r image phase stable current <<<"$out"
  [[ "$image" == *":$SHA" && "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" ]]
}

ci_run_id() {  # newest push run of the app CI for this commit
  gh api "repos/$APP_REPO/actions/runs?head_sha=$SHA&event=push&per_page=1" --jq '.workflow_runs[0].id // empty'
}

dispatch_promote() {  # dispatch_promote <target>; prints the new run id
  local target="$1" t0 id=""
  t0=$(now)
  gh workflow run promote.yml -R "$PLATFORM_REPO" -f target="$target" >/dev/null
  while [[ -z "$id" ]]; do
    sleep 3
    id=$(gh api "repos/$PLATFORM_REPO/actions/workflows/promote.yml/runs?event=workflow_dispatch&per_page=5" \
      --jq "[.workflow_runs[] | select(.created_at >= \"$(iso $((t0 - 5)))\")][0].id // empty")
    (( $(now) - t0 > 120 )) && { log "promote run for $target never appeared"; exit 1; }
  done
  echo "$id"
}

# ---- 1. push -> CI ----
log "waiting for the app CI run of ${SHA:0:12}"
ci_appeared() { [[ -n "$(ci_run_id)" ]]; }
wait_for "CI run to appear" ci_appeared
RUN=$(ci_run_id)
T_PUSH=$(iso2epoch "$(gh api "repos/$APP_REPO/actions/runs/$RUN" --jq .created_at)")
log "CI run $RUN (push at $(iso "$T_PUSH")); waiting for it to finish"
ci_finished() { [[ "$(gh api "repos/$APP_REPO/actions/runs/$RUN" --jq .status)" == completed ]]; }
wait_for "CI to finish" ci_finished
read -r CONCLUSION CI_DONE <<<"$(gh api "repos/$APP_REPO/actions/runs/$RUN" --jq '"\(.conclusion) \(.updated_at)"')"
[[ "$CONCLUSION" == success ]] || { log "CI concluded '$CONCLUSION'; nothing to measure"; exit 1; }
T_CI=$(iso2epoch "$CI_DONE")

# ---- 2. dev (automatic: CI commits the tag, Argo CD pulls, canary runs) ----
log "CI green; waiting for dev to be Healthy on ${SHA:0:12}"
wait_for "dev Healthy" rollout_healthy dev
T_DEV=$(now)
log "dev Healthy after $(dur $((T_DEV - T_PUSH))) from push"

T_STG=""; T_PROD=""; WAIT_APPROVAL=0; T_PROD_REQ=""
if [[ "$PROMOTE" == "--promote" ]]; then
  # ---- 3. staging (one-click promotion, no approval) ----
  T_STG_REQ=$(now)
  STG_RUN=$(dispatch_promote staging); log "staging promotion run $STG_RUN"
  wait_for "staging Healthy" rollout_healthy staging
  T_STG=$(now); log "staging Healthy $(dur $((T_STG - T_STG_REQ))) after promotion was requested"

  # ---- 4. prod (GitHub Environment 'production' needs a required reviewer) ----
  T_PROD_REQ=$(now)
  PROD_RUN=$(dispatch_promote prod)
  log "prod promotion run $PROD_RUN is waiting for approval:"
  log "  https://github.com/$PLATFORM_REPO/actions/runs/$PROD_RUN"
  wait_for "prod Healthy" rollout_healthy prod
  T_PROD=$(now)
  read -r J_CREATED J_STARTED <<<"$(gh api "repos/$PLATFORM_REPO/actions/runs/$PROD_RUN/jobs" \
    --jq '.jobs[] | select(.name=="prod") | "\(.created_at) \(.started_at)"')"
  WAIT_APPROVAL=$(( $(iso2epoch "$J_STARTED") - $(iso2epoch "$J_CREATED") ))
  log "prod Healthy; approval wait was $(dur "$WAIT_APPROVAL")"
fi

# ---- report ----
END=${T_PROD:-$T_DEV}
TOTAL=$((END - T_PUSH))
{
  echo
  echo "### Lead time for \`${SHA:0:12}\` (personal-project benchmark, local kind cluster)"
  echo
  echo "| Stage | Time (UTC) | Since push |"
  echo "|---|---|---|"
  echo "| Push (CI run created) | $(iso "$T_PUSH") | 0m00s |"
  echo "| CI green (test, image, scan, SBOM, publish) | $(iso "$T_CI") | $(dur $((T_CI - T_PUSH))) |"
  echo "| dev Healthy (canary finished) | $(iso "$T_DEV") | $(dur $((T_DEV - T_PUSH))) |"
  if [[ -n "$T_PROD" ]]; then
    echo "| staging Healthy | $(iso "$T_STG") | $(dur $((T_STG - T_PUSH))) |"
    echo "| prod promotion requested | $(iso "$T_PROD_REQ") | $(dur $((T_PROD_REQ - T_PUSH))) |"
    echo "| prod Healthy | $(iso "$T_PROD") | $(dur $((T_PROD - T_PUSH))) |"
    echo
    echo "- Total lead time: **$(dur "$TOTAL")**, of which human approval wait: **$(dur "$WAIT_APPROVAL")**"
    echo "- Lead time excluding approval wait: **$(dur $((TOTAL - WAIT_APPROVAL)))**"
  fi
}
mkdir -p "$(dirname "$CSV")"
[[ -f "$CSV" ]] || echo "app_sha,push_utc,ci_s,dev_healthy_s,staging_healthy_s,prod_healthy_s,approval_wait_s,lead_time_excl_approval_s" >"$CSV"
echo "$SHA,$(iso "$T_PUSH"),$((T_CI - T_PUSH)),$((T_DEV - T_PUSH)),${T_STG:+$((T_STG - T_PUSH))},${T_PROD:+$((T_PROD - T_PUSH))},$WAIT_APPROVAL,$((TOTAL - WAIT_APPROVAL))" >>"$CSV"
log "appended to $CSV"
