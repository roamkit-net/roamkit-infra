#!/usr/bin/env bash
# Verify PostGIS + Redis are reachable after docker compose up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/../../docker"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.dev.yml"

cd "${COMPOSE_DIR}"

if ! docker compose -f docker-compose.dev.yml ps --status running | grep -q postgis; then
  echo "Starting dev stack..."
  docker compose -f docker-compose.dev.yml up -d --wait
fi

echo "Checking PostGIS..."
docker compose -f docker-compose.dev.yml exec -T postgis   pg_isready -U "${POSTGRES_USER:-roamkit}" -d "${POSTGRES_DB:-roamkit}"

echo "Checking Redis..."
docker compose -f docker-compose.dev.yml exec -T redis redis-cli ping | grep -q PONG

echo "Checking Mailpit..."
curl -sf http://localhost:8025/api/v1/info >/dev/null

echo "All local infrastructure services OK."
