#!/usr/bin/env bash
# Explicit production rollback to N-1 images saved in .previous-tag.
# Flow: Deploy N → Smoke FAIL → ./rollback-production.sh → Verify smoke.
set -euo pipefail

STACK_DIR="${ROAMKIT_PRODUCTION_DIR:-/opt/stacks/roamkit-production}"
PREVIOUS_TAG_FILE="${STACK_DIR}/.previous-tag"
COMPOSE_PROFILE=(--profile app)

cd "${STACK_DIR}"

if [[ ! -f "${PREVIOUS_TAG_FILE}" ]]; then
  echo "ERROR: ${PREVIOUS_TAG_FILE} not found — cannot rollback automatically." >&2
  echo "Manual: set API_IMAGE/WEB_IMAGE in .env to last known good SHA tags, then:" >&2
  echo "  docker compose --profile app pull && docker compose --profile app up -d" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${PREVIOUS_TAG_FILE}"

if [[ -z "${API_IMAGE:-}" ]]; then
  echo "ERROR: API_IMAGE missing in ${PREVIOUS_TAG_FILE}" >&2
  exit 1
fi

echo "Rolling back to:"
echo "  API_IMAGE=${API_IMAGE}"
echo "  WEB_IMAGE=${WEB_IMAGE:-<unchanged from .env>}"

export API_IMAGE
if [[ -n "${WEB_IMAGE:-}" ]]; then
  export WEB_IMAGE
fi

docker compose "${COMPOSE_PROFILE[@]}" pull
docker compose "${COMPOSE_PROFILE[@]}" up -d

echo "Waiting for API ready..."
for _ in $(seq 1 45); do
  if docker compose "${COMPOSE_PROFILE[@]}" exec -T api curl -sf http://localhost:8000/health/ready >/dev/null; then
    break
  fi
  sleep 2
done

docker compose "${COMPOSE_PROFILE[@]}" exec -T api curl -sf http://localhost:8000/health/live >/dev/null
docker compose "${COMPOSE_PROFILE[@]}" exec -T api curl -sf http://localhost:8000/health/ready >/dev/null
docker compose "${COMPOSE_PROFILE[@]}" exec -T web curl -sf http://localhost:3000/ >/dev/null

echo "Rollback complete. Run: ./scripts/smoke-test-production.sh"
