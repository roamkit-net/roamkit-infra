#!/usr/bin/env bash
# Create standard labels across roamkit repos.
set -euo pipefail

ORG="${ROAMKIT_ORG:-roamkit}"
REPOS=(roamkit-infra roamkit-docs roamkit-api roamkit-web)

declare -A LABELS=(
  ["type:feature"]="0366d6"
  ["type:bug"]="d73a4a"
  ["type:chore"]="cfd3d7"
  ["type:docs"]="0075ca"
  ["type:security"]="b60205"
  ["priority:high"]="e99695"
  ["priority:medium"]="fbca04"
  ["priority:low"]="0e8a16"
  ["area:infra"]="5319e7"
  ["area:api"]="1d76db"
  ["area:web"]="bfd4f2"
  ["blocked"]="000000"
)

for repo in "${REPOS[@]}"; do
  echo "Labels for ${ORG}/${repo}..."
  for label in "${!LABELS[@]}"; do
    color="${LABELS[$label]}"
    gh label create "${label}" --repo "${ORG}/${repo}" --color "${color}" --force 2>/dev/null       || echo "  skipped ${label}"
  done
done

echo "Labels ensured."
