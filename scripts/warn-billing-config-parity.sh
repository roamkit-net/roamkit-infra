#!/usr/bin/env bash
# Soft-warn if staging and production billing/config display fields drift.
# Always exits 0 (warning only).
set -euo pipefail

STAGING_API="${STAGING_API_URL:-https://api.staging.roamkit.net}"
PROD_API="${PROD_API_URL:-https://api.roamkit.net}"
TIMEOUT="${SMOKE_TIMEOUT:-30}"

fetch() {
  curl -4sf --max-time "${TIMEOUT}" "${1%/}/api/v1/billing/config/" || true
}

staging_json="$(fetch "${STAGING_API}")"
prod_json="$(fetch "${PROD_API}")"

if [[ -z "${staging_json}" || -z "${prod_json}" ]]; then
  echo "WARN: billing config parity skipped (could not fetch both envs)" >&2
  exit 0
fi

fields='[.token_symbol, .display_decimals, .config_version]'
s="$(echo "${staging_json}" | jq -c "${fields}" 2>/dev/null || true)"
p="$(echo "${prod_json}" | jq -c "${fields}" 2>/dev/null || true)"

if [[ -z "${s}" || -z "${p}" ]]; then
  echo "WARN: billing config parity skipped (invalid JSON)" >&2
  exit 0
fi

if [[ "${s}" != "${p}" ]]; then
  echo "WARN: billing/config display drift staging=${s} production=${p}" >&2
  exit 0
fi

echo "billing/config parity OK (${s})"
