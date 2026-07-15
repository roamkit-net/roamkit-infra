#!/usr/bin/env bash
# Create roamkit org repositories (idempotent).
set -euo pipefail

ORG="${ROAMKIT_ORG:-roamkit-net}"

REPOS=(
  "roamkit-infra:Infrastructure as Code — bootstrap, compose, nginx, CI, deploy"
  "roamkit-docs:Architecture decisions, RFCs, and standards"
  "roamkit-api:Django + DRF + Celery API"
  "roamkit-web:Next.js web application"
  ".github:Organization reusable workflows and templates"
)

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "ERROR: GH_TOKEN is not set." >&2
  exit 1
fi

for entry in "${REPOS[@]}"; do
  name="${entry%%:*}"
  desc="${entry#*:}"

  if gh repo view "${ORG}/${name}" &>/dev/null; then
    echo "Repo ${ORG}/${name} already exists — skipping."
    continue
  fi

  echo "Creating ${ORG}/${name}..."
  gh repo create "${ORG}/${name}"     --private     --description "${desc}"     --disable-wiki     --disable-issues=false
done

echo "All repositories ensured."
