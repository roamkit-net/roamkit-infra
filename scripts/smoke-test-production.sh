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

echo "PRODUCTION SMOKE PASSED"
