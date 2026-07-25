#!/usr/bin/env bash
# Production HTTP smoke (platform health). Billing E2E DoD is PR2.
set -euo pipefail

API_URL="${API_URL:-https://api.roamkit.net}"
WEB_URL="${WEB_URL:-https://roamkit.net}"

# During pre-cutover dry-run on host, prefer in-compose curls via deploy script.
# This script is for post-Traefik public checks (or override URLs for local).

fail() {
  echo "PRODUCTION SMOKE FAILED: $*" >&2
  exit 1
}

echo "Production smoke against API=${API_URL} WEB=${WEB_URL}"

curl -sfI --max-time 20 "${WEB_URL}/" >/dev/null || fail "web ${WEB_URL}/"
curl -sf --max-time 20 "${API_URL}/health/live" >/dev/null || fail "api live"
curl -sf --max-time 20 "${API_URL}/health/ready" >/dev/null || fail "api ready"

# /version is api PR2 must-have — warn until present, do not fail PR1 platform smoke.
if curl -sf --max-time 10 "${API_URL}/version" >/dev/null 2>&1; then
  echo "GET /version OK"
else
  echo "WARN: GET /version not available yet (expected until api PR2)."
fi

# Unauthenticated billing money endpoints should 401 when billing enabled.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${API_URL}/api/v1/billing/balance/" || true)"
if [[ "${code}" != "401" && "${code}" != "404" ]]; then
  fail "billing/balance unexpected HTTP ${code} (want 401 or 404)"
fi

echo "PRODUCTION SMOKE PASSED"
