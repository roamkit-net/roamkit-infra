#!/usr/bin/env bash
# Production deploy: pull images, backup, migrate, health check, smoke, rollback on failure.
# Stack: /opt/stacks/roamkit-production/ (ADR 013).
#
# `.env` holds only immutable API_IMAGE and WEB_IMAGE. Compose loads that file
# automatically for interpolation. Do not pass --env-file: Compose v5 replaces
# the project `.env` instead of merging it. `runtime.env` is the container
# env_file and must not contain image pins or baked release identity.
# Rollback restores pins into `.env`. This script does not reverse migrations.
set -euo pipefail

STACK_DIR="${ROAMKIT_PRODUCTION_DIR:-/opt/stacks/roamkit-production}"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
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
  echo "ERROR: smoke-test-production.sh not found." >&2
  exit 1
fi

cd "${STACK_DIR}"

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "ERROR: ${COMPOSE_FILE} not found. Run init-production-stack.sh first." >&2
  exit 1
fi

if [[ ! -f "${IMAGE_ENV}" ]]; then
  echo "ERROR: ${IMAGE_ENV} missing. Copy from .env.example and fill secrets." >&2
  exit 1
fi

if ! grep -q 'runtime.env' "${COMPOSE_FILE}"; then
  echo "ERROR: ${COMPOSE_FILE} must set env_file to runtime.env before deploy." >&2
  echo "Refusing to split .env until the compose file no longer injects it." >&2
  exit 1
fi

# The one-time split of a combined .env is an operator bootstrap, not this
# deploy. Changing env_file from .env to runtime.env recreates every service
# even when the file bytes match, so that recreate must not run in the same
# step as migrate.
ensure_env_split() {
  local tmp
  if [[ ! -f "${RUNTIME_ENV}" ]]; then
    echo "ERROR: ${RUNTIME_ENV} is missing." >&2
    echo "Run the production env-split bootstrap before the first hardened deploy." >&2
    echo "This script will not create runtime.env or recreate services to do it." >&2
    exit 1
  fi
  sed -i \
    -e '/^API_IMAGE=/d' \
    -e '/^WEB_IMAGE=/d' \
    -e '/^ROAMKIT_GIT_SHA=/d' \
    -e '/^ROAMKIT_IMAGE_TAG=/d' \
    -e '/^ROAMKIT_BUILD_DATE=/d' \
    "${RUNTIME_ENV}"
  tmp="$(mktemp)"
  grep -E '^(API_IMAGE|WEB_IMAGE)=' "${IMAGE_ENV}" > "${tmp}" || true
  mv "${tmp}" "${IMAGE_ENV}"
  chmod 600 "${IMAGE_ENV}" "${RUNTIME_ENV}"
}

read_kv() {
  local file="$1"
  local key="$2"
  local line val
  line="$(grep -E "^${key}=" "${file}" | head -n1 || true)"
  if [[ -z "${line}" ]]; then
    echo "ERROR: ${key} missing from ${file}" >&2
    exit 1
  fi
  val="${line#*=}"
  val="${val%\"}"
  val="${val#\"}"
  val="${val%\'}"
  val="${val#\'}"
  printf '%s\n' "${val}"
}

# Project .env supplies API_IMAGE and WEB_IMAGE. No --env-file.
compose() {
  docker compose "${COMPOSE_PROFILE[@]}" "$@"
}

ensure_env_split

