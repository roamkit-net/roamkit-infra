#!/usr/bin/env bash
# Initialize Hetzner production stack directory (run once on server as root).
# ADR 013 — /opt/stacks/roamkit-production/ (separate from staging).
set -euo pipefail

STACK_DIR="${ROAMKIT_PRODUCTION_DIR:-/opt/stacks/roamkit-production}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "Creating production stack at ${STACK_DIR}..."

if ! docker network inspect proxy &>/dev/null; then
  echo "ERROR: Docker network 'proxy' not found. Shared Traefik must be running." >&2
  echo "See bootstrap/hetzner/prerequisites.md" >&2
  exit 1
fi

if ! docker ps --filter name=traefik --format '{{.Names}}' | grep -q traefik; then
  echo "WARN: Traefik container not detected — ensure /opt/stacks/traefik/ is up." >&2
fi

if ! docker network inspect postgis &>/dev/null; then
  echo "WARN: Docker network 'postgis' not found — shared PostGIS required." >&2
fi

if ! docker network inspect hetzner_net &>/dev/null; then
  echo "WARN: Docker network 'hetzner_net' not found — shared Redis required." >&2
fi

mkdir -p "${STACK_DIR}/scripts" "${STACK_DIR}/.secrets"
chmod 700 "${STACK_DIR}/.secrets"

copy_from_local() {
  cp "${INFRA_ROOT}/docker/docker-compose.production.yml" "${STACK_DIR}/docker-compose.yml"
  cp "${INFRA_ROOT}/docker/.env.production.example" "${STACK_DIR}/.env.example"
  cp "${INFRA_ROOT}/scripts/deploy-production.sh" "${STACK_DIR}/scripts/deploy-production.sh"
  cp "${INFRA_ROOT}/scripts/rollback-production.sh" "${STACK_DIR}/scripts/rollback-production.sh"
  cp "${INFRA_ROOT}/scripts/smoke-test-production.sh" "${STACK_DIR}/scripts/smoke-test-production.sh"
  cp "${INFRA_ROOT}/bootstrap/hetzner/PRODUCTION_PLAN.md" "${STACK_DIR}/PLAN.md"
  cp "${INFRA_ROOT}/bootstrap/hetzner/plan.production.yaml" "${STACK_DIR}/plan.yaml"
  chmod +x "${STACK_DIR}/scripts/"*.sh
  echo "Copied stack files from ${INFRA_ROOT}"
}

if [[ -f "${INFRA_ROOT}/docker/docker-compose.production.yml" ]]; then
  copy_from_local
else
  INFRA_REPO="${ROAMKIT_INFRA_REPO:-https://github.com/roamkit-net/roamkit-infra.git}"
  TMP_DIR=$(mktemp -d)
  git clone --depth 1 "${INFRA_REPO}" "${TMP_DIR}"
  cp "${TMP_DIR}/docker/docker-compose.production.yml" "${STACK_DIR}/docker-compose.yml"
  cp "${TMP_DIR}/docker/.env.production.example" "${STACK_DIR}/.env.example"
  cp "${TMP_DIR}/scripts/deploy-production.sh" "${STACK_DIR}/scripts/deploy-production.sh"
  cp "${TMP_DIR}/scripts/rollback-production.sh" "${STACK_DIR}/scripts/rollback-production.sh"
  cp "${TMP_DIR}/scripts/smoke-test-production.sh" "${STACK_DIR}/scripts/smoke-test-production.sh"
  cp "${TMP_DIR}/bootstrap/hetzner/PRODUCTION_PLAN.md" "${STACK_DIR}/PLAN.md"
  cp "${TMP_DIR}/bootstrap/hetzner/plan.production.yaml" "${STACK_DIR}/plan.yaml"
  chmod +x "${STACK_DIR}/scripts/"*.sh
  rm -rf "${TMP_DIR}"
  echo "Copied stack files from ${INFRA_REPO}"
fi

if [[ ! -f "${STACK_DIR}/.env" ]]; then
  cp "${STACK_DIR}/.env.example" "${STACK_DIR}/.env"
  chmod 600 "${STACK_DIR}/.env"
  echo "Created ${STACK_DIR}/.env from .env.example — edit secrets before deploy."
fi

cat <<EOF

Next (documented, no undocumented manual steps):
  1. Create DB on shared PostGIS:  CREATE DATABASE roamkit_production OWNER roamkit;
  2. Edit ${STACK_DIR}/.env  (replace all change-me; set POLYGON_PLATFORM_WALLET)
  3. Place wallet private key at ${STACK_DIR}/.secrets/ (chmod 600) if needed offline
  4. Login GHCR on host if required:  docker login ghcr.io
  5. First deploy:  cd ${STACK_DIR} && ./scripts/deploy-production.sh

See PLAN.md for health policy, secrets lifecycle, startup order, rollback.
EOF

echo "Production stack directory ready: ${STACK_DIR}"
