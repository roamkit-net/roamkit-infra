# Deprecated — not used for staging

Staging routing is handled by the **shared host Traefik** at `/opt/stacks/traefik/`.

RoamKit containers register via Docker labels on the external `proxy` network. See:

- `docker/docker-compose.staging.yml`
- `bootstrap/hetzner/prerequisites.md`

These nginx configs were from an earlier per-stack nginx + certbot design and are kept for reference only.
