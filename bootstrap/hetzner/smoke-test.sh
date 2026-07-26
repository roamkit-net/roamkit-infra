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

# Catalog price display dependency (hard fail).
billing_cfg="$(curl -4sf --max-time "${TIMEOUT}" "${API_URL}/api/v1/billing/config/")" \
  || fail "billing/config unreachable"
echo "${billing_cfg}" | jq -e '
  (.token_symbol | type == "string" and length > 0)
  and (.display_decimals != null)
  and (.config_version | type == "number")
' >/dev/null || fail "billing/config invalid payload: ${billing_cfg}"
echo "billing/config OK"

# Web release fingerprint (soft if route not deployed yet).
web_ver_code="$(curl -4s -o /tmp/roamkit_web_version.json -w "%{http_code}" --max-time "${TIMEOUT}" "${WEB_URL}/version" || true)"
if [[ "${web_ver_code}" == "200" ]]; then
  jq -e '(.git_sha | type == "string" and length > 0)' /tmp/roamkit_web_version.json >/dev/null \
    || fail "web /version empty git_sha"
  echo "web /version OK"
else
  echo "WARN: web /version HTTP ${web_ver_code} (expected after web fingerprint deploy)"
fi

# Baked NEXT_PUBLIC_API_URL host in client chunks (staging).
html="$(curl -4sf --max-time "${TIMEOUT}" "${WEB_URL}/")" || fail "web root body"
mapfile -t chunks < <(echo "${html}" | grep -oE '/_next/static/chunks/[^"]+\.js' | head -15)
found_staging=0
found_prod=0
for chunk in "${chunks[@]:-}"; do
  js="$(curl -4sf --max-time "${TIMEOUT}" "${WEB_URL}${chunk}" || true)"
  [[ -z "${js}" ]] && continue
  echo "${js}" | grep -q "api.staging.roamkit.net" && found_staging=1
  echo "${js}" | grep -q "api.roamkit.net" && found_prod=1
done
if [[ "${found_staging}" -eq 1 ]]; then
  echo "web bake host OK (api.staging.roamkit.net)"
elif [[ "${#chunks[@]}" -eq 0 ]]; then
  echo "WARN: no /_next/static chunk found to assert API host"
else
  fail "staging web bundle missing api.staging.roamkit.net"
fi
if [[ "${found_prod}" -eq 1 ]]; then
  fail "staging web bundle must not bake api.roamkit.net"
fi

curl -4sf --max-time "${TIMEOUT}" "${MARKETING_URL}/" >/dev/null   || fail "marketing root unreachable"

# Soft parity vs production (never fails deploy).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "${SCRIPT_DIR}/warn-billing-config-parity.sh" ]]; then
  STAGING_API_URL="${API_URL}" PROD_API_URL="https://api.roamkit.net" \
    "${SCRIPT_DIR}/warn-billing-config-parity.sh" || true
elif [[ -x "${SCRIPT_DIR}/../scripts/warn-billing-config-parity.sh" ]]; then
  STAGING_API_URL="${API_URL}" PROD_API_URL="https://api.roamkit.net" \
    "${SCRIPT_DIR}/../scripts/warn-billing-config-parity.sh" || true
fi

echo "SMOKE TEST PASSED"
