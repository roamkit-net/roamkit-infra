# Hetzner staging prerequisites

Complete this checklist before the first RoamKit deploy to `/opt/stacks/roamkit-net/`.

## 1. SSH access (WSL)

```bash
ssh dedicated-hel1
# or: ssh root@65.108.196.92
```

Requires `~/.ssh/id_ed25519` and host entry in `~/.ssh/config`.

## 2. Shared Traefik

Traefik runs at `/opt/stacks/traefik/` on the host. Verify:

```bash
docker ps --filter name=traefik
docker network inspect proxy
```

- Container listens on host ports **80** and **443**
- External Docker network **`proxy`** exists
- Cert resolver **`cloudflare`** configured in Traefik static config

RoamKit does **not** install Traefik — it joins the existing `proxy` network via Docker labels.

## 3. Cloudflare DNS

Create proxied records (orange cloud ON) pointing to **`65.108.196.92`**:

| Name | Type | Target |
|------|------|--------|
| `staging.roamkit.net` | A (or AAAA) | `65.108.196.92` |
| `api.staging.roamkit.net` | A (or AAAA) | `65.108.196.92` |

SSL/TLS mode in Cloudflare: **Full** or **Full (strict)** — not Flexible.

## 4. Initialize stack directory

From WSL (script runs on server via SSH):

```bash
ssh dedicated-hel1 'bash -s' < roamkit-infra/bootstrap/hetzner/init-staging-stack.sh
```

Or on the server directly after cloning `roamkit-infra`.

Creates:

```
/opt/stacks/roamkit-net/
├── docker-compose.yml
├── .env
├── data/postgis/
├── data/redis/
└── scripts/
```

## 5. Configure `.env`

Edit `/opt/stacks/roamkit-net/.env` on the server — set `POSTGRES_PASSWORD`, `DJANGO_SECRET_KEY`, and image tags before first deploy.

## 6. GitHub secrets (before CI deploy)

```bash
echo -n "65.108.196.92" | gh secret set STAGING_HOST --org roamkit-net
gh secret set STAGING_SSH_KEY --org roamkit-net < ~/.ssh/id_ed25519
```

See [../github/secrets.md](../github/secrets.md).

## 7. First deploy

After `roamkit-api` and `roamkit-web` images exist in GHCR:

```bash
ssh dedicated-hel1
cd /opt/stacks/roamkit-net
export API_IMAGE=ghcr.io/roamkit-net/roamkit-api:<tag>
export WEB_IMAGE=ghcr.io/roamkit-net/roamkit-web:<tag>
./scripts/deploy-staging.sh
```

Smoke test URLs: `https://staging.roamkit.net`, `https://api.staging.roamkit.net/health/ready`.

## Server task checklist

On the Hetzner host: **`/opt/stacks/roamkit-net/PLAN.md`** and **`plan.yaml`**. Source: [SERVER_PLAN.md](./SERVER_PLAN.md), [plan.yaml](./plan.yaml).
