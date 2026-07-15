#!/usr/bin/env bash
# Create roamkit GitHub organization (idempotent).
set -euo pipefail

ORG="${ROAMKIT_ORG:-roamkit}"

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "ERROR: GH_TOKEN is not set. Export a token with admin:org scope." >&2
  exit 1
fi

if gh api "orgs/${ORG}" &>/dev/null; then
  echo "Organization '${ORG}' already exists — skipping."
  exit 0
fi

echo "Creating organization '${ORG}'..."
gh api -X POST orgs -f login="${ORG}" -f profile_name="RoamKit" -f billing_email="${ROAMKIT_BILLING_EMAIL:-}"

echo "Organization '${ORG}' created."
