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

expect_http() {
  local url="$1"
  local expected="$2"
  local label="$3"
  local code
  code="$(curl -4s -o /dev/null -w "%{http_code}" --max-time "${TIMEOUT}" "${url}")" \
    || fail "${label} unreachable (${url})"
  if [[ "${code}" != "${expected}" ]]; then
    fail "${label} expected HTTP ${expected}, got ${code} (${url})"
  fi
}

echo "Smoke test: ${MARKETING_URL} + ${WEB_URL} + ${API_URL}"

# api.staging is DNS-only (grey cloud); prefer IPv4 to avoid stale proxied AAAA cache.
curl -4sf --max-time "${TIMEOUT}" "${API_URL}/health/live" >/dev/null   || fail "health/live unreachable"

curl -4sf --max-time "${TIMEOUT}" "${API_URL}/health/ready" >/dev/null   || fail "health/ready unreachable"

curl -4sf --max-time "${TIMEOUT}" "${API_URL}/api/v1/packages/" >/dev/null   || fail "/api/v1/packages/ unreachable"

# Phase 2 auth: unauthenticated /me must reject; register without body must validate.
expect_http "${API_URL}/api/v1/auth/me/" "401" "auth/me without JWT"
reg_code="$(curl -4s -o /dev/null -w "%{http_code}" --max-time "${TIMEOUT}" \
  -X POST "${API_URL}/api/v1/auth/register/" \
  -H "Content-Type: application/json" \
  -d '{}')" || fail "auth/register unreachable"
if [[ "${reg_code}" != "400" ]]; then
  fail "auth/register expected HTTP 400 for empty body, got ${reg_code}"
fi

curl -4sf --max-time "${TIMEOUT}" "${WEB_URL}/" >/dev/null   || fail "web root unreachable"

expect_http "${WEB_URL}/login" "200" "web /login"
expect_http "${WEB_URL}/register" "200" "web /register"
expect_http "${WEB_URL}/me/esims" "200" "web /me/esims"
expect_http "${WEB_URL}/plans" "200" "web /plans"

curl -4sf --max-time "${TIMEOUT}" "${MARKETING_URL}/" >/dev/null   || fail "marketing root unreachable"

echo "SMOKE TEST PASSED"
