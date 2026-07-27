#!/usr/bin/env bash
# Staging safeguard for Phase 7 Airalo Production Switch.
#
# Staging and production historically share the same Airalo client_id.
# When the partner account flips to Production mode, staging orders become LIVE
# unless staging has a dedicated sandbox credential pair.
#
# This script PAUSES Airalo fulfillment on staging by clearing credentials
# (catalog sync / orders will fail closed until sandbox keys are restored).
#
# Usage (on staging host):
#   ./scripts/staging-pause-airalo.sh          # clear credentials + recreate
#   ./scripts/staging-pause-airalo.sh restore  # restore from .env.airalo.bak
set -euo pipefail

STACK_DIR="${ROAMKIT_STAGING_DIR:-/opt/stacks/roamkit-net}"
ENV_FILE="${STACK_DIR}/.env"
BAK_FILE="${STACK_DIR}/.env.airalo.bak"
MODE="${1:-pause}"

cd "${STACK_DIR}"

fail() {
  echo "STAGING AIRALO PAUSE FAILED: $*" >&2
  exit 1
}

[[ -f "${ENV_FILE}" ]] || fail "missing ${ENV_FILE}"

if [[ "${MODE}" == "restore" ]]; then
  [[ -f "${BAK_FILE}" ]] || fail "missing backup ${BAK_FILE}"
  # shellcheck disable=SC1090
  # Restore only AIRALO_* lines from backup into .env
  python3 - "${ENV_FILE}" "${BAK_FILE}" <<'PY'
import sys
env_path, bak_path = sys.argv[1], sys.argv[2]
bak = {}
for line in open(bak_path, encoding="utf-8"):
    s = line.strip()
    if not s or s.startswith("#") or "=" not in s:
        continue
    k, _, v = s.partition("=")
    if k.startswith("AIRALO_"):
        bak[k] = v
lines = open(env_path, encoding="utf-8").read().splitlines(True)
out = []
seen = set()
for line in lines:
    s = line.strip()
    if s and not s.startswith("#") and "=" in s:
        k = s.split("=", 1)[0]
        if k.startswith("AIRALO_") and k in bak:
            out.append(f"{k}={bak[k]}\n")
            seen.add(k)
            continue
    out.append(line)
for k, v in bak.items():
    if k not in seen:
        out.append(f"{k}={v}\n")
open(env_path, "w", encoding="utf-8").writelines(out)
print("restored", sorted(bak))
PY
  docker compose --profile app up -d --force-recreate api celery celery-beat
  echo "STAGING AIRALO RESTORED from ${BAK_FILE}"
  exit 0
fi

[[ "${MODE}" == "pause" ]] || fail "usage: $0 [pause|restore]"

# Backup current AIRALO_* once
if [[ ! -f "${BAK_FILE}" ]]; then
  grep -E '^AIRALO_' "${ENV_FILE}" > "${BAK_FILE}" || true
  chmod 600 "${BAK_FILE}"
  echo "Wrote backup ${BAK_FILE}"
else
  echo "Keeping existing backup ${BAK_FILE}"
fi

python3 - "${ENV_FILE}" <<'PY'
import sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines(True)
out = []
have = {
    "AIRALO_CLIENT_ID": False,
    "AIRALO_CLIENT_SECRET": False,
    "AIRALO_SANDBOX": False,
    "AIRALO_ENABLED": False,
}
for line in lines:
    s = line.strip()
    if s and not s.startswith("#") and "=" in s:
        k = s.split("=", 1)[0]
        if k == "AIRALO_CLIENT_ID":
            out.append("AIRALO_CLIENT_ID=\n"); have[k] = True; continue
        if k == "AIRALO_CLIENT_SECRET":
            out.append("AIRALO_CLIENT_SECRET=\n"); have[k] = True; continue
        if k == "AIRALO_SANDBOX":
            out.append("AIRALO_SANDBOX=true\n"); have[k] = True; continue
        if k == "AIRALO_ENABLED":
            out.append("AIRALO_ENABLED=false\n"); have[k] = True; continue
    out.append(line)
if not have["AIRALO_CLIENT_ID"]:
    out.append("AIRALO_CLIENT_ID=\n")
if not have["AIRALO_CLIENT_SECRET"]:
    out.append("AIRALO_CLIENT_SECRET=\n")
if not have["AIRALO_SANDBOX"]:
    out.append("AIRALO_SANDBOX=true\n")
if not have["AIRALO_ENABLED"]:
    out.append("AIRALO_ENABLED=false\n")
open(path, "w", encoding="utf-8").writelines(out)
print("paused AIRALO credentials on staging")
PY

docker compose --profile app up -d --force-recreate api celery celery-beat
docker compose --profile app exec -T api python -c '
from django.conf import settings
assert not (settings.AIRALO_CLIENT_ID or "").strip()
assert settings.AIRALO_SANDBOX is True
enabled = getattr(settings, "AIRALO_ENABLED", True)
assert enabled is False or not (settings.AIRALO_CLIENT_ID or "").strip()
print("staging Airalo paused OK")
'
echo "STAGING AIRALO PAUSED — restore with: $0 restore"
