# RoamKit staging — zadaci na dedicated serveru

**Host:** `root@Ubuntu-2204-jammy-amd64-base`  
**Stack:** `/opt/stacks/roamkit-net`  
**Origin IP:** `65.108.196.92`  
**Traefik:** `/opt/stacks/traefik/` · mreža `proxy` · `certresolver=cloudflare`

Radi se **na serveru** (SSH) ili u **Cloudflare dashboardu**. GitHub secrets postavi iz WSL-a kad org token ima prava.

---

## Status

| Stavka | Status |
|--------|--------|
| Direktorij `/opt/stacks/roamkit-net` | OK |
| `docker-compose.yml` + `.env` + `scripts/` | OK |
| Mreža `proxy` + Traefik container | OK |
| Shared postgis + infra-redis | OK |
| Cloudflare DNS (`staging`, `api.staging` → proxied A) | OK (2026-07) |
| Cloudflare SSL mode Full / Full strict | Provjeri ručno u dashboardu |
| `.env` produkcijski secreti | TODO |
| GHCR image deploy | TODO (Faza 0) |

---

## 1. Provjera Traefika (na serveru)

```bash
cd /opt/stacks/roamkit-net

docker ps --filter name=traefik
docker network inspect proxy --format '{{.Name}}'
ss -tlnp | grep -E ':80|:443'
```

Očekivano:
- [ ] Container `traefik` je **Up**
- [ ] Mreža **`proxy`** postoji
- [ ] Portovi **80** i **443** slušaju na hostu

Detalji Traefika (referenca):

```bash
ls -la /opt/stacks/traefik/
docker inspect traefik --format '{{range .Config.Cmd}}{{println .}}{{end}}' | head -20
```

Ne mijenjaj Traefik config osim ako dodaješ novi cert resolver — RoamKit se samo spaja labelama.

---

## 2. Cloudflare DNS (dashboard)

Zona: **`roamkit.net`**

| Zapis | Tip | Ime | Vrijednost | Proxy |
|-------|-----|-----|------------|-------|
| Web staging | A | `staging` | `65.108.196.92` | Proxied (narančasti oblak) |
| API staging | A | `api.staging` | `65.108.196.92` | Proxied |

- [x] `staging.roamkit.net` → A → `65.108.196.92` (proxied)
- [x] `api.staging.roamkit.net` → A → `65.108.196.92` (proxied)

**SSL/TLS** (Cloudflare → SSL/TLS → Overview) — token nema read na SSL; provjeri ručno:
- [ ] Način: **Full** ili **Full (strict)** — **ne** Flexible

Provjera s servera (nakon propagacije, 1–5 min):

```bash
dig +short staging.roamkit.net A
dig +short api.staging.roamkit.net A
# Očekivano: Cloudflare proxy IP (ne nužno 65.108.196.92 — to je normalno za proxied)
```

---

## 3. `.env` na serveru

```bash
cd /opt/stacks/roamkit-net
nano .env
```

Shared servisi (kao `stay.hr` / `fiskal.hr`):

- `POSTGRES_HOST=postgis` — shared PostGIS (`/opt/stacks/data`, mreža `postgis`)
- `REDIS_URL=redis://infra-redis:6379/4` — shared Redis (`/opt/stacks/redis`, DB **4**)

Obavezno promijeni (ne ostavljaj `change-me`):

- [ ] `POSTGRES_PASSWORD` — lozinka za user `roamkit` na shared postgis
- [ ] `DJANGO_SECRET_KEY` — jak random (50+ znakova)
- [ ] `DJANGO_SETTINGS_MODULE=config.settings.staging`
- [ ] `DJANGO_DEBUG=false`
- [ ] `DJANGO_ALLOWED_HOSTS=api.staging.roamkit.net,staging.roamkit.net`
- [ ] `NEXT_PUBLIC_API_URL=https://api.staging.roamkit.net`

Kasnije (Faza 1+):
- [ ] `AIRALO_CLIENT_ID` / `AIRALO_CLIENT_SECRET`
- [ ] `STRIPE_*` (test ključevi)

Spremi: `chmod 600 .env`

---

## 4. Shared infra (provjera — nema lokalnih postgis/redis kontejnera)

RoamKit **ne** podiže vlastite `postgis` / `redis` kontejnere. Koristi shared stackove:

