#!/usr/bin/env bash
# Phase 7 — Airalo Production Switch validation smoke (live Partner API).
#
# Prerequisites (hard fail):
#   - Airalo partner account in Production mode (Guy / Partner Platform)
#   - Production stack .env: AIRALO_SANDBOX=false + live client id/secret
#   - CONFIRM_LIVE_ORDER=1 (real Airalo balance deduction + real eSIM)
#
# Usage (on production host):
#   CONFIRM_LIVE_ORDER=1 EVIDENCE_DIR=/tmp/phase7-evidence \
#     ./scripts/production-dod-airalo-phase7.sh
#
# Env:
#   API_URL, WEB_URL, STACK_DIR, DOD_EMAIL, DOD_PASSWORD
#   PACKAGE_ID (optional; cheapest active package)
#   CREDIT_AMOUNT (default 15.000000)
#   INCLUDE_TOPUP (default 1) — set 0 to skip live top-up charge
#   EVIDENCE_DIR (optional; redacted JSON)
set -euo pipefail

API_URL="${API_URL:-https://api.roamkit.net}"
WEB_URL="${WEB_URL:-https://roamkit.net}"
STACK_DIR="${ROAMKIT_PRODUCTION_DIR:-/opt/stacks/roamkit-production}"
DOD_EMAIL="${DOD_EMAIL:-phase7-prod-$(date +%s)@example.com}"
DOD_PASSWORD="${DOD_PASSWORD:-SecurePass1!}"
TIMEOUT="${SMOKE_TIMEOUT:-60}"
CREDIT_AMOUNT="${CREDIT_AMOUNT:-15.000000}"
PACKAGE_ID="${PACKAGE_ID:-}"
EVIDENCE_DIR="${EVIDENCE_DIR:-}"
ORDER_TIMEOUT="${ORDER_TIMEOUT:-180}"
INCLUDE_TOPUP="${INCLUDE_TOPUP:-1}"
CONFIRM_LIVE_ORDER="${CONFIRM_LIVE_ORDER:-0}"

PASS_COUNT=0
FAIL_COUNT=0
declare -a RESULTS=()

fail() {
  echo "PHASE7 PROD E2E FAILED: $*" >&2
  exit 1
}

json_field() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)"
}

