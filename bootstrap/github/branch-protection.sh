#!/usr/bin/env bash
# Branch protection for main and develop (PR required).
set -euo pipefail

ORG="${ROAMKIT_ORG:-roamkit-net}"
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

  if gh api --method PUT \
    -H "Accept: application/vnd.github+json" \
    "/repos/${ORG}/${repo}/branches/${branch}/protection" \
    --input - >/dev/null 2>&1 <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
  then
    echo "  ok"
  else
    echo "  skipped (private repo, missing branch, or GitHub Pro required)"
  fi
}

for repo in "${REPOS[@]}"; do
  for branch in "${BRANCHES[@]}"; do
    protect_branch "${repo}" "${branch}"
  done
done

echo "Branch protection applied."
