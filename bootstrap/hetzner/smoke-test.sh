#!/usr/bin/env bash
# Post-deploy smoke test for staging.
set -euo pipefail

WEB_URL="${SMOKE_WEB_URL:-https://staging.roamkit.net}"
MARKETING_URL="${SMOKE_MARKETING_URL:-https://roamkit.net}"
API_URL="${SMOKE_API_URL:-https://api.staging.roamkit.net}"
TIMEOUT="${SMOKE_TIMEOUT:-30}"

fail() {
  echo "SMOKE TEST FAILED: $*" >&2
  exit 1
}

echo "Smoke test: ${MARKETING_URL} + ${WEB_URL} + ${API_URL}"

# api.staging is DNS-only (grey cloud); prefer IPv4 to avoid stale proxied AAAA cache.
curl -4sf --max-time "${TIMEOUT}" "${API_URL}/health/live" >/dev/null   || fail "health/live unreachable"

curl -4sf --max-time "${TIMEOUT}" "${API_URL}/health/ready" >/dev/null   || fail "health/ready unreachable"

curl -4sf --max-time "${TIMEOUT}" "${API_URL}/api/v1/packages/" >/dev/null   || echo "WARN: /api/v1/packages/ not yet available (expected before Faza 1)"

curl -4sf --max-time "${TIMEOUT}" "${WEB_URL}/" >/dev/null   || fail "web root unreachable"

curl -4sf --max-time "${TIMEOUT}" "${MARKETING_URL}/" >/dev/null   || fail "marketing root unreachable"

echo "SMOKE TEST PASSED"
