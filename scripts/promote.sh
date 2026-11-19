#!/usr/bin/env bash
# Copies the image tag from one environment to the next and commits it to main.
# Used by .github/workflows/promote.yml; Argo CD picks the commit up on its next poll.
# Audit trail: the commit (who/what/from where) + the GitHub deployment record (who approved prod).
set -euo pipefail
FROM="${1:?from env}"; TO="${2:?to env}"

TAG="$(yq '.image.tag' "envs/$FROM/values.yaml")"
CURRENT="$(yq '.image.tag' "envs/$TO/values.yaml")"
[[ "$TAG" =~ ^[0-9a-f]{40}$ ]] || { echo "refusing: $FROM tag '$TAG' is not a full git SHA" >&2; exit 1; }
if [[ "$TAG" == "$CURRENT" ]]; then
  echo "$TO already runs \`$TAG\`; nothing to promote" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

yq -i ".image.tag = \"$TAG\"" "envs/$TO/values.yaml"
git commit -am "$TO: promote ${TAG:0:12} from $FROM" \
  -m "App commit: https://github.com/KulmeetSJ/gitops-demo-app/commit/$TAG
Previous: $CURRENT
Triggered by: ${GITHUB_ACTOR:-local} (${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-})"

# Another pipeline (e.g. a CI dev bump) may have pushed meanwhile: rebase and retry.
for attempt in 1 2 3 4 5; do
  git push origin HEAD:main && break
  echo "push rejected (attempt $attempt), rebasing"; sleep $((attempt * 2))
  git pull --rebase origin main
done
echo "Promoted **$TO** to \`$TAG\` ($(git rev-parse --short HEAD))" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
