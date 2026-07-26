#!/usr/bin/env bash
# Production HTTP smoke (platform health). Billing E2E: production-dod-billing.sh.
set -euo pipefail

API_URL="${API_URL:-https://api.roamkit.net}"
WEB_URL="${WEB_URL:-https://roamkit.net}"

fail() {
  echo "PRODUCTION SMOKE FAILED: $*" >&2
  exit 1
}

echo "Production smoke against API=${API_URL} WEB=${WEB_URL}"

curl -sfI --max-time 20 "${WEB_URL}/" >/dev/null || fail "web ${WEB_URL}/"
curl -sf --max-time 20 "${API_URL}/health/live" >/dev/null || fail "api live"
curl -sf --max-time 20 "${API_URL}/health/ready" >/dev/null || fail "api ready"

# Gate C / ADR 013 must-have: non-empty git_sha
version_json="$(curl -sf --max-time 10 "${API_URL}/version")" \
  || fail "GET /version missing (Gate C must-have)"
echo "${version_json}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
sha=(d.get("git_sha") or "").strip()
assert sha, d
print("GET /version OK git_sha=%s…" % (sha[:12],))
' || fail "GET /version empty git_sha: ${version_json}"

# Unauthenticated billing money endpoints should 401 when billing enabled.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${API_URL}/api/v1/billing/balance/" || true)"
if [[ "${code}" != "401" && "${code}" != "404" ]]; then
  fail "billing/balance unexpected HTTP ${code} (want 401 or 404)"
fi

# Catalog price display dependency (hard fail).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "${SCRIPT_DIR}/assert-billing-config.sh" ]]; then
  API_URL="${API_URL}" "${SCRIPT_DIR}/assert-billing-config.sh" "${API_URL}" \
    || fail "billing/config assert"
else
  billing_cfg="$(curl -sf --max-time 20 "${API_URL}/api/v1/billing/config/")" \
    || fail "billing/config unreachable"
  echo "${billing_cfg}" | jq -e '
    (.token_symbol | type == "string" and length > 0)
    and (.display_decimals != null)
    and (.config_version | type == "number")
  ' >/dev/null || fail "billing/config invalid: ${billing_cfg}"
  echo "billing/config OK"
fi

# Web release fingerprint (required for production cutover builds).
web_ver="$(curl -sf --max-time 10 "${WEB_URL}/version" || true)"
if [[ -n "${web_ver}" ]]; then
  echo "${web_ver}" | jq -e '(.git_sha | type == "string" and length > 0)' >/dev/null \
    || fail "web /version empty git_sha: ${web_ver}"
  echo "web /version OK"
else
  echo "WARN: web /version missing (required after fingerprint deploy)"
fi

# Baked production API host in client chunks (hard-fail when ENFORCE_WEB_BAKE=1).
html="$(curl -sf --max-time 20 "${WEB_URL}/")" || fail "web root body"
chunk="$(echo "${html}" | grep -oE '/_next/static/chunks/[^"]+\.js' | head -1 || true)"
if [[ -n "${chunk}" ]]; then
  js="$(curl -sf --max-time 20 "${WEB_URL}${chunk}")" || fail "web chunk ${chunk}"
  if echo "${js}" | grep -q "api.roamkit.net"; then
    echo "web bake host OK (api.roamkit.net)"
  elif echo "${js}" | grep -q "api.staging.roamkit.net"; then
    if [[ "${ENFORCE_WEB_BAKE:-0}" == "1" ]]; then
      fail "production web bundle must not bake api.staging.roamkit.net"
    fi
    echo "WARN: web still bakes api.staging.roamkit.net (set ENFORCE_WEB_BAKE=1 after apex cutover)"
  else
    fail "web bundle missing expected API host"
  fi
else
  echo "WARN: no /_next/static chunk found to assert API host"
fi

if [[ -x "${SCRIPT_DIR}/warn-billing-config-parity.sh" ]]; then
  STAGING_API_URL="https://api.staging.roamkit.net" PROD_API_URL="${API_URL}" \
    "${SCRIPT_DIR}/warn-billing-config-parity.sh" || true
fi

echo "PRODUCTION SMOKE PASSED"
