# GitHub Secrets — roamkit org

Never commit secret values. Set via `gh` from WSL.

## Org secrets (shared across repos)

| Secret | Purpose | Set command |
|--------|---------|-------------|
| `STAGING_HOST` | Hetzner server IP or hostname (not SSH config alias) | `gh secret set STAGING_HOST --org roamkit` |
| `STAGING_SSH_KEY` | SSH private key for deploy (root) | `gh secret set STAGING_SSH_KEY --org roamkit` |
| `GHCR_TOKEN` | Pull/push container images | `gh secret set GHCR_TOKEN --org roamkit` |

### Staging host (confirmed)

Server: Hetzner dedicated HEL1 — `65.108.196.92`, SSH user **`root`**.

WSL alias `dedicated-hel1` works locally only; GitHub Actions needs the IP:

```bash
echo -n "65.108.196.92" | gh secret set STAGING_HOST --org roamkit
gh secret set STAGING_SSH_KEY --org roamkit < ~/.ssh/id_ed25519
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
echo -n "value" | gh secret set SECRET_NAME --org roamkit

# Repo-level
echo -n "value" | gh secret set SECRET_NAME --repo roamkit/roamkit-api

# List (names only)
gh secret list --org roamkit
gh secret list --repo roamkit/roamkit-api
```

## Server-side secrets

Staging `.env` on Hetzner (`/opt/stacks/roamkit-net/.env`) holds runtime secrets.
GitHub Actions injects deploy credentials only; app secrets are on the server.
