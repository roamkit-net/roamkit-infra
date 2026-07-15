#!/usr/bin/env bash
# Branch protection for main and develop (PR required).
set -euo pipefail

ORG="${ROAMKIT_ORG:-roamkit}"
REPOS=(roamkit-infra roamkit-docs roamkit-api roamkit-web .github)
BRANCHES=(main develop)

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "ERROR: GH_TOKEN is not set." >&2
  exit 1
fi

protect_branch() {
  local repo="$1"
  local branch="$2"

  echo "Protecting ${ORG}/${repo}:${branch}..."

  gh api     --method PUT     -H "Accept: application/vnd.github+json"     "/repos/${ORG}/${repo}/branches/${branch}/protection"     -f required_status_checks='null'     -F enforce_admins=true     -F required_pull_request_reviews[required_approving_review_count]=1     -F required_pull_request_reviews[dismiss_stale_reviews]=true     -F restrictions='null'     -F allow_force_pushes=false     -F allow_deletions=false     2>/dev/null || echo "  (may already be protected or branch missing — create ${branch} first)"
}

for repo in "${REPOS[@]}"; do
  for branch in "${BRANCHES[@]}"; do
    protect_branch "${repo}" "${branch}"
  done
done

echo "Branch protection applied."
