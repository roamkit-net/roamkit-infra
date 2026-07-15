#!/usr/bin/env bash
# Create org milestones for phased delivery.
set -euo pipefail

ORG="${ROAMKIT_ORG:-roamkit}"
REPOS=(roamkit-infra roamkit-api roamkit-web)

MILESTONES=(
  "Faza 0: Application skeleton"
  "Faza 1: Landing + catalog"
  "Faza 2: Auth + My eSIM"
  "Faza 3: Payment + self-service"
)

for repo in "${REPOS[@]}"; do
  echo "Milestones for ${ORG}/${repo}..."
  for title in "${MILESTONES[@]}"; do
    gh api       --method POST       "/repos/${ORG}/${repo}/milestones"       -f title="${title}"       -f state="open"       2>/dev/null || echo "  skipped: ${title}"
  done
done

echo "Milestones ensured."
