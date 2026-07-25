#!/usr/bin/env bash
# Post-deploy smoke test for staging.
set -euo pipefail

WEB_URL="${SMOKE_WEB_URL:-https://staging.roamkit.net}"
MARKETING_URL="${SMOKE_MARKETING_URL:-https://roamkit.net}"
API_URL="${SMOKE_API_URL:-https://api.staging.roamkit.net}"
TIMEOUT="${SMOKE_TIMEOUT:-30}"
RETRIES="${SMOKE_RETRIES:-20}"
RETRY_SLEEP="${SMOKE_RETRY_SLEEP:-3}"

fail() {
  echo "SMOKE TEST FAILED: $*" >&2
  exit 1
}

wait_for() {
  local url="$1"
  local label="$2"
  local i
  for i in $(seq 1 "${RETRIES}"); do
    if curl -4sf --max-time "${TIMEOUT}" "${url}" >/dev/null; then
      return 0
    fi
    sleep "${RETRY_SLEEP}"
  done
  fail "${label} unreachable"
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

# Web can briefly 502 while nginx reconnects after container recreate.
wait_for "${WEB_URL}/" "web root"

expect_http "${WEB_URL}/login" "200" "web /login"
expect_http "${WEB_URL}/register" "200" "web /register"
expect_http "${WEB_URL}/me/esims" "200" "web /me/esims"
expect_http "${WEB_URL}/me/deposit" "200" "web /me/deposit"
expect_http "${WEB_URL}/plans" "200" "web /plans"

# Billing HTTP is JWT-only (404 when BILLING_ENABLED=false).
expect_http "${API_URL}/api/v1/billing/balance/" "401" "billing/balance without JWT"
expect_http "${API_URL}/api/v1/billing/deposit-info/" "401" "billing/deposit-info without JWT"

curl -4sf --max-time "${TIMEOUT}" "${MARKETING_URL}/" >/dev/null   || fail "marketing root unreachable"

echo "SMOKE TEST PASSED"
