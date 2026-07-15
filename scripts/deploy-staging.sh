#!/usr/bin/env bash
# Staging deploy: pull images, migrate, health check, smoke test, rollback on failure.
set -euo pipefail

STACK_DIR="${ROAMKIT_STAGING_DIR:-/opt/stacks/roamkit-net}"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
PREVIOUS_TAG_FILE="${STACK_DIR}/.previous-tag"
COMPOSE_PROFILE=(--profile app)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/smoke-test.sh" ]]; then
  SMOKE_SCRIPT="${SCRIPT_DIR}/smoke-test.sh"
elif [[ -f "${SCRIPT_DIR}/../bootstrap/hetzner/smoke-test.sh" ]]; then
  SMOKE_SCRIPT="${SCRIPT_DIR}/../bootstrap/hetzner/smoke-test.sh"
else
  echo "ERROR: smoke-test.sh not found." >&2
  exit 1
fi

cd "${STACK_DIR}"

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "ERROR: ${COMPOSE_FILE} not found. Run init-staging-stack.sh first." >&2
  exit 1
fi

# Save current image tags for rollback (from .env or environment)
if [[ -n "${API_IMAGE:-}" ]]; then
  echo "${API_IMAGE}" > "${PREVIOUS_TAG_FILE}"
  echo "Saved rollback tag: ${API_IMAGE}"
fi

rollback() {
  echo "ROLLBACK: restoring previous image..."
  if [[ -f "${PREVIOUS_TAG_FILE}" ]]; then
    PREV=$(cat "${PREVIOUS_TAG_FILE}")
    export API_IMAGE="${PREV}"
    export WEB_IMAGE="${PREV/roamkit-api/roamkit-web}"
    docker compose "${COMPOSE_PROFILE[@]}" pull
    docker compose "${COMPOSE_PROFILE[@]}" up -d
    echo "Rollback complete."
  else
    echo "No previous tag file — manual intervention required." >&2
  fi
  exit 1
}

trap 'rollback' ERR

echo "Pulling images..."
docker compose "${COMPOSE_PROFILE[@]}" pull

echo "Starting services..."
docker compose "${COMPOSE_PROFILE[@]}" up -d

echo "Running migrations..."
docker compose "${COMPOSE_PROFILE[@]}" exec -T api python manage.py migrate --noinput

echo "Health checks..."
for _ in $(seq 1 30); do
  if docker compose "${COMPOSE_PROFILE[@]}" exec -T api curl -sf http://localhost:8000/health/ready; then
    break
  fi
  sleep 2
done

docker compose "${COMPOSE_PROFILE[@]}" exec -T api curl -sf http://localhost:8000/health/live
docker compose "${COMPOSE_PROFILE[@]}" exec -T api curl -sf http://localhost:8000/health/ready

echo "Smoke test..."
"${SMOKE_SCRIPT}"

trap - ERR
echo "Deploy successful."