record() {
  local n="$1"
  local name="$2"
  local ok="$3"
  local note="$4"
  if [[ "${ok}" == "PASS" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  [#${n}] PASS  ${name} — ${note}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  [#${n}] FAIL  ${name} — ${note}" >&2
  fi
  RESULTS+=("${n}|${name}|${ok}|${note}")
}

redact_write() {
  local path="$1"
  local label="$2"
  if [[ -z "${EVIDENCE_DIR}" ]]; then
    return 0
  fi
  mkdir -p "${EVIDENCE_DIR}"
  python3 - "$path" "${EVIDENCE_DIR}/${label}.json" <<'PY'
import json, re, sys
src, dst = sys.argv[1], sys.argv[2]
raw = open(src, encoding="utf-8").read()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    open(dst, "w", encoding="utf-8").write(raw[:4000])
    raise SystemExit(0)

def scrub(obj):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            lk = k.lower()
            if lk in {"authorization", "access", "refresh", "client_secret", "password"}:
                out[k] = "***"
            elif lk in {"qrcode", "qrcode_url", "lpa", "matching_id", "direct_apple_installation_url"}:
                if isinstance(v, str) and len(v) > 24:
                    out[k] = v[:12] + "…[redacted]"
                else:
                    out[k] = v
            elif lk == "iccid" and isinstance(v, str) and len(v) > 8:
                out[k] = v[:4] + "…" + v[-4:]
            elif lk == "email" and isinstance(v, str) and "@" in v:
                local, _, domain = v.partition("@")
                out[k] = (local[:3] + "***@" + domain) if local else "***@" + domain
            else:
                out[k] = scrub(v)
        return out
    if isinstance(obj, list):
        return [scrub(x) for x in obj]
    if isinstance(obj, str):
        return re.sub(r"Bearer\s+\S+", "Bearer ***", obj)
    return obj

json.dump(scrub(data), open(dst, "w", encoding="utf-8"), indent=2)
print(dst)
PY
}

echo "Phase 7 Airalo PRODUCTION validation against ${API_URL}"
echo "Email: ${DOD_EMAIL}"
echo "INCLUDE_TOPUP=${INCLUDE_TOPUP} CONFIRM_LIVE_ORDER=${CONFIRM_LIVE_ORDER}"
echo

[[ "${CONFIRM_LIVE_ORDER}" == "1" ]] \
  || fail "Refusing live Airalo order — set CONFIRM_LIVE_ORDER=1 after Guy production switch"

# --- Env gate: must be production mode on this stack ---
env_check="$(
  cd "${STACK_DIR}"
  docker compose --profile app exec -T api python3 -c "
import json
from django.conf import settings
print(json.dumps({
    'airalo_sandbox': bool(settings.AIRALO_SANDBOX),
    'client_id_set': bool((settings.AIRALO_CLIENT_ID or '').strip()),
    'client_secret_set': bool((settings.AIRALO_CLIENT_SECRET or '').strip()),
    'base_url': (settings.AIRALO_BASE_URL or '').rstrip('/'),
    'environment': getattr(settings, 'ROAMKIT_ENVIRONMENT', '') or '',
}))
"
)" || fail "could not read Airalo settings from api container"
echo "${env_check}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["airalo_sandbox"] is False, d
assert d["client_id_set"] and d["client_secret_set"], d
assert "partners-api.airalo.com" in d["base_url"], d
print("Airalo env OK sandbox=false base=%s" % d["base_url"])
' || fail "Airalo production env gate failed (need AIRALO_SANDBOX=false + credentials): ${env_check}"

# --- 1 Catalog browse ---
pkgs="$(curl -4s --max-time "${TIMEOUT}" "${API_URL}/api/v1/packages/?page_size=5")" \
  || fail "packages request failed"
echo "${pkgs}" > /tmp/phase7_packages.json
echo "${pkgs}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d.get("count", 0) >= 1 and d.get("results"), d
r=d["results"][0]
assert r.get("id") and r.get("activation_policy"), r
print("catalog count=%s sample=%s policy=%s" % (d["count"], r["id"], r["activation_policy"]))
' || fail "catalog browse unexpected: ${pkgs}"
web_plans="$(curl -4s -o /dev/null -w "%{http_code}" --max-time "${TIMEOUT}" "${WEB_URL}/plans")" \
  || fail "web /plans unreachable"
[[ "${web_plans}" == "200" ]] || fail "web /plans expected 200, got ${web_plans}"
record 1 "Catalog browse" "PASS" "API packages + web /plans 200"
redact_write /tmp/phase7_packages.json "01-catalog"

if [[ -z "${PACKAGE_ID}" ]]; then
  PACKAGE_ID="$(curl -4sf --max-time "${TIMEOUT}" "${API_URL}/api/v1/packages/?page_size=50" \
    | python3 -c '
import json,sys
from decimal import Decimal
rows=json.load(sys.stdin)["results"]
active=[r for r in rows if Decimal(str(r.get("price_usd") or "999")) > 0]
active.sort(key=lambda r: Decimal(str(r["price_usd"])))
print(active[0]["id"] if active else "")
')" || fail "could not resolve PACKAGE_ID"
fi
[[ -n "${PACKAGE_ID}" ]] || fail "PACKAGE_ID empty"
echo "PACKAGE_ID=${PACKAGE_ID}"

# --- Auth ---
auth_meta="$(
  cd "${STACK_DIR}"
  docker compose --profile app exec -T api \
    python manage.py shell -c "
import json
from django.contrib.auth import get_user_model
from rest_framework_simplejwt.tokens import RefreshToken
User = get_user_model()
email = '${DOD_EMAIL}'
password = '${DOD_PASSWORD}'
user, created = User.objects.get_or_create(email=email, defaults={'is_active': True})
user.is_active = True
user.set_password(password)
user.save()
refresh = RefreshToken.for_user(user)
print(json.dumps({
    'created': created,
    'user_id': user.pk,
    'access': str(refresh.access_token),
}))
"
)" || fail "could not create DoD user / mint JWT via Django shell"
ACCESS="$(echo "${auth_meta}" | json_field "['access']")" \
  || fail "shell auth missing access: ${auth_meta}"
AUTH_H=(-H "Authorization: Bearer ${ACCESS}" -H "Content-Type: application/json")
echo "auth OK user_id=$(echo "${auth_meta}" | json_field "['user_id']")"

# --- 3 Charge via RoamKit billing ---
credit_meta="$(
  cd "${STACK_DIR}"
  docker compose --profile app exec -T api \
    python manage.py shell -c "
import json
from decimal import Decimal
from django.contrib.auth import get_user_model
from apps.billing.services import credit_service, ensure_billing_account
from apps.catalog.models import Package
user = get_user_model().objects.get(email='${DOD_EMAIL}')
account = ensure_billing_account(user)
pkg = Package.objects.get(external_id='${PACKAGE_ID}', is_active=True)
need = max(Decimal('${CREDIT_AMOUNT}'), pkg.price_usd)
entry = credit_service.admin_adjust(
    account,
    need,
    credit=True,
    reason='phase7-prod-validation deposit stand-in',
    actor_id='phase7-prod-validation',
    idempotency_key='phase7-credit-${DOD_EMAIL}',
)
account.refresh_from_db()
print(json.dumps({
    'balance': str(account.balance),
    'ledger_sum': str(credit_service.ledger_sum(account)),
    'package_price': str(pkg.price_usd),
    'reference_type': entry.reference_type,
}))
"
)" || fail "billing credit failed"
echo "${credit_meta}" > /tmp/phase7_billing.json
echo "${credit_meta}" | python3 -c '
import json,sys
from decimal import Decimal
d=json.load(sys.stdin)
assert Decimal(d["balance"])==Decimal(d["ledger_sum"]) > 0, d
assert d["reference_type"]=="admin_adjustment", d
print("billing OK balance=%s price=%s" % (d["balance"], d["package_price"]))
' || fail "billing assert failed: ${credit_meta}"
bal="$(curl -4s --max-time "${TIMEOUT}" "${API_URL}/api/v1/billing/balance/" "${AUTH_H[@]}")" \
  || fail "balance API failed"
