# roamkit-infra

Infrastructure as Code for [RoamKit](https://github.com/roamkit-net). This is the **first repo** in the org — bootstrap, compose, CI templates, and deploy scripts live here before `roamkit-api` and `roamkit-web` exist.

## Layout

```
bootstrap/          # One-time org + server setup (gh CLI, Hetzner)
docker/             # Compose stacks (dev, staging, production, test)
ci/workflows/       # Reusable GitHub Actions templates
scripts/            # Deploy + rollback automation (staging + production)
```

Staging and production both use **shared host Traefik** (`proxy`) and **shared PostGIS/Redis hosts** with **isolated DB name + Redis index** ([ADR 013](https://github.com/roamkit-net/roamkit-docs/blob/develop/docs/adr/013-production-launch.md)). See `bootstrap/hetzner/prerequisites.md`, `plan.yaml` (staging), `plan.production.yaml` (production).

## Quick start (local dev)

```bash
cd docker
cp .env.example .env   # edit secrets locally — never commit .env
docker compose -f docker-compose.dev.yml up -d
```

Verify PostGIS + Redis:

```bash
./bootstrap/docker/verify-local.sh
```

## Bootstrap (GitHub org)

Run from WSL with `GH_TOKEN` set (org admin scope):

```bash
cd bootstrap/github
./create-org.sh        # skip if org already exists
./create-repos.sh
./branch-protection.sh
./labels.sh
./milestones.sh
```

See `bootstrap/github/secrets.md` for required GitHub secrets.

## Staging deploy

Staging stack on Hetzner: `/opt/stacks/roamkit-net/`

- `staging.roamkit.net` → Next.js (via Traefik)
- `api.staging.roamkit.net` → Django API (via Traefik)

Server **pulls images only** (GHCR) — never builds on host.

Prerequisites: `bootstrap/hetzner/prerequisites.md`

```bash
# On server after init
cd /opt/stacks/roamkit-net && ./scripts/deploy-staging.sh
```

SSH from WSL: `ssh dedicated-hel1` (root@65.108.196.92)

### Billing smoke (Polygon USDT)

1. Set `BILLING_*` / `POLYGON_*` on `/opt/stacks/roamkit-net/.env` (template: `docker/.env.staging.example`).
2. Recreate api/celery so env is loaded.
3. Run:

```bash
# On host (or scp scripts/staging-dod-billing.sh first)
./scripts/staging-dod-billing.sh
```

Post-deploy health smoke (`scripts/smoke-test.sh`) also checks `/me/deposit` and unauthenticated billing 401s. Full money path (ledger/order) is the DoD script above.

## Production platform (Faza 4 PR1)

Production stack: `/opt/stacks/roamkit-production/`

- Isolation: DB `roamkit_production`, Redis index **5**, own `.secrets/`, no shared volumes with staging
- Compose: `docker/docker-compose.production.yml`
- Env template: `docker/.env.production.example`
- Runbook: `bootstrap/hetzner/PRODUCTION_PLAN.md`
- Spec: `bootstrap/hetzner/plan.production.yaml`

```bash
# On server (once)
bash bootstrap/hetzner/init-production-stack.sh
# create DB roamkit_production, edit .env, then:
cd /opt/stacks/roamkit-production && ./scripts/deploy-production.sh

# Rollback N → N-1
./scripts/rollback-production.sh && ./scripts/smoke-test-production.sh
```

**Out of scope for PR1:** DNS/apex cutover, `roamkit-api`/`roamkit-web` code, `/version` implementation, billing E2E prod DoD (PR2), Sentry (PR3).

Rule: if a change requires editing `roamkit-api` or `roamkit-web`, open a **separate** PR — do not fold it into infra PR1.

## CI templates

Copy workflows from `ci/workflows/` into each repo's `.github/workflows/` or into the org `.github` repo as reusable workflows.

## Branch strategy

| Branch      | Deploy                                       |
|-------------|----------------------------------------------|
| `main`      | Production (when deploy CI exists — ADR 013) |
| `develop`   | Auto-deploy to staging                       |
| `feature/*` | PR → develop                                 |

## Related repos

| Repo           | Purpose                          |
|----------------|----------------------------------|
| `roamkit-docs` | ADR, RFC, architecture standards |
| `roamkit-api`  | Django + DRF + Celery            |
| `roamkit-web`  | Next.js 15 App Router            |
| `.github`      | Org reusable workflows, templates|
