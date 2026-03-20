# Chatwoot — Docker Production Deployment (v0.2x)

Self-hosted [Chatwoot](https://www.chatwoot.com/) on a single domain, deployed with Docker Compose behind a **Traefik** reverse proxy. Based on the [official Chatwoot production template](https://github.com/chatwoot/chatwoot/blob/develop/docker-compose.production.yaml).

```
Internet
    │
    ▼
Traefik  (ports 80 / 443, automatic TLS via Let's Encrypt)
    │
    └── app.chat.yourdomain.com  →  chatwoot_rails (Rails web server)

Shared network (chatwoot-net)
    ├── chatwoot_sidekiq   (Sidekiq background worker)
    ├── chatwoot_postgres  (PostgreSQL 16 + pgvector)
    └── chatwoot_redis     (Redis)
```

---

## Stack

| Container | Image | Purpose |
|---|---|---|
| `chatwoot_traefik` | `traefik:v3.6` | Reverse proxy, TLS termination (Let's Encrypt) |
| `chatwoot_postgres` | `pgvector/pgvector:pg16` | Relational database |
| `chatwoot_redis` | `redis:alpine` | Cache and Sidekiq job queues |
| `chatwoot_rails` | `chatwoot/chatwoot:latest` | Rails web server (runs DB migrations on start) |
| `chatwoot_sidekiq` | `chatwoot/chatwoot:latest` | Sidekiq background worker |

**Environment files:**

| File | Purpose |
|---|---|
| `.env` | Shared infra: domain, ACME e-mail, Postgres and Redis credentials |
| `chatwoot.env` | Chatwoot application vars (secrets, DB, Redis, SMTP) |

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Ubuntu 22.04 or 24.04 LTS | Other Linux distros work |
| Docker >= 24 + Docker Compose v2 | `curl -fsSL https://get.docker.com \| sh` |
| A DNS A record for the app subdomain | e.g. `app.chat.yourdomain.com -> <server-ip>` |
| Ports 80 and 443 open | Required by Traefik and the ACME HTTP-01 challenge |

---

## First-time setup

### 1. Clone the repository

```bash
git clone https://github.com/santzit/chatwoot.git /opt/chatwoot
cd /opt/chatwoot
```

---

### 2. Configure .env (shared infrastructure)

```bash
cp .env.example .env
```

Edit `.env` and fill in every value:

```env
DOMAIN=chat.yourdomain.com              # base domain (no protocol prefix)
ACME_EMAIL=you@yourdomain.com           # plain e-mail for Let's Encrypt
POSTGRES_USER=chatwoot
POSTGRES_PASSWORD=<strong-password>     # openssl rand -hex 32
REDIS_PASSWORD=<strong-password>        # openssl rand -hex 32
```

With `DOMAIN=chat.yourdomain.com`, Traefik will serve Chatwoot at `https://app.chat.yourdomain.com`.

> ⚠️ `ACME_EMAIL` must be a plain address — no display name, no angle brackets.

---

### 3. Configure chatwoot.env (Chatwoot application)

```bash
cp chatwoot.env.example chatwoot.env
chmod 600 chatwoot.env
```

Edit `chatwoot.env` and fill in every value. Generate the required secrets:

```bash
openssl rand -hex 64   # SECRET_KEY_BASE
openssl rand -hex 32   # ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
openssl rand -hex 32   # ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
openssl rand -hex 32   # ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
```

Set the database and Redis credentials to match `.env`:

```env
POSTGRES_USERNAME=chatwoot              # same as POSTGRES_USER in .env
POSTGRES_PASSWORD=<same-as-env>
REDIS_URL=redis://:<redis-password>@redis:6379/0
```

Fill in the SMTP block so Chatwoot can send e-mails:

```env
SMTP_ADDRESS=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=user@example.com
SMTP_PASSWORD=<smtp-password>
MAILER_SENDER_EMAIL=support@yourdomain.com
```

> 💡 Free SMTP relays: [Resend](https://resend.com), [SendGrid](https://sendgrid.com), [Mailgun](https://mailgun.com).

> ℹ️ `FRONTEND_URL`, `NODE_ENV`, `RAILS_ENV`, and `INSTALLATION_ENV` are set automatically by `docker-compose.yml` — do not add them to `chatwoot.env`.

---

### 4. Create acme.json (TLS certificate storage)

```bash
install -m 600 /dev/null acme.json
```

---

### 5. Start all services

```bash
docker compose up -d
```

On first start, the `rails` container automatically runs `db:chatwoot_prepare` (creates all tables and applies the full schema) before starting the web server. This takes 1–3 minutes. The `sidekiq` container waits until `rails` is healthy before starting.

Follow the startup logs:

```bash
docker compose logs -f rails
```

Look for a line like:
```
* Listening on http://0.0.0.0:3000
```

Once it appears, open `https://app.chat.yourdomain.com` in your browser. Traefik issues the TLS certificate automatically via Let's Encrypt (allow up to 60 seconds on first request — DNS must be live).

---

## Management

### View logs

```bash
# All services
docker compose logs -f

# Rails web server
docker compose logs -f rails

# Sidekiq background worker
docker compose logs -f sidekiq

# Postgres / Redis
docker compose logs -f postgres
docker compose logs -f redis
```

### Rails console (advanced operations)

```bash
docker exec -it chatwoot_rails bundle exec rails console
```

### Restart a service

```bash
docker compose restart rails
docker compose restart sidekiq
```

### Service status

```bash
docker compose ps
```

---

## Upgrading

Pull the latest images and restart:

```bash
docker compose pull
docker compose up -d
```

The `rails` container automatically applies pending database migrations on every restart. The `sidekiq` container waits for `rails` to become healthy — no manual migration step needed.

---

## Backup and restore

### Backup the Chatwoot database

```bash
docker compose exec postgres \
  pg_dump -U chatwoot -d chatwoot \
  | gzip > backups/chatwoot_$(date +%Y%m%d_%H%M%S).sql.gz
```

### Restore a backup

```bash
gunzip -c backups/chatwoot_<timestamp>.sql.gz \
  | docker compose exec -T postgres \
      psql -U chatwoot -d chatwoot
```

### Backup uploaded files (local storage)

```bash
docker run --rm \
  -v chatwoot_storage_data:/data \
  -v "$(pwd)/backups":/backups \
  alpine \
  tar czf /backups/chatwoot_storage_$(date +%Y%m%d_%H%M%S).tar.gz -C /data .
```

---

## Troubleshooting

### Chatwoot takes a long time to start

On first start, `db:chatwoot_prepare` loads the full database schema. This is normal and takes 1–3 minutes. Follow the logs with `docker compose logs -f rails`.

### HTTP 500 — `relation "installation_configs" does not exist`

This means the database schema is empty — `db:chatwoot_prepare` ran but the tables were never created. The most common cause is a **stale postgres volume** from a previous failed deployment: the `chatwoot_production` database already existed (so `db:prepare` skipped `db:schema:load`) but the schema was never fully applied.

**Fix (recommended — on first deploy or when there is no data to keep):**
```bash
docker compose down -v        # removes volumes — clears the broken DB state
docker compose up -d          # fresh start: postgres creates DB, rails loads schema
```

Wait 3–5 minutes for migrations to complete after the first `docker compose up -d`.

**Alternative — if you have real data to preserve:**
```bash
docker exec chatwoot_rails bundle exec rails db:schema:load   # force-loads full schema
docker compose restart rails
```

> `db:schema:load` drops and recreates all tables. Use only if you have a backup or no data to lose.

### `unable to parse email address` (ACME / Let's Encrypt)

`ACME_EMAIL` in `.env` is empty or has a display-name format. Fix it and clear the stale ACME cache:

```bash
nano .env
# Must be a plain address: ACME_EMAIL=you@yourdomain.com

docker compose stop traefik
echo '{}' > acme.json && chmod 600 acme.json
docker compose up -d traefik
```

### `permissions 755 for /acme.json are too open`

```bash
chmod 600 acme.json
docker compose restart traefik
```

### Traefik shows "404 page not found"

Traefik returns 404 when no router matches. This usually means the `rails` container is not running or still starting. Check:

```bash
docker compose ps
docker compose logs rails
```

| Symptom | Cause | Fix |
|---|---|---|
| `rails` in "Created" or "Exited" state | A dependency was unhealthy | `docker compose up -d` |
| `rails` keeps restarting | Startup error | Check `docker compose logs rails` |
| Still 404 after rails is healthy | DNS A record not pointing to this server | `dig app.chat.yourdomain.com` |

### `rails` container shows `(unhealthy)` after first deploy

On first start, migrations take 3–5 minutes before Rails accepts HTTP connections. If the healthcheck expired before migrations finished, reset it:

```bash
docker exec chatwoot_rails nc -z localhost 3000 && echo "PORT OPEN"
# If PORT OPEN, rails is fine — restart to reset the healthcheck state:
docker compose restart rails
docker compose up -d
```

### TLS certificate not issued

1. Confirm DNS has propagated: `dig app.chat.yourdomain.com`
2. Confirm port 80 is reachable from the internet.
3. Check Traefik logs: `docker compose logs traefik | grep -i acme`

### Chatwoot is not sending e-mails

SMTP is misconfigured. Edit `chatwoot.env`, update the `SMTP_*` block, then restart:

```bash
docker compose restart rails sidekiq
```

---

## Security notes

- `.env` and `chatwoot.env` are listed in `.gitignore` — never commit them.
- `acme.json` is also gitignored — it contains your TLS private keys.
- Generate unique cryptographic secrets for each deployment.
- PostgreSQL and Redis have **no published ports** — accessible only inside `chatwoot-net`.
- Traefik only routes containers carrying the `traefik.enable=true` label.

---

## Env file reference

### .env

| Variable | Required | Description |
|---|---|---|
| `DOMAIN` | ✅ | Base domain; Chatwoot served at `app.<DOMAIN>` (e.g. `chat.yourdomain.com`) |
| `ACME_EMAIL` | ✅ | Plain e-mail for Let's Encrypt certificate registration |
| `POSTGRES_USER` | ✅ | PostgreSQL superuser name |
| `POSTGRES_PASSWORD` | ✅ | PostgreSQL superuser password |
| `REDIS_PASSWORD` | ✅ | Redis authentication password |

### chatwoot.env

| Variable | Required | Description |
|---|---|---|
| `SECRET_KEY_BASE` | ✅ | Rails secret key (`openssl rand -hex 64`) |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | ✅ | Encryption key (`openssl rand -hex 32`) |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | ✅ | Encryption salt (`openssl rand -hex 32`) |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | ✅ | Encryption primary key (`openssl rand -hex 32`) |
| `POSTGRES_HOST` | ✅ | Must be `postgres` (Docker Compose service name) |
| `POSTGRES_DATABASE` | ✅ | Must be `chatwoot_production` |
| `POSTGRES_USERNAME` | ✅ | Same as `POSTGRES_USER` in `.env` |
| `POSTGRES_PASSWORD` | ✅ | Same as `POSTGRES_PASSWORD` in `.env` |
| `REDIS_URL` | ✅ | `redis://:<password>@redis:6379/0` |
| `SMTP_ADDRESS` | ✅ | SMTP server hostname |
| `SMTP_PORT` | ✅ | SMTP port (usually 587) |
| `SMTP_USERNAME` | ✅ | SMTP username |
| `SMTP_PASSWORD` | ✅ | SMTP password |
| `MAILER_SENDER_EMAIL` | ✅ | Sender address for outbound e-mails |