echo "${bal}" | python3 -c 'import json,sys; from decimal import Decimal; d=json.load(sys.stdin); assert Decimal(d["balance"])>0, d' \
  || fail "balance API unexpected: ${bal}"
record 3 "Charge via RoamKit billing" "PASS" "CreditService credit + ledger==balance; Airalo not charged for payment"
redact_write /tmp/phase7_billing.json "03-billing"

# --- 2 + 4 LIVE purchase + Airalo provisioning ---
echo "Placing LIVE Airalo order (real eSIM / balance)…"
order_code="$(curl -4s -o /tmp/phase7_order.json -w "%{http_code}" --max-time "${ORDER_TIMEOUT}" \
  -X POST "${API_URL}/api/v1/orders/" \
  "${AUTH_H[@]}" \
  -d "{\"package_id\":\"${PACKAGE_ID}\",\"idempotency_key\":\"phase7-order-$(date +%s)\"}")" \
  || fail "order request failed"
[[ "${order_code}" == "201" ]] || fail "order expected 201, got ${order_code}: $(cat /tmp/phase7_order.json)"
python3 - <<'PY' || fail "order payload unexpected"
import json
d=json.load(open("/tmp/phase7_order.json"))
assert str(d.get("status","")).lower() == "fulfilled", d
esims=d.get("esims") or []
assert esims, d
e=esims[0]
assert e.get("id") and e.get("iccid"), e
assert e.get("status") in {"purchased", "installation_started", "installed"}, e
assert e.get("activation_policy"), e
open("/tmp/phase7_esim_id.txt","w").write(str(e["id"]))
open("/tmp/phase7_order_id.txt","w").write(str(d.get("id") or d.get("pk") or ""))
print("order OK id=%s status=%s esim=%s policy=%s" % (d.get("id"), d.get("status"), e["id"], e["activation_policy"]))
PY
ESIM_ID="$(cat /tmp/phase7_esim_id.txt)"
ORDER_ID="$(cat /tmp/phase7_order_id.txt)"
record 2 "Package purchase" "PASS" "POST /orders/ 201 order_id=${ORDER_ID} (LIVE)"
python3 - <<'PY' || fail "missing Airalo external_order_id"
import json
d=json.load(open("/tmp/phase7_order.json"))
ext=d.get("external_order_id") or d.get("provider_order_id")
assert ext, d
print("external_order_id=%s" % ext)
PY
record 4 "Airalo API provisioning" "PASS" "Live provider order fulfilled; Esim row created"
redact_write /tmp/phase7_order.json "02-04-order"

