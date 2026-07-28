#!/usr/bin/env bash
# Phase 7 — Airalo preflight (hard STOP before first live order).
#
# Checks configuration consistency and stack isolation. Does NOT authenticate
# against Airalo (credential validity is validated by live / staging smoke).
#
# Usage (on production host, after API image with AIRALO_ENABLED is deployed):
#   EXPECTED_GIT_SHA=<prod api sha> \
#   CONFIRM_SENTRY_GREEN=1 CONFIRM_KUMA_GREEN=1 \
#   CONFIRM_STAGING_PARTNER=Roamkit-Sandbox \
#   CONFIRM_PRODUCTION_PARTNER='Fine Star' \
#     ./scripts/phase7-airalo-preflight.sh
#
# Env:
#   PRODUCTION_DIR / STAGING_DIR (stack roots)
#   API_URL (default https://api.roamkit.net)
#   EXPECTED_GIT_SHA (required — must match GET /version git_sha)
#   CONFIRM_SENTRY_GREEN=1  CONFIRM_KUMA_GREEN=1  (operator attestation)
#   CONFIRM_STAGING_PARTNER / CONFIRM_PRODUCTION_PARTNER (partner identity)
set -euo pipefail

API_URL="${API_URL:-https://api.roamkit.net}"
PRODUCTION_DIR="${ROAMKIT_PRODUCTION_DIR:-/opt/stacks/roamkit-production}"
STAGING_DIR="${ROAMKIT_STAGING_DIR:-/opt/stacks/roamkit-net}"
EXPECTED_GIT_SHA="${EXPECTED_GIT_SHA:-}"
CONFIRM_SENTRY_GREEN="${CONFIRM_SENTRY_GREEN:-0}"
CONFIRM_KUMA_GREEN="${CONFIRM_KUMA_GREEN:-0}"
CONFIRM_STAGING_PARTNER="${CONFIRM_STAGING_PARTNER:-}"
CONFIRM_PRODUCTION_PARTNER="${CONFIRM_PRODUCTION_PARTNER:-}"
TIMEOUT="${SMOKE_TIMEOUT:-30}"

fail() {
  echo "PHASE7 PREFLIGHT FAILED: $*" >&2
  echo "STOP — do not run CONFIRM_LIVE_ORDER=1 production-dod-airalo-phase7.sh" >&2
  exit 1
}

pass() {
  echo "  PASS  $*"
}

read_airalo_json() {
  local stack_dir="$1"
  cd "${stack_dir}"
  docker compose --profile app exec -T api python3 -c "
import json
from django.conf import settings
cid = (settings.AIRALO_CLIENT_ID or '').strip()
blocked = [
    x.strip()
    for x in (getattr(settings, 'AIRALO_BLOCKED_CLIENT_IDS', '') or '').split(',')
    if x.strip()
]
print(json.dumps({
    'airalo_sandbox': bool(settings.AIRALO_SANDBOX),
    'airalo_enabled': bool(getattr(settings, 'AIRALO_ENABLED', True)),
    'client_id': cid,
    'client_id_set': bool(cid),
    'client_secret_set': bool((settings.AIRALO_CLIENT_SECRET or '').strip()),
    'blocked_ids': blocked,
    'client_id_blocked': cid in blocked if cid else False,
    'environment': getattr(settings, 'ROAMKIT_ENVIRONMENT', '') or '',
}))
"
}

echo "Phase 7 Airalo preflight"
echo "  production=${PRODUCTION_DIR}"
echo "  staging=${STAGING_DIR}"
echo "  api=${API_URL}"
echo

[[ -n "${EXPECTED_GIT_SHA}" ]] || fail "set EXPECTED_GIT_SHA to the expected production GET /version git_sha"
[[ "${CONFIRM_SENTRY_GREEN}" == "1" ]] || fail "set CONFIRM_SENTRY_GREEN=1 after verifying Sentry is GREEN"
[[ "${CONFIRM_KUMA_GREEN}" == "1" ]] || fail "set CONFIRM_KUMA_GREEN=1 after verifying Uptime Kuma is GREEN"
[[ "${CONFIRM_STAGING_PARTNER}" == "Roamkit-Sandbox" ]] \
  || fail "set CONFIRM_STAGING_PARTNER=Roamkit-Sandbox (partner identity attestation)"
