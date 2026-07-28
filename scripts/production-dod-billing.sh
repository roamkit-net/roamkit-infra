#!/usr/bin/env bash
# Gate C production billing DoD: billing env → deposit-info → verify → ledger → balance → order.
#
# No feature code — ops verification against a live production stack (or dress-rehearsal with URL overrides).
#
# Automated path uses CreditService.admin_adjust to credit (stand-in for a verified
# on-chain deposit). Real USDT deposit+verify is optional via VERIFY_TX_HASH.
#
# Usage (on production host or via SSH with docker access):
#   ./scripts/production-dod-billing.sh
#   SKIP_ORDER=1 ./scripts/production-dod-billing.sh          # stop after ledger/balance
#   VERIFY_TX_HASH=0x... ./scripts/production-dod-billing.sh  # real CEX verify path
#
# Env:
#   API_URL, WEB_URL, STACK_DIR, DOD_EMAIL, DOD_PASSWORD
#   PACKAGE_ID (optional; cheapest active package used when unset)
#   CREDIT_AMOUNT (default 5.000000)
#   SKIP_ORDER (0|1), VERIFY_TX_HASH (optional real Polygon USDT tx)
set -euo pipefail

API_URL="${API_URL:-https://api.roamkit.net}"
WEB_URL="${WEB_URL:-https://roamkit.net}"
STACK_DIR="${ROAMKIT_PRODUCTION_DIR:-/opt/stacks/roamkit-production}"
DOD_EMAIL="${DOD_EMAIL:-prod-billing-dod-$(date +%s)@example.com}"
DOD_PASSWORD="${DOD_PASSWORD:-SecurePass1!}"
TIMEOUT="${SMOKE_TIMEOUT:-45}"
CREDIT_AMOUNT="${CREDIT_AMOUNT:-5.000000}"
SKIP_ORDER="${SKIP_ORDER:-0}"
VERIFY_TX_HASH="${VERIFY_TX_HASH:-}"
PACKAGE_ID="${PACKAGE_ID:-}"

fail() {
  echo "PRODUCTION BILLING DoD FAILED: $*" >&2
  exit 1
}

json_field() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d$1)"
}

expect_http() {
  local url="$1"
  local expected="$2"
  local label="$3"
  local code
  code="$(curl -4s -o /dev/null -w "%{http_code}" --max-time "${TIMEOUT}" "${url}")" \
    || fail "${label} unreachable (${url})"
  [[ "${code}" == "${expected}" ]] || fail "${label} expected HTTP ${expected}, got ${code}"
}

echo "Gate C production billing DoD against ${API_URL}"
echo "Email: ${DOD_EMAIL}"

# --- Web surfaces ---
expect_http "${WEB_URL}/me/deposit" "200" "web /me/deposit"

# --- Env gate (must be set on server .env; defaults alone are not enough for deposits) ---
env_check="$(
  cd "${STACK_DIR}"
  docker compose --profile app exec -T api python3 -c "
import json
from django.conf import settings
payload = {
    'billing_enabled': bool(settings.BILLING_ENABLED),
    'walletconnect_enabled': bool(settings.WALLETCONNECT_ENABLED),
    'subscriptions_enabled': bool(settings.SUBSCRIPTIONS_ENABLED),
    'rpc_url': bool((settings.POLYGON_RPC_URL or '').strip()),
    'wallet': (settings.POLYGON_PLATFORM_WALLET or '').strip(),
    'contract': (settings.POLYGON_USDT_CONTRACT or '').strip(),
    'chain_id': int(settings.POLYGON_CHAIN_ID),
    'min_confirmations': int(settings.POLYGON_MIN_CONFIRMATIONS),
}
print(json.dumps(payload))
"
)" || fail "could not read billing settings from api container"