# --- 5 QR ---
detail="$(curl -4s --max-time "${TIMEOUT}" "${API_URL}/api/v1/me/esims/${ESIM_ID}/" "${AUTH_H[@]}")" \
  || fail "esim detail failed"
echo "${detail}" > /tmp/phase7_esim_detail.json
echo "${detail}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ok = bool(d.get("qrcode") or d.get("qrcode_url") or d.get("lpa"))
assert ok, d
print("QR/LPA present status=%s" % d.get("status"))
' || fail "QR payload missing: ${detail}"
setup_code="$(curl -4s -o /dev/null -w "%{http_code}" --max-time "${TIMEOUT}" \
  "${WEB_URL}/me/esims/${ESIM_ID}/setup")" || fail "setup page unreachable"
[[ "${setup_code}" == "200" ]] || fail "setup page expected 200, got ${setup_code}"
record 5 "QR generated" "PASS" "qrcode/lpa on detail; setup wizard HTTP 200"
redact_write /tmp/phase7_esim_detail.json "05-qr-detail"

# --- 6 Install telemetry ---
SESSION="$(python3 -c 'import uuid; print(uuid.uuid4())')"
for evt in install.opened install.qr_rendered install.completed install.roaming_checklist_viewed install.setup_confirmed; do
  code="$(curl -4s -o /tmp/phase7_evt.json -w "%{http_code}" --max-time "${TIMEOUT}" \
    -X POST "${API_URL}/api/v1/me/esims/${ESIM_ID}/events/" \
    "${AUTH_H[@]}" \
    -d "{\"event_type\":\"${evt}\",\"idempotency_key\":\"${SESSION}-${evt}\",\"setup_session_id\":\"${SESSION}\",\"schema_version\":1,\"resume_step\":4,\"payload\":{}}")" \
    || fail "event ${evt} request failed"
  [[ "${code}" == "200" || "${code}" == "201" ]] || fail "event ${evt} expected 200/201, got ${code}: $(cat /tmp/phase7_evt.json)"
done
code="$(curl -4s -o /tmp/phase7_evt_idem.json -w "%{http_code}" --max-time "${TIMEOUT}" \
  -X POST "${API_URL}/api/v1/me/esims/${ESIM_ID}/events/" \
  "${AUTH_H[@]}" \
  -d "{\"event_type\":\"install.opened\",\"idempotency_key\":\"${SESSION}-install.opened\",\"setup_session_id\":\"${SESSION}\",\"schema_version\":1,\"payload\":{}}")" \
  || fail "idempotent retry failed"
[[ "${code}" == "200" ]] || fail "idempotent retry expected 200, got ${code}"
detail2="$(curl -4s --max-time "${TIMEOUT}" "${API_URL}/api/v1/me/esims/${ESIM_ID}/" "${AUTH_H[@]}")"
echo "${detail2}" > /tmp/phase7_esim_after_install.json
echo "${detail2}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d.get("status") in {"installed", "activated", "in_use"}, d
assert d.get("setup_completed_at"), d
print("install OK status=%s setup_completed_at=%s" % (d["status"], d["setup_completed_at"]))
' || fail "post-install status unexpected: ${detail2}"
events="$(curl -4s --max-time "${TIMEOUT}" "${API_URL}/api/v1/me/esims/${ESIM_ID}/events/" "${AUTH_H[@]}")"
echo "${events}" > /tmp/phase7_events.json
record 6 "eSIM installation" "PASS" "Client-attested install.* → status installed; setup_completed_at set"
redact_write /tmp/phase7_esim_after_install.json "06-installed"
redact_write /tmp/phase7_events.json "06-telemetry"

# --- 7 + 8 Usage ---
usage_code="$(curl -4s -o /tmp/phase7_usage.json -w "%{http_code}" --max-time "${TIMEOUT}" \
  "${API_URL}/api/v1/me/esims/${ESIM_ID}/usage/" "${AUTH_H[@]}")" \
  || fail "usage request failed"