[[ "${CONFIRM_PRODUCTION_PARTNER}" == "Fine Star" ]] \
  || fail "set CONFIRM_PRODUCTION_PARTNER='Fine Star' (partner identity attestation)"

pass "operator attestations (Sentry, Kuma, partner identities)"

prod_json="$(read_airalo_json "${PRODUCTION_DIR}")" \
  || fail "could not read Airalo settings from production api"
stg_json="$(read_airalo_json "${STAGING_DIR}")" \
  || fail "could not read Airalo settings from staging api"

echo "${prod_json}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["airalo_sandbox"] is False, d
assert d["airalo_enabled"] is True, d
assert d["client_id_set"] and d["client_secret_set"], d
print("prod config OK")
' || fail "production Airalo config inconsistent: ${prod_json}"
pass "production AIRALO_SANDBOX=false AIRALO_ENABLED=true credentials present"

echo "${stg_json}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["airalo_sandbox"] is True, ("staging must keep sandbox=true", d)
# After Roamkit-Sandbox keys: staging may call Airalo, but never Fine Star live.
# Reject live-capable config: blocked Fine Star client_id in use.
assert not d["client_id_blocked"], (
    "staging AIRALO_CLIENT_ID is Fine Star live (blocked)",
    {"cid_prefix": (d.get("client_id") or "")[:6] + "…"},
)
if d["airalo_enabled"]:
    assert d["client_id_set"] and d["client_secret_set"], (
        "staging AIRALO_ENABLED=true requires sandbox credentials",
        d,
    )
print("staging sandbox-ready OK")
' || fail "staging Airalo config not sandbox-ready (redacted)"
pass "staging on Roamkit-Sandbox path (sandbox=true, not Fine Star)"

python3 -c '
import json,sys
prod=json.loads(sys.argv[1])
stg=json.loads(sys.argv[2])
pcid=prod["client_id"]
scid=stg["client_id"]
assert pcid, "production client_id empty"
if scid:
    assert scid != pcid, "staging client_id must differ from production Fine Star id"
    assert scid not in prod.get("blocked_ids", []), "unexpected"
# If staging has a client_id, production id should be on the denylist when set.
blocked=stg.get("blocked_ids") or []
if blocked:
    assert pcid in blocked, (
        "staging AIRALO_BLOCKED_CLIENT_IDS must include production Fine Star client_id",
        {"prod_prefix": pcid[:6]+"…", "blocked_count": len(blocked)},
    )
print("client_id isolation OK")
' "${prod_json}" "${stg_json}" \
  || fail "staging/production Airalo client_id isolation failed"
pass "staging client_id isolated from production Fine Star"

version_json="$(curl -4sS --max-time "${TIMEOUT}" "${API_URL}/version")" \
  || fail "GET ${API_URL}/version failed"
echo "${version_json}" | EXPECTED_GIT_SHA="${EXPECTED_GIT_SHA}" python3 -c '
import json,sys,os
d=json.load(sys.stdin)
expected=os.environ["EXPECTED_GIT_SHA"].strip()
got=(d.get("git_sha") or "").strip()
assert got == expected, {"expected": expected, "got": got, "body": d}
print("version OK", got)
' || fail "production /version SHA mismatch (EXPECTED_GIT_SHA=${EXPECTED_GIT_SHA}): ${version_json}"
pass "production GET /version matches EXPECTED_GIT_SHA=${EXPECTED_GIT_SHA}"

pass "partner identity attested: staging=Roamkit-Sandbox production=Fine Star"

echo
echo "PHASE7 PREFLIGHT PASS — safe to run live smoke when ready:"
echo "  CONFIRM_LIVE_ORDER=1 ./scripts/production-dod-airalo-phase7.sh"