| Servis | Stack | Container | Mreža |
|--------|-------|-----------|-------|
| PostGIS | `/opt/stacks/data` | `postgis` | `postgis` |
| Redis | `/opt/stacks/redis` | `infra-redis` | `hetzner_net` |

```bash
docker ps --filter name=postgis --format '{{.Names}} {{.Status}}'
docker ps --filter name=infra-redis --format '{{.Names}} {{.Status}}'
docker exec postgis pg_isready -U postgres
docker exec infra-redis redis-cli ping
# Baza roamkit mora postojati na shared postgis (user roamkit + PostGIS ext)
```

- [ ] `postgis` Up (healthy)
- [ ] `infra-redis` Up (healthy)
- [ ] baza `roamkit` postoji

**Redis DB indeksi (referenca):** 0=mozart, 1=uzorita, 2=stay.hr, 3=racunai/sauber, **4=roamkit**, 5=fiskal

---

## 5. App servisi (kad GHCR imagei postoje)

```bash
cd /opt/stacks/roamkit-net
export API_IMAGE=ghcr.io/roamkit/roamkit-api:<tag>
export WEB_IMAGE=ghcr.io/roamkit/roamkit-web:<tag>
docker compose --profile app pull
docker compose --profile app up -d
```

Deklarativni spec: **`plan.yaml`**

- [ ] `roamkit-api-staging` healthy
- [ ] `roamkit-celery-staging` Up
- [ ] `roamkit-web-staging` healthy

---

## 6. Traefik routing provjera

```bash
docker logs traefik 2>&1 | tail -30 | grep -i roamkit || true
docker compose --profile app exec api curl -sf http://localhost:8000/health/live
docker compose --profile app exec web curl -sf http://localhost:3000/
curl -sf https://api.staging.roamkit.net/health/live
curl -sf https://staging.roamkit.net/
```

- [ ] Routeri `roamkit-api` / `roamkit-web` u Traefiku
- [ ] HTTPS radi; cert bez greške

---

## 7. Deploy skripta (pun pipeline)

```bash
cd /opt/stacks/roamkit-net
export API_IMAGE=ghcr.io/roamkit/roamkit-api:<tag>
export WEB_IMAGE=ghcr.io/roamkit/roamkit-web:<tag>
./scripts/deploy-staging.sh
```

- [ ] Migrate prošao
- [ ] Smoke test PASS

---

## 8. GitHub org secrets (iz WSL-a, ne s servera)

Kad `GH_TOKEN` ima **org admin** ili **Actions secrets: write**:

```bash
# Na Dell XPS / WSL
echo -n "65.108.196.92" | gh secret set STAGING_HOST --org roamkit
gh secret set STAGING_SSH_KEY --org roamkit < ~/.ssh/id_ed25519
```

- [ ] `STAGING_HOST` postavljen
- [ ] `STAGING_SSH_KEY` postavljen
- [ ] `GHCR_TOKEN` postavljen (za CI push/pull)

---

## 9. Troubleshooting

| Problem | Provjera |
|---------|----------|
| 502 Bad Gateway | `docker compose --profile app ps` — api/web Up? Na `proxy`? |
| Router se ne vidi | Traefik labele; `traefik.docker.network=proxy` |
| Cert greška | Cloudflare Full SSL; `certresolver=cloudflare` |
| DB connection fail | `.env` POSTGRES_*; `docker exec postgis pg_isready` |
| Redis fail | `REDIS_URL=redis://infra-redis:6379/4`; `docker exec infra-redis redis-cli ping` |
| DNS ne radi | Cloudflare A zapisi; propagacija |

Korisne naredbe:

```bash
cd /opt/stacks/roamkit-net
docker compose logs -f api
docker compose logs -f web
docker network inspect proxy --format '{{range .Containers}}{{.Name}} {{end}}'
```

---

## Redoslijed (preporuka)

1. **§2** Cloudflare DNS  
2. **§3** `.env` secreti (shared postgis + redis DB 4)  
3. **§4** provjera shared postgis + infra-redis  
4. **Faza 0** — api/web imagei na GHCR  
5. **§5–7** app stack + deploy skripta  
6. **§8** GitHub secrets (paralelno kad token spreman)

---

*Generirano iz roamkit-infra. Ažuriraj lokalno: `roamkit-infra/bootstrap/hetzner/SERVER_PLAN.md`*
