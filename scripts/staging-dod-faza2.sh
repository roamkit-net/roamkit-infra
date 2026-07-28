#!/usr/bin/env bash
# Phase 2 staging DoD: register → activate → token → (optional sandbox) → me/esims.
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

for path in /login /register /forgot-password /set-password /reset-password /me/esims; do
  code="$(curl -4s -o /dev/null -w "%{http_code}" --max-time "${TIMEOUT}" "${WEB_URL}${path}")" \
    || fail "web ${path} unreachable"
  [[ "${code}" == "200" ]] || fail "web ${path} expected 200, got ${code}"
done

reg_body="$(curl -4s --max-time "${TIMEOUT}" -X POST "${API_URL}/api/v1/auth/register/" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${DOD_EMAIL}\"}")" \
  || fail "register request failed"
echo "${reg_body}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "detail" in d, d' \
  || fail "register did not return generic detail: ${reg_body}"

# Activate via Django shell on the staging host (reads pending user + token).
# When running off-host without SSH/docker, set ACTIVATE_UID + ACTIVATE_TOKEN from the email.
if [[ -n "${ACTIVATE_UID:-}" && -n "${ACTIVATE_TOKEN:-}" ]]; then
  UID_B64="${ACTIVATE_UID}"
  ACT_TOKEN="${ACTIVATE_TOKEN}"
else
  activate_meta="$(
    cd "${STACK_DIR}"
    docker compose --profile app exec -T api \
      python manage.py shell -c "
import json
from django.contrib.auth import get_user_model
from apps.accounts.services.email import uid_for_user
from apps.accounts.tokens import account_activation_token
user = get_user_model().objects.get(email='${DOD_EMAIL}')
print(json.dumps({'uid': uid_for_user(user), 'token': account_activation_token.make_token(user)}))
"
  )" || fail "could not mint activation token on staging (set ACTIVATE_UID/ACTIVATE_TOKEN or run on host)"
  UID_B64="$(echo "${activate_meta}" | json_field "['uid']")"
  ACT_TOKEN="$(echo "${activate_meta}" | json_field "['token']")"
fi

act_body="$(curl -4s --max-time "${TIMEOUT}" -X POST "${API_URL}/api/v1/auth/activate/" \
  -H "Content-Type: application/json" \
  -d "{\"uid\":\"${UID_B64}\",\"token\":\"${ACT_TOKEN}\",\"password\":\"${DOD_PASSWORD}\",\"password_confirm\":\"${DOD_PASSWORD}\"}")" \
  || fail "activate request failed"
echo "${act_body}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("email"), d' \
  || fail "activate did not return user: ${act_body}"

tok_body="$(curl -4s --max-time "${TIMEOUT}" -X POST "${API_URL}/api/v1/auth/token/" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${DOD_EMAIL}\",\"password\":\"${DOD_PASSWORD}\"}")" \
  || fail "token request failed"
ACCESS="$(echo "${tok_body}" | json_field "['access']")" \
  || fail "token response missing access: ${tok_body}"

# Password-reset round-trip (request always 200; confirm via minted token on host).
reset_req="$(curl -4s --max-time "${TIMEOUT}" -X POST "${API_URL}/api/v1/auth/password-reset/" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${DOD_EMAIL}\"}")" \
  || fail "password-reset request failed"
echo "${reset_req}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "detail" in d, d' \
  || fail "password-reset missing detail: ${reset_req}"

if [[ -n "${RESET_UID:-}" && -n "${RESET_TOKEN:-}" ]]; then
  R_UID="${RESET_UID}"
  R_TOKEN="${RESET_TOKEN}"
else
  reset_meta="$(
    cd "${STACK_DIR}"
    docker compose --profile app exec -T api \
      python manage.py shell -c "
import json
from django.contrib.auth import get_user_model
from apps.accounts.services.email import uid_for_user
from apps.accounts.tokens import password_reset_token
user = get_user_model().objects.get(email='${DOD_EMAIL}')
print(json.dumps({'uid': uid_for_user(user), 'token': password_reset_token.make_token(user)}))
"
  )" || fail "could not mint reset token on staging (set RESET_UID/RESET_TOKEN or run on host)"
  R_UID="$(echo "${reset_meta}" | json_field "['uid']")"
  R_TOKEN="$(echo "${reset_meta}" | json_field "['token']")"
fi

NEW_PASSWORD="${DOD_PASSWORD}-r"
reset_confirm="$(curl -4s --max-time "${TIMEOUT}" -X POST "${API_URL}/api/v1/auth/password-reset/confirm/" \
  -H "Content-Type: application/json" \
  -d "{\"uid\":\"${R_UID}\",\"token\":\"${R_TOKEN}\",\"password\":\"${NEW_PASSWORD}\",\"password_confirm\":\"${NEW_PASSWORD}\"}")" \
  || fail "password-reset confirm failed"
echo "${reset_confirm}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "detail" in d, d' \
  || fail "password-reset confirm unexpected: ${reset_confirm}"

tok_body="$(curl -4s --max-time "${TIMEOUT}" -X POST "${API_URL}/api/v1/auth/token/" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${DOD_EMAIL}\",\"password\":\"${NEW_PASSWORD}\"}")" \
  || fail "token after reset failed"
ACCESS="$(echo "${tok_body}" | json_field "['access']")" \
  || fail "token after reset missing access: ${tok_body}"
DOD_PASSWORD="${NEW_PASSWORD}"

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