echo "${env_check}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["billing_enabled"] is True, d
assert d["walletconnect_enabled"] is False, "WALLETCONNECT_ENABLED must stay false until AppKit confirmed"
assert d["rpc_url"] is True, "POLYGON_RPC_URL is required"
assert d["wallet"].startswith("0x") and len(d["wallet"])==42, f"POLYGON_PLATFORM_WALLET invalid: {d}"
assert d["contract"].startswith("0x") and len(d["contract"])==42, f"POLYGON_USDT_CONTRACT invalid: {d}"
assert d["chain_id"]==137, d
assert d["min_confirmations"]>=1, d
print("env OK billing=%s wc=%s chain=%s wallet=%s…" % (
    d["billing_enabled"], d["walletconnect_enabled"], d["chain_id"], d["wallet"][:10]))
' || fail "billing env gate failed: ${env_check}"

# --- Auth (register → activate → token) ---
reg_body="$(curl -4s --max-time "${TIMEOUT}" -X POST "${API_URL}/api/v1/auth/register/" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${DOD_EMAIL}\"}")" \
  || fail "register request failed"
echo "${reg_body}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "detail" in d, d' \
  || fail "register unexpected: ${reg_body}"

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
  )" || fail "could not mint activation token (set ACTIVATE_UID/ACTIVATE_TOKEN or run on host)"
  UID_B64="$(echo "${activate_meta}" | json_field "['uid']")"
  ACT_TOKEN="$(echo "${activate_meta}" | json_field "['token']")"
fi

act_body="$(curl -4s --max-time "${TIMEOUT}" -X POST "${API_URL}/api/v1/auth/activate/" \
  -H "Content-Type: application/json" \
  -d "{\"uid\":\"${UID_B64}\",\"token\":\"${ACT_TOKEN}\",\"password\":\"${DOD_PASSWORD}\",\"password_confirm\":\"${DOD_PASSWORD}\"}")" \
  || fail "activate request failed"
echo "${act_body}" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("email"), d' \
  || fail "activate unexpected: ${act_body}"

tok_body="$(curl -4s --max-time "${TIMEOUT}" -X POST "${API_URL}/api/v1/auth/token/" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${DOD_EMAIL}\",\"password\":\"${DOD_PASSWORD}\"}")" \
  || fail "token request failed"
ACCESS="$(echo "${tok_body}" | json_field "['access']")" \
  || fail "token missing access: ${tok_body}"
AUTH_H=(-H "Authorization: Bearer ${ACCESS}" -H "Content-Type: application/json")

# --- deposit-info SSoT ---
info_body="$(curl -4s --max-time "${TIMEOUT}" "${API_URL}/api/v1/billing/deposit-info/" \
  "${AUTH_H[@]}")" || fail "deposit-info request failed"
echo "${info_body}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for key in ("wallet","chain_id","token_symbol","token_decimals","contract","min_confirmations","eip681_uri"):
    assert d.get(key) not in (None,""), f"missing {key}: {d}"
assert d["token_symbol"]=="USDT", d
assert d["chain_id"]==137, d
assert d["walletconnect_enabled"] is False, d
assert "transfer?address=" in d["eip681_uri"], d
print("deposit-info OK wallet=%s contract=%s…" % (d["wallet"][:10], d["contract"][:10]))
' || fail "deposit-info payload invalid: ${info_body}"

# --- balance starts at zero ---
bal0="$(curl -4s --max-time "${TIMEOUT}" "${API_URL}/api/v1/billing/balance/" \
  "${AUTH_H[@]}")" || fail "balance request failed"
echo "${bal0}" | python3 -c '
import json,sys
from decimal import Decimal
d=json.load(sys.stdin)
assert Decimal(d["balance"])==Decimal("0"), d
print("balance OK 0")
' || fail "expected zero balance: ${bal0}"

if [[ -z "${PACKAGE_ID}" ]]; then
  PACKAGE_ID="$(curl -4sf --max-time "${TIMEOUT}" "${API_URL}/api/v1/packages/?page_size=50" \
    | python3 -c '
import json,sys
from decimal import Decimal
rows=json.load(sys.stdin).get("results") or []
rows=sorted(rows, key=lambda r: Decimal(r["price_usd"]))
assert rows, "no packages"
print(rows[0]["id"])
')" || fail "could not resolve PACKAGE_ID"
fi
echo "Using package ${PACKAGE_ID}"

