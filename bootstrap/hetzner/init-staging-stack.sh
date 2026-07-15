#!/usr/bin/env bash
# Initialize Hetzner staging stack directory (run once on server as root).
set -euo pipefail

STACK_DIR="${ROAMKIT_STAGING_DIR:-/opt/stacks/roamkit-net}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "Creating staging stack at ${STACK_DIR}..."

if ! docker network inspect proxy &>/dev/null; then
  echo "ERROR: Docker network 'proxy' not found. Shared Traefik must be running." >&2
  echo "See bootstrap/hetzner/prerequisites.md" >&2
  exit 1
fi

if ! docker ps --filter name=traefik --format '{{.Names}}' | grep -q traefik; then
  echo "WARN: Traefik container not detected — ensure /opt/stacks/traefik/ is up." >&2
fi

mkdir -p "${STACK_DIR}/scripts"

if ! docker network inspect postgis &>/dev/null; then
  echo "WARN: Docker network 'postgis' not found — shared PostGIS required." >&2
fi

if ! docker network inspect hetzner_net &>/dev/null; then
  echo "WARN: Docker network 'hetzner_net' not found — shared Redis required." >&2
fi

copy_from_local() {
  cp "${INFRA_ROOT}/docker/docker-compose.staging.yml" "${STACK_DIR}/docker-compose.yml"
  cp "${INFRA_ROOT}/docker/.env.staging.example" "${STACK_DIR}/.env.example"
  cp "${INFRA_ROOT}/scripts/deploy-staging.sh" "${STACK_DIR}/scripts/deploy-staging.sh"
  cp "${INFRA_ROOT}/bootstrap/hetzner/smoke-test.sh" "${STACK_DIR}/scripts/smoke-test.sh"
  cp "${INFRA_ROOT}/bootstrap/hetzner/plan.yaml" "${STACK_DIR}/plan.yaml"
  cp "${INFRA_ROOT}/bootstrap/hetzner/SERVER_PLAN.md" "${STACK_DIR}/PLAN.md"
  chmod +x "${STACK_DIR}/scripts/"*.sh
  echo "Copied stack files from ${INFRA_ROOT}"
}

if [[ -f "${INFRA_ROOT}/docker/docker-compose.staging.yml" ]]; then
  copy_from_local
else
  INFRA_REPO="${ROAMKIT_INFRA_REPO:-https://github.com/roamkit-net/roamkit-infra.git}"
  TMP_DIR=$(mktemp -d)
  git clone "${INFRA_REPO}" "${TMP_DIR}"
  cp "${TMP_DIR}/docker/docker-compose.staging.yml" "${STACK_DIR}/docker-compose.yml"
  cp "${TMP_DIR}/docker/.env.staging.example" "${STACK_DIR}/.env.example"
  cp "${TMP_DIR}/scripts/deploy-staging.sh" "${STACK_DIR}/scripts/deploy-staging.sh"
  cp "${TMP_DIR}/bootstrap/hetzner/smoke-test.sh" "${STACK_DIR}/scripts/smoke-test.sh"
  cp "${TMP_DIR}/bootstrap/hetzner/plan.yaml" "${STACK_DIR}/plan.yaml"
  cp "${TMP_DIR}/bootstrap/hetzner/SERVER_PLAN.md" "${STACK_DIR}/PLAN.md"
  chmod +x "${STACK_DIR}/scripts/"*.sh
  rm -rf "${TMP_DIR}"
  echo "Copied stack files from ${INFRA_REPO}"
fi

if [[ ! -f "${STACK_DIR}/.env" ]]; then
  cp "${STACK_DIR}/.env.example" "${STACK_DIR}/.env"
  echo "Created ${STACK_DIR}/.env from .env.example — edit before deploy."
fi

echo "Staging stack directory ready: ${STACK_DIR}"
echo "See PLAN.md and plan.yaml for next steps."