# Prefer a registry digest. Fall back to a 40-hex SHA tag. Never :main/:develop/:latest.
immutable_image_ref() {
  local id="$1"
  local ref hex picked=""
  while IFS= read -r ref; do
    [[ -z "${ref}" ]] && continue
    if [[ "${ref}" == *"@sha256:"* ]]; then
      hex="${ref##*@sha256:}"
      if [[ "${hex}" =~ ^[0-9a-f]{64}$ ]]; then
        if [[ "${ref}" == ghcr.io/* ]]; then
          printf '%s\n' "${ref}"
          return 0
        fi
        picked="${ref}"
      fi
    fi
  done < <(docker image inspect "${id}" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null || true)
  if [[ -n "${picked}" ]]; then
    printf '%s\n' "${picked}"
    return 0
  fi
  while IFS= read -r ref; do
    [[ -z "${ref}" || "${ref}" == "<none>" ]] && continue
    if [[ "${ref}" =~ :[0-9a-f]{40}$ ]]; then
      printf '%s\n' "${ref}"
      return 0
    fi
  done < <(docker image inspect "${id}" --format '{{range .RepoTags}}{{println .}}{{end}}' 2>/dev/null || true)
  return 1
}

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

read_env_pin() {
  read_kv "${IMAGE_ENV}" "$1"
}

# Save currently running image refs for rollback (API + WEB).
save_previous_tags() {
  local api_id web_id api_ref web_ref tmp
  api_id="$(compose images -q api 2>/dev/null | head -n1 || true)"
  web_id="$(compose images -q web 2>/dev/null | head -n1 || true)"
  if [[ -z "${api_id}" || -z "${web_id}" ]]; then
    echo "ERROR: cannot resolve running api/web image ids for rollback." >&2
    exit 1
  fi
  if ! api_ref="$(immutable_image_ref "${api_id}")"; then
    echo "ERROR: running API image has no immutable digest or 40-hex SHA tag." >&2
    exit 1
  fi
  if ! web_ref="$(immutable_image_ref "${web_id}")"; then
    echo "ERROR: running web image has no immutable digest or 40-hex SHA tag." >&2
    exit 1
  fi
  assert_immutable_pin API_IMAGE "${api_ref}"
  assert_immutable_pin WEB_IMAGE "${web_ref}"
  tmp="$(mktemp)"
  {
    echo "API_IMAGE=${api_ref}"
    echo "WEB_IMAGE=${web_ref}"
  } > "${tmp}"
  mv "${tmp}" "${PREVIOUS_TAG_FILE}"
  echo "Saved rollback refs to ${PREVIOUS_TAG_FILE}"
  echo "  API_IMAGE=${api_ref}"
  echo "  WEB_IMAGE=${web_ref}"
}

save_previous_tags

api_pin="$(read_env_pin API_IMAGE)"
web_pin="$(read_env_pin WEB_IMAGE)"
assert_immutable_pin API_IMAGE "${api_pin}"
assert_immutable_pin WEB_IMAGE "${web_pin}"

assert_runtime_has_no_pins() {
  compose config --format json | python3 -c '
import json, sys
doc = json.load(sys.stdin)
banned = ("API_IMAGE", "WEB_IMAGE", "ROAMKIT_GIT_SHA", "ROAMKIT_IMAGE_TAG", "ROAMKIT_BUILD_DATE")
for name, svc in doc.get("services", {}).items():
    env = svc.get("environment") or {}
    for key in banned:
        if key in env:
            print(f"ERROR: {name} runtime environment contains {key}", file=sys.stderr)
            sys.exit(1)
'
}

assert_runtime_has_no_pins

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

# Parent exports must not override the pins just validated in .env.
unset API_IMAGE WEB_IMAGE

echo "Pulling images..."
compose pull

echo "Starting services (api start_period up to 90s; web waits for api healthy)..."
compose up -d

echo "Backing up production database before migrate..."
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
pg_user="$(read_kv "${RUNTIME_ENV}" POSTGRES_USER)"
pg_db="$(read_kv "${RUNTIME_ENV}" POSTGRES_DB)"
pg_container="${ROAMKIT_POSTGRES_CONTAINER:-$(read_kv "${RUNTIME_ENV}" POSTGRES_HOST)}"
if [[ "${pg_container}" == *.* || "${pg_container}" == *:* || "${pg_container}" == */* ]]; then
  echo "ERROR: POSTGRES_HOST=${pg_container} is not a local container name." >&2
  echo "Set ROAMKIT_POSTGRES_CONTAINER to the shared PostGIS container." >&2
  exit 1
fi
if ! docker inspect "${pg_container}" >/dev/null 2>&1; then
  echo "ERROR: Postgres container ${pg_container} was not found. Not migrating." >&2
  exit 1
fi
if ! docker exec "${pg_container}" sh -c 'command -v pg_dump >/dev/null && command -v pg_restore >/dev/null'; then
  echo "ERROR: pg_dump or pg_restore is missing in ${pg_container}. Not migrating." >&2
  exit 1
fi
backup_dir="${STACK_DIR}/backups"
backup_file="${backup_dir}/${pg_db}-${stamp}.dump"
remote_dump="/tmp/${pg_db}-${stamp}.dump"
mkdir -p "${backup_dir}"
chmod 700 "${backup_dir}"
# docker exec uses the container's local socket. This image's pg_hba trusts
# local sockets, so no password is passed. A non-zero dump exits before migrate.
if ! docker exec "${pg_container}" pg_dump -U "${pg_user}" -d "${pg_db}" -Fc -f "${remote_dump}"; then
  echo "ERROR: pg_dump failed; not migrating." >&2
  exit 1
fi
if ! docker exec "${pg_container}" pg_restore --list "${remote_dump}" >/dev/null; then
  docker exec "${pg_container}" rm -f "${remote_dump}" || true
  echo "ERROR: pg_restore --list failed; not migrating." >&2
  exit 1
fi
docker cp "${pg_container}:${remote_dump}" "${backup_file}"
docker exec "${pg_container}" rm -f "${remote_dump}"
if [[ ! -s "${backup_file}" ]]; then
  echo "ERROR: backup missing or empty: ${backup_file}" >&2
  exit 1
fi
chmod 600 "${backup_file}"
echo "Backup OK: ${backup_file} ($(wc -c < "${backup_file}") bytes)"

echo "Running migrations..."
compose exec -T api python manage.py migrate --noinput

echo "Waiting for API health (live + ready; DB may lag up to ~90s)..."
ready=0
for _ in $(seq 1 45); do
  if compose exec -T api curl -sf http://localhost:8000/health/ready >/dev/null; then
    ready=1
    break
  fi
  sleep 2
done
if [[ "${ready}" -ne 1 ]]; then
  echo "ERROR: API /health/ready did not become ready in time." >&2
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
  echo "ERROR: web origin did not return 200 in time." >&2
  exit 1
fi

echo "Smoke test..."
"${SMOKE_SCRIPT}"

trap - ERR
echo "Deploy successful."
echo "Rollback procedure if later smoke fails: ./scripts/rollback-production.sh && ./scripts/smoke-test-production.sh"