# Spend before deposit must 402.
underfund_code="$(curl -4s -o /tmp/billing_order_402.json -w "%{http_code}" --max-time "${TIMEOUT}" \
  -X POST "${API_URL}/api/v1/orders/" \
  "${AUTH_H[@]}" \
  -d "{\"package_id\":\"${PACKAGE_ID}\",\"idempotency_key\":\"order-under-$(date +%s)\"}")" \
  || fail "orders unreachable"
[[ "${underfund_code}" == "402" ]] || fail "order expected 402 before deposit, got ${underfund_code}: $(cat /tmp/billing_order_402.json)"
echo "order 402 OK (insufficient credits)"

# --- verify path ---
# WalletConnect verify must stay gated off.
FAKE_TX="0x$(python3 -c 'print("11"*32)')"
wc_code="$(curl -4s -o /tmp/billing_wc.json -w "%{http_code}" --max-time "${TIMEOUT}" \
  -X POST "${API_URL}/api/v1/billing/verify-wallet/" \
  "${AUTH_H[@]}" \
  -d "{\"tx_hash\":\"${FAKE_TX}\",\"amount_requested\":\"1.000000\",\"idempotency_key\":\"wc-gate-$(date +%s)\"}")" \
  || fail "verify-wallet unreachable"
[[ "${wc_code}" == "403" ]] || fail "verify-wallet expected 403 while WALLETCONNECT_ENABLED=false, got ${wc_code}"

if [[ -n "${VERIFY_TX_HASH}" ]]; then
  echo "Real CEX verify for ${VERIFY_TX_HASH}..."
  ver_code="$(curl -4s -o /tmp/billing_verify.json -w "%{http_code}" --max-time "${TIMEOUT}" \
    -X POST "${API_URL}/api/v1/billing/verify-cex/" \
    "${AUTH_H[@]}" \
    -d "{\"tx_hash\":\"${VERIFY_TX_HASH}\",\"amount_requested\":\"${CREDIT_AMOUNT}\",\"idempotency_key\":\"cex-real-$(date +%s)\"}")" \
    || fail "verify-cex unreachable"
  if [[ "${ver_code}" != "200" && "${ver_code}" != "202" ]]; then
    fail "verify-cex expected 200/202, got ${ver_code}: $(cat /tmp/billing_verify.json)"
  fi
  echo "verify-cex HTTP ${ver_code}"
else
  # Negative path: bogus hash must hit RPC and fail (proves verify + POLYGON_RPC_URL).
  bogus="0xdead$(python3 -c 'import secrets; print(secrets.token_hex(29))')"
  ver_code="$(curl -4s -o /tmp/billing_verify.json -w "%{http_code}" --max-time "${TIMEOUT}" \
    -X POST "${API_URL}/api/v1/billing/verify-cex/" \
    "${AUTH_H[@]}" \
    -d "{\"tx_hash\":\"${bogus}\",\"amount_requested\":\"1.000000\",\"idempotency_key\":\"cex-neg-$(date +%s)-$RANDOM\"}")" \
    || fail "verify-cex unreachable"
  case "${ver_code}" in
    400|409|502) echo "verify-cex negative path OK (HTTP ${ver_code})" ;;
    *) fail "verify-cex negative expected 400/409/502, got ${ver_code}: $(cat /tmp/billing_verify.json)" ;;
  esac

  # Credit stand-in for a verified deposit (CreditService only).
  echo "Admin-adjust credit ${CREDIT_AMOUNT} (deposit stand-in)..."
  credit_meta="$(
    cd "${STACK_DIR}"
    docker compose --profile app exec -T api \
      python manage.py shell -c "
