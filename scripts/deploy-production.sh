#!/usr/bin/env bash
# Production deploy: pull images, migrate, health check, smoke, rollback on failure.
# Stack: /opt/stacks/roamkit-production/ (ADR 013).
set -euo pipefail

STACK_DIR="${ROAMKIT_PRODUCTION_DIR:-/opt/stacks/roamkit-production}"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
PREVIOUS_TAG_FILE="${STACK_DIR}/.previous-tag"
COMPOSE_PROFILE=(--profile app)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/smoke-test-production.sh" ]]; then
  SMOKE_SCRIPT="${SCRIPT_DIR}/smoke-test-production.sh"
elif [[ -f "${SCRIPT_DIR}/../bootstrap/hetzner/smoke-test-production.sh" ]]; then
  SMOKE_SCRIPT="${SCRIPT_DIR}/../bootstrap/hetzner/smoke-test-production.sh"
else
  echo "ERROR: smoke-test-production.sh not found." >&2
  exit 1
fi

cd "${STACK_DIR}"

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "ERROR: ${COMPOSE_FILE} not found. Run init-production-stack.sh first." >&2
  exit 1
fi

if [[ ! -f "${STACK_DIR}/.env" ]]; then
  echo "ERROR: ${STACK_DIR}/.env missing. Copy from .env.example and fill secrets." >&2
  exit 1
fi

# Save currently running image refs for rollback (API + WEB).
save_previous_tags() {
  local api_id web_id api_ref web_ref
  api_id="$(docker compose "${COMPOSE_PROFILE[@]}" images -q api 2>/dev/null | head -n1 || true)"
  web_id="$(docker compose "${COMPOSE_PROFILE[@]}" images -q web 2>/dev/null | head -n1 || true)"
  api_ref=""
  web_ref=""
  if [[ -n "${api_id}" ]]; then
    api_ref="$(docker image inspect "${api_id}" --format '{{index .RepoTags 0}}' 2>/dev/null || true)"
  fi
  if [[ -n "${web_id}" ]]; then
    web_ref="$(docker image inspect "${web_id}" --format '{{index .RepoTags 0}}' 2>/dev/null || true)"
  fi
  if [[ -n "${api_ref}" && "${api_ref}" != "<none>" ]]; then
    {
      echo "API_IMAGE=${api_ref}"
      if [[ -n "${web_ref}" && "${web_ref}" != "<none>" ]]; then
        echo "WEB_IMAGE=${web_ref}"
      fi
    } > "${PREVIOUS_TAG_FILE}"
    echo "Saved rollback tags to ${PREVIOUS_TAG_FILE}"
  fi
}

save_previous_tags

rollback_on_failure() {
  echo "DEPLOY FAILED — invoking rollback..."
  if [[ -x "${SCRIPT_DIR}/rollback-production.sh" ]]; then
    "${SCRIPT_DIR}/rollback-production.sh" || true
  elif [[ -x "${STACK_DIR}/scripts/rollback-production.sh" ]]; then
    "${STACK_DIR}/scripts/rollback-production.sh" || true
  else
    echo "ERROR: rollback-production.sh not found." >&2
  fi
  exit 1
}

trap 'rollback_on_failure' ERR

echo "Pulling images..."
docker compose "${COMPOSE_PROFILE[@]}" pull

echo "Starting services (api start_period up to 90s; web waits for api healthy)..."
docker compose "${COMPOSE_PROFILE[@]}" up -d

echo "Running migrations..."
docker compose "${COMPOSE_PROFILE[@]}" exec -T api python manage.py migrate --noinput

echo "Waiting for API health (live + ready; DB may lag up to ~90s)..."
ready=0
for _ in $(seq 1 45); do
  if docker compose "${COMPOSE_PROFILE[@]}" exec -T api curl -sf http://localhost:8000/health/ready >/dev/null; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "${ready}" -ne 1 ]]; then
  echo "ERROR: API /health/ready did not become ready in time." >&2
  exit 1
fi

docker compose "${COMPOSE_PROFILE[@]}" exec -T api curl -sf http://localhost:8000/health/live >/dev/null
docker compose "${COMPOSE_PROFILE[@]}" exec -T api curl -sf http://localhost:8000/health/ready >/dev/null

echo "Waiting for web..."
web_ok=0
for _ in $(seq 1 45); do
  if docker compose "${COMPOSE_PROFILE[@]}" exec -T web curl -sf http://localhost:3000/ >/dev/null; then
    web_ok=1
    break
  fi
  sleep 2
done
if [[ "${web_ok}" -ne 1 ]]; then
  echo "ERROR: web origin did not return 200 in time." >&2
  exit 1
fi

echo "Smoke test..."
"${SMOKE_SCRIPT}"

trap - ERR
echo "Deploy successful."
echo "Rollback procedure if later smoke fails: ./scripts/rollback-production.sh && ./scripts/smoke-test-production.sh"