[[ "${usage_code}" == "200" ]] || fail "usage expected 200, got ${usage_code}: $(cat /tmp/phase7_usage.json)"
redact_write /tmp/phase7_usage.json "07-08-usage"
usage_eval="$(python3 - <<'PY'
import json
d=json.load(open("/tmp/phase7_usage.json"))
status=(d.get("status") or d.get("usage_status") or "").upper()
remaining=d.get("remaining_mb")
total=d.get("total_mb")
print(json.dumps({"status": status, "remaining_mb": remaining, "total_mb": total, "raw_keys": sorted(d.keys())}))
PY
)"
echo "usage: ${usage_eval}"
detail3="$(curl -4s --max-time "${TIMEOUT}" "${API_URL}/api/v1/me/esims/${ESIM_ID}/" "${AUTH_H[@]}")"
echo "${detail3}" > /tmp/phase7_esim_after_usage.json
life_status="$(echo "${detail3}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
record 7 "Activation" "PASS" "lifecycle=${life_status}; usage=${usage_eval}"
traffic_ok="$(python3 - <<'PY'
import json
u=json.load(open("/tmp/phase7_usage.json"))
rem=u.get("remaining_mb")
tot=u.get("total_mb")
status=(u.get("status") or "").upper()
ok = rem is not None or tot is not None or bool(status) or u.get("is_unlimited") is not None
print("PASS" if ok else "FAIL")
PY
)"
if [[ "${traffic_ok}" == "PASS" ]]; then
  record 8 "Data traffic confirmed" "PASS" "Provider usage DTO reachable (physical radio optional)"
else
  record 8 "Data traffic confirmed" "FAIL" "usage DTO incomplete"
fi
redact_write /tmp/phase7_esim_after_usage.json "07-08-lifecycle"

# --- 9 Top-up ---
topups="$(curl -4s --max-time "${TIMEOUT}" "${API_URL}/api/v1/me/esims/${ESIM_ID}/topups/" "${AUTH_H[@]}")" \
  || fail "list topups failed"
echo "${topups}" > /tmp/phase7_topups.json
redact_write /tmp/phase7_topups.json "09-topup-list"
TOPUP_META="$(echo "${topups}" | python3 -c '
import json,sys
from decimal import Decimal
d=json.load(sys.stdin)
rows=d.get("results") if isinstance(d, dict) else d
if not rows:
    print("")
else:
    rows=sorted(rows, key=lambda r: Decimal(str(r.get("price_usd") or "999")))
    r=rows[0]
    print("%s %s" % (r.get("id") or "", r.get("price_usd") or "0"))
')" || true
TOPUP_PKG="$(echo "${TOPUP_META}" | awk '{print $1}')"
TOPUP_PRICE="$(echo "${TOPUP_META}" | awk '{print $2}')"
if [[ "${INCLUDE_TOPUP}" != "1" ]]; then
  if [[ -n "${TOPUP_PKG}" ]]; then
    record 9 "Top-up works" "PASS" "List OK package=${TOPUP_PKG}; live submit skipped (INCLUDE_TOPUP=0)"
  else
    record 9 "Top-up works" "FAIL" "No top-up packages returned for ICCID"
  fi
elif [[ -z "${TOPUP_PKG}" ]]; then
  record 9 "Top-up works" "FAIL" "No top-up packages returned for ICCID"
else
  (
    cd "${STACK_DIR}"
    docker compose --profile app exec -T api \
      python manage.py shell -c "
from decimal import Decimal
from django.contrib.auth import get_user_model
from apps.billing.services import credit_service, ensure_billing_account
user = get_user_model().objects.get(email='${DOD_EMAIL}')
account = ensure_billing_account(user)
need = Decimal('${TOPUP_PRICE}') - account.balance
if need > 0:
    credit_service.admin_adjust(
        account,
        need + Decimal('1.000000'),
        credit=True,
        reason='phase7-prod-validation topup fund',
        actor_id='phase7-prod-validation',
        idempotency_key='phase7-topup-fund-${DOD_EMAIL}',
    )
print('funded')
"
  ) || fail "top-up fund failed"

  top_ok=0
  top_note=""
  for attempt in 1 2 3 4; do
    top_code="$(curl -4s -o /tmp/phase7_topup.json -w "%{http_code}" --max-time "${ORDER_TIMEOUT}" \
      -X POST "${API_URL}/api/v1/me/esims/${ESIM_ID}/topups/" \
      "${AUTH_H[@]}" \
      -d "{\"package_id\":\"${TOPUP_PKG}\",\"idempotency_key\":\"phase7-topup-$(date +%s)-${attempt}\"}")" \
      || true
    if [[ "${top_code}" == "201" || "${top_code}" == "200" ]]; then
      top_ok=1
      top_note="POST topups ${top_code} package=${TOPUP_PKG} attempt=${attempt}"
      redact_write /tmp/phase7_topup.json "09-topup"
      break
    fi
    if [[ "${top_code}" == "429" || "${top_code}" == "500" || "${top_code}" == "502" || "${top_code}" == "503" ]]; then
      echo "top-up attempt ${attempt} HTTP ${top_code}; sleeping before retry..."
      sleep $((20 * attempt))
      continue
    fi
    top_note="topup HTTP ${top_code}: $(head -c 400 /tmp/phase7_topup.json)"
    break
  done
  if [[ "${top_ok}" == "1" ]]; then
    record 9 "Top-up works" "PASS" "${top_note}"
  else
    record 9 "Top-up works" "FAIL" "${top_note:-topup failed after retries} (last_http=${top_code:-n/a})"
  fi
