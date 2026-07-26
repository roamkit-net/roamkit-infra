#!/usr/bin/env bash
# Assert public GET /api/v1/billing/config/ is usable for catalog price display.
# Usage: assert-billing-config.sh [API_URL]
set -euo pipefail

API_URL="${1:-${API_URL:-https://api.staging.roamkit.net}}"
API_URL="${API_URL%/}"
TIMEOUT="${SMOKE_TIMEOUT:-30}"

fail() {
  echo "BILLING CONFIG ASSERT FAILED: $*" >&2
  exit 1
}

json="$(curl -4sf --max-time "${TIMEOUT}" "${API_URL}/api/v1/billing/config/")" \
  || fail "GET ${API_URL}/api/v1/billing/config/ unreachable"

echo "${json}" | jq -e '
  (.token_symbol | type == "string" and length > 0)
  and (.display_decimals != null)
  and (.config_version | type == "number")
' >/dev/null \
  || fail "invalid billing/config payload: ${json}"

echo "billing/config OK (${API_URL})"
