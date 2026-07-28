# GitHub Secrets — roamkit-net org

Never commit secret values. Set via `gh` from WSL.

## Org secrets (shared across repos)

| Secret | Purpose | Set command |
|--------|---------|-------------|
| `STAGING_HOST` | Hetzner server IP or hostname (not SSH config alias) | `gh secret set STAGING_HOST --org roamkit-net` |
| `STAGING_SSH_KEY` | SSH private key for deploy (root) | `gh secret set STAGING_SSH_KEY --org roamkit-net` |
| `PRODUCTION_HOST` | Same host IP for production stack (ADR 013) | `gh secret set PRODUCTION_HOST --org roamkit-net` |
| `PRODUCTION_SSH_KEY` | SSH key for production deploy (may equal staging key) | `gh secret set PRODUCTION_SSH_KEY --org roamkit-net` |
| `GHCR_TOKEN` | Pull/push container images | `gh secret set GHCR_TOKEN --org roamkit-net` |

### Staging host (confirmed)

Server: Hetzner dedicated HEL1 — `65.108.196.92`, SSH user **`root`**.

WSL alias `dedicated-hel1` works locally only; GitHub Actions needs the IP:

```bash
echo -n "65.108.196.92" | gh secret set STAGING_HOST --org roamkit-net
gh secret set STAGING_SSH_KEY --org roamkit-net < ~/.ssh/id_ed25519
```

## Repo secrets (per repository)

### roamkit-api

| Secret | Purpose |
|--------|---------|
| `DJANGO_SECRET_KEY` | Production/staging Django secret |
| `POSTGRES_PASSWORD` | Database password |
| `AIRALO_CLIENT_ID` | Airalo Partner API |
| `AIRALO_CLIENT_SECRET` | Airalo Partner API |
| `STRIPE_SECRET_KEY` | Stripe (staging: test key) |
| `STRIPE_WEBHOOK_SECRET` | Stripe webhook verification |

### roamkit-web

| Secret | Purpose |
|--------|---------|
| `NEXT_PUBLIC_API_URL` | API base URL (usually not secret; can be env) |

## Setting secrets

```bash
# Org-level
echo -n "value" | gh secret set SECRET_NAME --org roamkit-net

# Repo-level
echo -n "value" | gh secret set SECRET_NAME --repo roamkit-net/roamkit-api

# List (names only)
gh secret list --org roamkit-net
gh secret list --repo roamkit-net/roamkit-api
```

## Server-side secrets

Staging `.env` on Hetzner (`/opt/stacks/roamkit-net/.env`) holds runtime secrets.
GitHub Actions injects deploy credentials only; app secrets are on the server.

SMTP for auth emails (activation + password reset) lives on the server `.env` — do not commit:

```
EMAIL_HOST=mail.roamkit.net
EMAIL_PORT=587
EMAIL_USE_TLS=true
EMAIL_HOST_USER=info@roamkit.net
EMAIL_HOST_PASSWORD=<mailbox password>
DEFAULT_FROM_EMAIL=noreply@roamkit.net
FRONTEND_BASE_URL=https://staging.roamkit.net
```

`EMAIL_HOST_PASSWORD` is a server secret only (not a GitHub Actions secret unless you automate `.env` provisioning).

## Staging billing (Polygon USDT — ADR-010)

Runtime flags live on the server `.env` (see `docker/.env.staging.example`), not in GitHub Actions:

```
BILLING_ENABLED=true
SUBSCRIPTIONS_ENABLED=false
WALLETCONNECT_ENABLED=false
POLYGON_RPC_URL=https://polygon-bor-rpc.publicnode.com
POLYGON_PLATFORM_WALLET=0x...
POLYGON_USDT_CONTRACT=0xc2132D05D31c914a87C6611C10748AEb04B58e8F
POLYGON_CHAIN_ID=137
POLYGON_MIN_CONFIRMATIONS=20
```

- Keep `WALLETCONNECT_ENABLED=false` until Reown AppKit is confirmed on staging.
- Store the platform wallet **private key** only under `/opt/stacks/roamkit-net/.secrets/` (chmod 600); never commit it.
- After editing `.env`, recreate api/celery: `docker compose --profile app up -d api celery celery-beat`
- Verify with `./scripts/staging-dod-billing.sh` (deposit-info → verify → ledger → balance → order).
  Optional real on-chain path: `VERIFY_TX_HASH=0x... ./scripts/staging-dod-billing.sh`

## Production secrets (ADR 013 / Faza 4 PR1)

Runtime secrets live only on the server:

| Path | Contents |
|------|----------|
| `/opt/stacks/roamkit-production/.env` | App env (chmod 600); from `docker/.env.production.example` |
| `/opt/stacks/roamkit-production/.secrets/` | Offline material e.g. wallet private key (chmod 700 dir / 600 files) |

Isolation vs staging:

- `POSTGRES_DB=roamkit_production` (not `roamkit`)
- `REDIS_URL=redis://infra-redis:6379/5` (staging uses `/4`)

Lifecycle (create / rotate / backup): see `bootstrap/hetzner/PRODUCTION_PLAN.md` § Secrets lifecycle.

Org secrets for future `deploy-production` CI:

```bash
echo -n "65.108.196.92" | gh secret set PRODUCTION_HOST --org roamkit-net
# Often identical to staging key on the same host:
gh secret set PRODUCTION_SSH_KEY --org roamkit-net < ~/.ssh/id_ed25519
```

Cutover flag matrix remains: Billing ON, WalletConnect OFF, Subscriptions OFF.