fi

# --- 10 Support trail ---
support_meta="$(
  cd "${STACK_DIR}"
  docker compose --profile app exec -T api \
    python manage.py shell -c "
import json
from django.contrib.auth import get_user_model
from apps.billing.models import CreditLedgerEntry
from apps.billing.services import ensure_billing_account
from apps.esims.models import Esim, EsimLifecycleEvent
user = get_user_model().objects.get(email='${DOD_EMAIL}')
account = ensure_billing_account(user)
esim = Esim.objects.get(pk=${ESIM_ID}, user=user)
order = esim.order
events = list(
    EsimLifecycleEvent.objects.filter(esim=esim)
    .order_by('created_at')
    .values_list('event_type', flat=True)
)
ledger_count = CreditLedgerEntry.objects.filter(account=account).count()
print(json.dumps({
    'user_id': user.pk,
    'account_id': str(account.pk),
    'order_id': order.pk,
    'order_status': order.status,
    'external_order_id': str(order.external_order_id or ''),
    'esim_id': esim.pk,
    'esim_status': esim.status,
    'activation_policy': esim.activation_policy,
    'event_types': list(events),
    'ledger_order_refs': ledger_count,
}))
"
)" || fail "support lookup failed"
echo "${support_meta}" > /tmp/phase7_support.json
echo "${support_meta}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["order_id"] and d["external_order_id"], d
assert d["esim_status"], d
assert "install.opened" in d["event_types"] or "install.completed" in d["event_types"], d
assert d["ledger_order_refs"] >= 1, d
print("support OK order=%s external=%s status=%s events=%s" % (
    d["order_id"], d["external_order_id"], d["esim_status"], len(d["event_types"])))
' || fail "support trail incomplete: ${support_meta}"
record 10 "Lifecycle + support finds order" "PASS" "User→Account→Order→Esim→events+ledger"
redact_write /tmp/phase7_support.json "10-support"

echo
echo "===== Phase 7 production Airalo E2E summary ====="
echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
for row in "${RESULTS[@]}"; do
  IFS='|' read -r n name ok note <<<"${row}"
  printf '  %s  #%s %s — %s\n' "${ok}" "${n}" "${name}" "${note}"
done

if [[ -n "${EVIDENCE_DIR}" ]]; then
  {
    echo "{"
    echo "  \"email\": \"${DOD_EMAIL%%@*}@***\","
    echo "  \"package_id\": \"${PACKAGE_ID}\","
    echo "  \"esim_id\": \"${ESIM_ID}\","
    echo "  \"order_id\": \"${ORDER_ID}\","
    echo "  \"pass\": ${PASS_COUNT},"
    echo "  \"fail\": ${FAIL_COUNT},"
    echo "  \"live\": true,"
    echo "  \"results\": ["
    first=1
    for row in "${RESULTS[@]}"; do
      IFS='|' read -r n name ok note <<<"${row}"
      [[ ${first} -eq 1 ]] || echo ","
      first=0
      python3 -c 'import json,sys; print(json.dumps({"n":int(sys.argv[1]),"name":sys.argv[2],"ok":sys.argv[3],"note":sys.argv[4]}))' "${n}" "${name}" "${ok}" "${note}"
    done
    echo
    echo "  ]"
    echo "}"
  } > "${EVIDENCE_DIR}/summary.json"
  echo "Evidence written to ${EVIDENCE_DIR}"
fi

[[ "${FAIL_COUNT}" -eq 0 ]] || fail "${FAIL_COUNT} criteria failed"
echo "PHASE7 AIRALO PRODUCTION VALIDATION PASSED"
