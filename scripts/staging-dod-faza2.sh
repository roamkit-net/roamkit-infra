#!/usr/bin/env bash
# Phase 2 staging DoD: register → (optional sandbox) → me/esims.
#
# Usage:
#   ./scripts/staging-dod-faza2.sh
#   SKIP_SANDBOX=1 ./scripts/staging-dod-faza2.sh   # API-only (no docker exec)
#   CREATE_SANDBOX=1 ./scripts/staging-dod-faza2.sh # also runs create_sandbox_esim
#
# Env:
#   API_URL, WEB_URL, STACK_DIR, PACKAGE_ID, DOD_EMAIL, DOD_PASSWORD
set -euo pipefail

API_URL="${API_URL:-https://api.staging.roamkit.net}"
WEB_URL="${WEB_URL:-https://staging.roamkit.net}"
STACK_DIR="${ROAMKIT_STAGING_DIR:-/opt/stacks/roamkit-net}"
PACKAGE_ID="${PACKAGE_ID:-}"
DOD_EMAIL="${DOD_EMAIL:-dod-$(date +%s)@example.com}"
DOD_PASSWORD="${DOD_PASSWORD:-SecurePass1!}"
TIMEOUT="${SMOKE_TIMEOUT:-30}"
CREATE_SANDBOX="${CREATE_SANDBOX:-0}"
SKIP_SANDBOX="${SKIP_SANDBOX:-0}"

fail() {
  echo "STAGING DoD FAILED: $*" >&2
  exit 1
}

json_field() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)"
}

echo "Phase 2 staging DoD against ${API_URL}"
echo "Email: ${DOD_EMAIL}"

for path in /login /register /me/esims; do
  code="$(curl -4s -o /dev/null -w "%{http_code}" --max-time "${TIMEOUT}" "${WEB_URL}${path}")" \
    || fail "web ${path} unreachable"
  [[ "${code}" == "200" ]] || fail "web ${path} expected 200, got ${code}"
done

reg_body="$(curl -4s --max-time "${TIMEOUT}" -X POST "${API_URL}/api/v1/auth/register/" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${DOD_EMAIL}\",\"password\":\"${DOD_PASSWORD}\"}")" \
  || fail "register request failed"
echo "${reg_body}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "email" in d, d' \
  || fail "register did not return user payload: ${reg_body}"

tok_body="$(curl -4s --max-time "${TIMEOUT}" -X POST "${API_URL}/api/v1/auth/token/" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${DOD_EMAIL}\",\"password\":\"${DOD_PASSWORD}\"}")" \
  || fail "token request failed"
ACCESS="$(echo "${tok_body}" | json_field "['access']")" \
  || fail "token response missing access: ${tok_body}"

if [[ "${CREATE_SANDBOX}" == "1" && "${SKIP_SANDBOX}" != "1" ]]; then
  if [[ -z "${PACKAGE_ID}" ]]; then
    PACKAGE_ID="$(curl -4sf --max-time "${TIMEOUT}" "${API_URL}/api/v1/packages/" \
      | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"]; print(r[0]["id"] if r else "")')" \
      || fail "could not resolve PACKAGE_ID from /api/v1/packages/"
  fi
  [[ -n "${PACKAGE_ID}" ]] || fail "PACKAGE_ID is empty; sync packages first"
  echo "Creating sandbox eSIM for package ${PACKAGE_ID}..."
  (
    cd "${STACK_DIR}"
    docker compose --profile app exec -T api \
      python manage.py create_sandbox_esim \
      --email="${DOD_EMAIL}" \
      --package-id="${PACKAGE_ID}"
  ) || fail "create_sandbox_esim failed"
fi

esims_body="$(curl -4s --max-time "${TIMEOUT}" "${API_URL}/api/v1/me/esims/" \
  -H "Authorization: Bearer ${ACCESS}")" \
  || fail "me/esims request failed"

if [[ "${CREATE_SANDBOX}" == "1" && "${SKIP_SANDBOX}" != "1" ]]; then
  echo "${esims_body}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d.get("count", 0) >= 1, d
item=d["results"][0]
for key in ("iccid", "qrcode", "qrcode_url"):
    assert item.get(key), f"missing {key}: {item}"
print(item["id"], item["iccid"])
' || fail "me/esims missing sandbox ICCID/QR payload: ${esims_body}"
  ESIM_ID="$(echo "${esims_body}" | json_field "['results'][0]['id']")"
  usage_code="$(curl -4s -o /tmp/dod_usage.json -w "%{http_code}" --max-time "${TIMEOUT}" \
    "${API_URL}/api/v1/me/esims/${ESIM_ID}/usage/" \
    -H "Authorization: Bearer ${ACCESS}")" \
    || fail "usage request failed"
  [[ "${usage_code}" == "200" ]] || fail "usage expected 200, got ${usage_code}"
else
  echo "${esims_body}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert "count" in d and "results" in d, d
print("me/esims OK (count=%s)" % d["count"])
' || fail "me/esims unexpected payload: ${esims_body}"
  echo "NOTE: set CREATE_SANDBOX=1 on the staging host to fulfill Airalo sandbox eSIM."
fi

echo "STAGING DoD PASSED"
