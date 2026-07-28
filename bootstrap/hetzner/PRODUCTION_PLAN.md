# RoamKit production platform — runbook (PR1)

**Host:** same Hetzner HEL1 as staging (`65.108.196.92`)  
**Stack:** `/opt/stacks/roamkit-production/`  
**Architecture:** [ADR 013](https://github.com/roamkit-net/roamkit-docs/blob/develop/docs/adr/013-production-launch.md)  
**Gate:** PR0.5 GO WITH CONDITIONS — this PR builds the platform; cutover is PR2.

---

## Reproducible bootstrap (clean host / clean stack dir)

No undocumented manual steps. From a machine with Docker + git + `gh`/SSH to the server:

```bash
# On server as root
cd /opt
git clone https://github.com/roamkit-net/roamkit-infra.git /tmp/roamkit-infra
bash /tmp/roamkit-infra/bootstrap/hetzner/init-production-stack.sh
# → creates /opt/stacks/roamkit-production with compose, .env.example, scripts, PLAN.md

# Create isolated database on shared PostGIS (once)
docker exec -i "$(docker ps -qf name=postgis)" \
  psql -U roamkit -d postgres -c "CREATE DATABASE roamkit_production OWNER roamkit;"

cd /opt/stacks/roamkit-production
cp .env.example .env   # if init did not already
chmod 600 .env
nano .env              # replace every change-me; set POLYGON_PLATFORM_WALLET, Airalo live keys

# Optional offline secrets (wallet key material)
chmod 700 .secrets
# install key file(s) with chmod 600 — never commit

docker login ghcr.io   # token with package read
export API_IMAGE=ghcr.io/roamkit-net/roamkit-api:<sha-or-main>
export WEB_IMAGE=ghcr.io/roamkit-net/roamkit-web:<sha-or-main>
./scripts/deploy-production.sh
```

Upgrade path (existing stack):

```bash
cd /opt/stacks/roamkit-production
# refresh scripts/compose from infra repo if needed, then:
./scripts/deploy-production.sh
```

---

## Healthcheck policy (“healthy” means)

| Component | Check | Healthy means |
|-----------|--------|----------------|
| PostgreSQL (shared) | App `/health/ready` | Django can open DB connections to `POSTGRES_DB=roamkit_production` |
| Redis (shared index 5) | App `/health/ready` | Celery/broker ping succeeds |
| API liveness | Compose healthcheck + `/health/live` | Process up; no dependency on DB |
| API readiness | Deploy wait loop `/health/ready` | DB + Redis OK |
| Web | Compose healthcheck `curl /` | HTTP 200 from Next origin |
| Traefik | Host `docker ps` + public HTTPS | Router present; LE cert via `certresolver=cloudflare` |

Deploy fails (and rolls back) if API ready or web 200 is not reached within the wait window (~90s).

---

## Startup order

```text
docker compose up -d
  ├─ api          start_period=90s, health = /health/live
  ├─ web          depends_on: api (service_healthy)
  ├─ celery       depends_on: api (service_healthy)
  └─ celery-beat  depends_on: api (service_healthy)

deploy-production.sh then:
  migrate → wait /health/ready → wait web / → smoke
```

If PostGIS is down or `roamkit_production` missing:

- API stays unhealthy / ready fails for up to the wait window (~90s).
- Deploy script **ERR → rollback** to `.previous-tag`.
- Fix DB, re-run deploy. Do not improvise `docker start` order outside compose.

---

## Secrets lifecycle

| Secret | Where created | Who generates | Rotation | Backup |
|--------|---------------|---------------|----------|--------|
| `DJANGO_SECRET_KEY` | Server `.env` | Operator (`openssl rand -hex 32`) | Rotate → recreate api/celery/web | Encrypted offline copy (operator vault) |
| `POSTGRES_PASSWORD` | Shared PostGIS + `.env` | Operator at DB create | Rotate DB role + update both stacks carefully | DB backup + vault |
| Airalo live client id/secret | Server `.env` | Airalo dashboard | Rotate in partner portal → update `.env` → recreate | Vault only |
| `POLYGON_PLATFORM_WALLET` (address) | Server `.env` (public) | Operator wallet tooling | New deposit address = new wallet + ADR ops note | Address is public |
| Wallet private key | `/opt/stacks/roamkit-production/.secrets/` chmod 600 | Operator | New key = new address; never git | Encrypted offline; **not** in git |
| `EMAIL_HOST_PASSWORD` | Server `.env` | Mail host | Rotate mailbox → update `.env` | Vault |
| `PRODUCTION_SSH_KEY` / `GHCR_TOKEN` | GitHub org secrets | Operator via `gh secret set` | Rotate GitHub + server authorized_keys / GHCR PAT | GitHub encrypted secrets |

**Never** commit `.env` or `.secrets/`. Template only: `docker/.env.production.example`.

---

## Rollback procedure (one documented path)

```text
Deploy N
   ↓
Smoke FAIL  (or post-deploy incident)
   ↓
./scripts/rollback-production.sh     # loads .previous-tag → pull → up -d → health
   ↓
./scripts/smoke-test-production.sh   # Verify
```

`.previous-tag` is written at the start of each `deploy-production.sh` run (API + WEB image refs).

---

## Release metadata (contract for api PR2 `/version`)

When `/version` ships, payload SHOULD include at least:

| Field | Source |
|-------|--------|
| `git_sha` | `ROAMKIT_GIT_SHA` / build arg |
| `build_date` | `ROAMKIT_BUILD_DATE` |
| `image` / `image_tag` | `API_IMAGE` / `ROAMKIT_IMAGE_TAG` |
| `environment` | `ROAMKIT_ENVIRONMENT=production` |

PR1 only documents the env placeholders — **no api/web code in this PR**.

---

## Logging

Compose uses `json-file` driver with rotation (`max-size` / `max-file`) for api, celery, beat, web. Inspect:

```bash
docker logs --since 1h roamkit-api-production
```

Sentry / uptime alerting = PR3 (not this PR).

---

## Backup hooks (stub → PR4)

| Hook | PR1 status | Later |
|------|------------|-------|
| Postgres dump of `roamkit_production` | Documented intent | PR4 restore test |
| `.env` / `.secrets` encrypted offline | Operator responsibility | PR4 Disaster Day |
| Image tags in `.previous-tag` | ✅ | Continuous |

Suggested nightly (operator cron, not shipped as systemd unit in PR1):

```bash
# Example only — enable in PR4 after restore drill
# docker exec postgis pg_dump -U roamkit roamkit_production | gzip > /var/backups/roamkit_production_$(date +%F).sql.gz
```

---

## PR1 merge checklist

| Stavka | Status |
|--------|--------|
| Production compose reproducible | ☐ |
| Fresh bootstrap documented + scripts present | ☐ |
| Existing deployment upgrade path (`deploy-production.sh`) | ☐ |
| Rollback scripted (`rollback-production.sh`) | ☐ |
| Secrets not in repository (example only) | ☐ |
| Healthcheck policy documented + compose checks | ☐ |
| Container restart policy `unless-stopped` | ☐ |
| Persistent isolation (DB name + Redis index + stack dir) | ☐ |
| Logging configured (json-file rotation) | ☐ |
| Documentation updated (this PLAN + README + secrets) | ☐ |

---

## Cutover (out of scope for PR1)

Do **not** remove `roamkit.net` / `www` from staging Traefik Host rules until PR2 cutover checklist is green. Production routers may exist idle until DNS/traffic move.
