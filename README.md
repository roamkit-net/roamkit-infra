# roamkit-infra

Infrastructure as Code for [RoamKit](https://github.com/roamkit-net). This is the **first repo** in the org — bootstrap, compose, CI templates, and deploy scripts live here before `roamkit-api` and `roamkit-web` exist.

## Layout

```
bootstrap/          # One-time org + server setup (gh CLI, Hetzner)
docker/             # Compose stacks (dev, staging, test)
ci/workflows/       # Reusable GitHub Actions templates
scripts/            # Deploy + rollback automation
```

Staging uses **shared host Traefik** (`proxy` network) and **shared PostGIS/Redis** — see `bootstrap/hetzner/prerequisites.md` and `plan.yaml`.

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

## CI templates

Copy workflows from `ci/workflows/` into each repo's `.github/workflows/` or into the org `.github` repo as reusable workflows.

## Branch strategy

| Branch      | Deploy                   |
|-------------|--------------------------|
| `main`      | CI only — no auto-deploy |
| `develop`   | Auto-deploy to staging   |
| `feature/*` | PR → develop             |

## Related repos

| Repo           | Purpose                          |
|----------------|----------------------------------|
| `roamkit-docs` | ADR, RFC, architecture standards |
| `roamkit-api`  | Django + DRF + Celery            |
| `roamkit-web`  | Next.js 15 App Router            |
| `.github`      | Org reusable workflows, templates|
