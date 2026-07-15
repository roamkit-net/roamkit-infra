#!/usr/bin/env bash
# Post-deploy smoke test for staging.
set -euo pipefail

WEB_URL="${SMOKE_WEB_URL:-https://staging.roamkit.net}"
API_URL="${SMOKE_API_URL:-https://api.staging.roamkit.net}"
TIMEOUT="${SMOKE_TIMEOUT:-30}"

fail() {
  echo "SMOKE TEST FAILED: $*" >&2
  exit 1
}

echo "Smoke test: ${WEB_URL} + ${API_URL}"

curl -sf --max-time "${TIMEOUT}" "${API_URL}/health/live" >/dev/null   || fail "health/live unreachable"

curl -sf --max-time "${TIMEOUT}" "${API_URL}/health/ready" >/dev/null   || fail "health/ready unreachable"

curl -sf --max-time "${TIMEOUT}" "${API_URL}/api/v1/packages/" >/dev/null   || echo "WARN: /api/v1/packages/ not yet available (expected before Faza 1)"

curl -sf --max-time "${TIMEOUT}" "${WEB_URL}/" >/dev/null   || fail "web root unreachable"

echo "SMOKE TEST PASSED"