import json
from decimal import Decimal
from django.contrib.auth import get_user_model
from apps.billing.services import credit_service, ensure_billing_account
user = get_user_model().objects.get(email='${DOD_EMAIL}')
account = ensure_billing_account(user)
entry = credit_service.admin_adjust(
    account,
    Decimal('${CREDIT_AMOUNT}'),
    credit=True,
    reason='production-dod-billing deposit stand-in',
    actor_id='production-dod-billing',
    idempotency_key='production-dod-credit-${DOD_EMAIL}',
)
ledger_sum = credit_service.ledger_sum(account)
account.refresh_from_db()
print(json.dumps({
    'balance': str(account.balance),
    'ledger_sum': str(ledger_sum),
    'ledger_entry_id': str(entry.pk),
    'reference_type': entry.reference_type,
}))
"
  )" || fail "admin_adjust credit failed"
  echo "${credit_meta}" | python3 -c '
import json,sys
from decimal import Decimal
d=json.load(sys.stdin)
assert Decimal(d["balance"])==Decimal(d["ledger_sum"]), d
assert Decimal(d["balance"])==Decimal("'"${CREDIT_AMOUNT}"'"), d
assert d["reference_type"]=="admin_adjustment", d
print("ledger==balance OK", d["balance"])
' || fail "ledger/balance mismatch after credit: ${credit_meta}"
fi

# Ensure enough funds for the chosen package (real verify may credit a different amount).
(
  cd "${STACK_DIR}"
  docker compose --profile app exec -T api \
    python manage.py shell -c "
from decimal import Decimal
from django.contrib.auth import get_user_model
from apps.billing.services import credit_service, ensure_billing_account
from apps.catalog.models import Package
user = get_user_model().objects.get(email='${DOD_EMAIL}')
account = ensure_billing_account(user)
pkg = Package.objects.get(external_id='${PACKAGE_ID}', is_active=True)
need = pkg.price_usd - account.balance
if need > 0:
    credit_service.admin_adjust(
        account,
        need,
        credit=True,
        reason='production-dod-billing top-up for order',
        actor_id='production-dod-billing',
        idempotency_key='production-dod-topup-${DOD_EMAIL}',
    )
print('funded')
"
) || fail "could not fund account for order"

# --- balance refresh via API ---
bal1="$(curl -4s --max-time "${TIMEOUT}" "${API_URL}/api/v1/billing/balance/" \
  "${AUTH_H[@]}")" || fail "balance after credit failed"
echo "${bal1}" | python3 -c '
import json,sys
from decimal import Decimal
d=json.load(sys.stdin)
assert Decimal(d["balance"]) > 0, d
print("API balance OK", d["balance"])
' || fail "expected positive balance: ${bal1}"

if [[ "${SKIP_ORDER}" == "1" ]]; then
  echo "SKIP_ORDER=1 — stopping before fulfillment"
  echo "PRODUCTION BILLING DoD PASSED (ledger/balance only)"
  exit 0
fi

order_code="$(curl -4s -o /tmp/billing_order.json -w "%{http_code}" --max-time 120 \
  -X POST "${API_URL}/api/v1/orders/" \
  "${AUTH_H[@]}" \
  -d "{\"package_id\":\"${PACKAGE_ID}\",\"idempotency_key\":\"order-ok-$(date +%s)\"}")" \
  || fail "order request failed"
[[ "${order_code}" == "201" ]] || fail "order expected 201, got ${order_code}: $(cat /tmp/billing_order.json)"
python3 -c '
import json
d=json.load(open("/tmp/billing_order.json"))
assert d.get("id") or d.get("status"), d
print("order OK id=%s status=%s" % (d.get("id"), d.get("status")))
' || fail "order payload unexpected: $(cat /tmp/billing_order.json)"

# Ledger still matches balance cache after spend
(
  cd "${STACK_DIR}"
  docker compose --profile app exec -T api \
    python manage.py shell -c "
import json
from django.contrib.auth import get_user_model
from apps.billing.services import credit_service, ensure_billing_account
user = get_user_model().objects.get(email='${DOD_EMAIL}')
account = ensure_billing_account(user)
account.refresh_from_db()
ledger_sum = credit_service.ledger_sum(account)
assert account.balance == ledger_sum, (account.balance, ledger_sum)
print(json.dumps({'balance': str(account.balance), 'ledger_sum': str(ledger_sum)}))
"
) || fail "post-order ledger/balance drift"

echo "PRODUCTION BILLING DoD PASSED"
