#!/usr/bin/env bash
# Explicit production rollback to the immutable N-1 refs saved in .previous-tag.
# Writes those refs back into .env (Compose interpolation file) before pull/up.
# A later plain `docker compose up -d` reads that same .env. Does not restore
# the database and does not run migrate.
# Flow: Deploy N → Smoke FAIL → ./rollback-production.sh → Verify smoke.
set -euo pipefail

STACK_DIR="${ROAMKIT_PRODUCTION_DIR:-/opt/stacks/roamkit-production}"
PREVIOUS_TAG_FILE="${STACK_DIR}/.previous-tag"
RUNTIME_ENV="${STACK_DIR}/runtime.env"
IMAGE_ENV="${STACK_DIR}/.env"
COMPOSE_PROFILE=(--profile app)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/smoke-test-production.sh" ]]; then
  SMOKE_SCRIPT="${SCRIPT_DIR}/smoke-test-production.sh"
elif [[ -f "${SCRIPT_DIR}/../bootstrap/hetzner/smoke-test-production.sh" ]]; then
  SMOKE_SCRIPT="${SCRIPT_DIR}/../bootstrap/hetzner/smoke-test-production.sh"
else
  SMOKE_SCRIPT=""
fi

cd "${STACK_DIR}"

if [[ ! -f "${PREVIOUS_TAG_FILE}" ]]; then
  echo "ERROR: ${PREVIOUS_TAG_FILE} not found — cannot rollback automatically." >&2
  echo "Manual: set API_IMAGE/WEB_IMAGE in .env to last known good SHA or digest, then:" >&2
  echo "  docker compose --profile app pull && docker compose --profile app up -d" >&2
  exit 1
fi

if [[ ! -f "${IMAGE_ENV}" ]]; then
  echo "ERROR: ${IMAGE_ENV} missing." >&2
  exit 1
fi

if [[ ! -f "${RUNTIME_ENV}" ]]; then
  echo "ERROR: ${RUNTIME_ENV} missing. Refusing to roll image pins into the secrets file." >&2
  exit 1
fi

# Same interpolation path as deploy: project .env, no --env-file.
compose() {
  docker compose "${COMPOSE_PROFILE[@]}" "$@"
}

# shellcheck disable=SC1090
source "${PREVIOUS_TAG_FILE}"

assert_immutable_pin() {
  local name="$1"
  local ref="$2"
  local hex
  if [[ "${ref}" == *"@sha256:"* ]]; then
    hex="${ref##*@sha256:}"
    if [[ "${hex}" =~ ^[0-9a-f]{64}$ ]]; then
      return 0
    fi
  elif [[ "${ref}" =~ :[0-9a-f]{40}$ ]]; then
    return 0
  fi
  echo "ERROR: ${name} must be an immutable SHA tag or sha256 digest, got: ${ref}" >&2
  exit 1
}

set_env_pin() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "${IMAGE_ENV}" ]]; then
    grep -v -E "^${key}=" "${IMAGE_ENV}" > "${tmp}" || true
  fi
  printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
  mv "${tmp}" "${IMAGE_ENV}"
}

if [[ -z "${API_IMAGE:-}" || -z "${WEB_IMAGE:-}" ]]; then
  echo "ERROR: API_IMAGE and WEB_IMAGE are both required in ${PREVIOUS_TAG_FILE}" >&2
  exit 1
fi

assert_immutable_pin API_IMAGE "${API_IMAGE}"
assert_immutable_pin WEB_IMAGE "${WEB_IMAGE}"

echo "Rolling back .env image pins to:"
echo "  API_IMAGE=${API_IMAGE}"
echo "  WEB_IMAGE=${WEB_IMAGE}"

set_env_pin API_IMAGE "${API_IMAGE}"
set_env_pin WEB_IMAGE "${WEB_IMAGE}"
# Drop any non-pin lines so .env cannot become a container env file again.
tmp_pins="$(mktemp)"
grep -E '^(API_IMAGE|WEB_IMAGE)=' "${IMAGE_ENV}" > "${tmp_pins}"
mv "${tmp_pins}" "${IMAGE_ENV}"
chmod 600 "${IMAGE_ENV}"
sed -i \
  -e '/^API_IMAGE=/d' \
  -e '/^WEB_IMAGE=/d' \
  -e '/^ROAMKIT_GIT_SHA=/d' \
  -e '/^ROAMKIT_IMAGE_TAG=/d' \
  -e '/^ROAMKIT_BUILD_DATE=/d' \
  "${RUNTIME_ENV}"

# Do not export pins over .env. A later plain `docker compose up -d` reads .env.
unset API_IMAGE WEB_IMAGE

compose pull
compose up -d

echo "Waiting for API ready..."
ready=0
for _ in $(seq 1 45); do
  if compose exec -T api curl -sf http://localhost:8000/health/ready >/dev/null; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "${ready}" -ne 1 ]]; then
  echo "ERROR: API /health/ready did not recover after rollback." >&2
  exit 1
fi

compose exec -T api curl -sf http://localhost:8000/health/live >/dev/null
compose exec -T api curl -sf http://localhost:8000/health/ready >/dev/null

echo "Waiting for web..."
web_ok=0
for _ in $(seq 1 45); do
  if compose exec -T web curl -sf http://localhost:3000/ >/dev/null; then
    web_ok=1
    break
  fi
  sleep 2
done
if [[ "${web_ok}" -ne 1 ]]; then
  echo "ERROR: web origin did not return 200 after rollback." >&2
  exit 1
fi

if [[ -n "${SMOKE_SCRIPT}" ]]; then
  echo "Smoke test..."
  "${SMOKE_SCRIPT}"
else
  echo "ERROR: smoke-test-production.sh not found." >&2
  exit 1
fi

echo "Rollback complete. .env holds the immutable pins above. Database was not restored."
