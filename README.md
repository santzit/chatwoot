# Chatwoot — Simplified Single-Domain Docker Deployment (v0.2x)

Self-hosted [Chatwoot](https://www.chatwoot.com/) + [Evolution API](https://doc.evolution-api.com/v2/pt/get-started/introduction) on a **single domain**, deployed with Docker Compose behind a **Traefik** reverse proxy. Six containers, two env files, zero proprietary scripts.

```
Internet
    │
    ▼
Traefik  (ports 80 / 443, automatic TLS via Let's Encrypt)
    │
    ├── app.chat.yourdomain.com  →  chatwoot         (Rails web server)
    └── evo.chat.yourdomain.com  →  chatwoot_evolution (Evolution API v2)

Shared network (chatwoot-net)
    ├── chatwoot-worker  (Sidekiq background worker)
    ├── chatwoot_postgres  (PostgreSQL 16 + pgvector)
    └── chatwoot_redis     (Redis 7)
```

---

## Stack

| Container | Image | Purpose |
|---|---|---|
| `chatwoot_traefik` | `traefik:v3.6` | Reverse proxy, TLS termination (Let's Encrypt) |
| `chatwoot_postgres` | `pgvector/pgvector:pg16` | Relational database (chatwoot + evolution DBs) |
| `chatwoot_redis` | `redis:7-alpine` | Cache and Sidekiq job queues |
| `chatwoot` | `chatwoot/chatwoot:v4.11.2` | Rails web server (runs DB migrations on start) |
| `chatwoot-worker` | `chatwoot/chatwoot:v4.11.2` | Sidekiq background worker |
| `chatwoot_evolution` | `evoapicloud/evolution-api:v2.3.7` | WhatsApp bridge (Evolution API v2) |

**Environment files** (kept separate so each app's configuration is self-contained):

| File | Purpose |
|---|---|
| `.env` | Shared infra: domain, ACME e-mail, Postgres and Redis credentials |
| `chatwoot.env` | Chatwoot application vars (secrets, DB, Redis, SMTP) |
| `evolution.env` | Evolution API vars (API key, DB, Redis, integration flags) |

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Ubuntu 22.04 or 24.04 LTS | Other Linux distros work |
| Docker ≥ 24 + Docker Compose v2 | `curl -fsSL https://get.docker.com \| sh` |
| A DNS A record for the app subdomain | e.g. `app.chat.yourdomain.com → <server-ip>` |
| A DNS A record for the evo subdomain | e.g. `evo.chat.yourdomain.com → <server-ip>` |
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
DOMAIN=chat.yourdomain.com              # ← base domain (no protocol prefix)
ACME_EMAIL=you@yourdomain.com           # ← plain e-mail for Let's Encrypt
POSTGRES_USERNAME=chatwoot
POSTGRES_PASSWORD=<strong-password>     # openssl rand -hex 32
REDIS_PASSWORD=<strong-password>        # openssl rand -hex 32
```

With `DOMAIN=chat.yourdomain.com`, Traefik will serve:
- Chatwoot at `https://app.chat.yourdomain.com`
- Evolution API at `https://evo.chat.yourdomain.com`

> ⚠️ `ACME_EMAIL` must be a plain address — no display name, no angle brackets.
> Using `@example.com` is rejected by Let's Encrypt with "forbidden domain".

---

### 3. Configure chatwoot.env (Chatwoot application)

```bash
cp chatwoot.env.example chatwoot.env
chmod 600 chatwoot.env
```

Edit `chatwoot.env` and fill in every value. Generate the required secrets:

```bash
openssl rand -hex 64   # → SECRET_KEY_BASE
openssl rand -hex 32   # → ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
openssl rand -hex 32   # → ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
openssl rand -hex 32   # → ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
```

Set the database and Redis credentials to match `.env`:

```env
POSTGRES_USERNAME=chatwoot              # same as .env
POSTGRES_PASSWORD=<same-as-env>         # same as .env
REDIS_URL=redis://:<same-as-env-redis-password>@redis:6379/0
```

Fill in the SMTP block so Chatwoot can send invitation and notification e-mails:

```env
SMTP_ADDRESS=smtp.example.com
SMTP_PORT=587
SMTP_DOMAIN=yourdomain.com
SMTP_USERNAME=user@example.com
SMTP_PASSWORD=<smtp-password>
SMTP_AUTHENTICATION=plain
SMTP_ENABLE_STARTTLS_AUTO=true
MAILER_SENDER_EMAIL=support@yourdomain.com
```

> 💡 Free SMTP relays: [Resend](https://resend.com), [SendGrid](https://sendgrid.com), [Mailgun](https://mailgun.com).

> ℹ️ `FRONTEND_URL` is set automatically by `docker-compose.yml` from `DOMAIN` — do not add it to `chatwoot.env`.

---

### 4. Configure evolution.env (Evolution API)

```bash
cp evolution.env.example evolution.env
chmod 600 evolution.env
```

Edit `evolution.env`:

```bash
openssl rand -hex 32   # → AUTHENTICATION_API_KEY
```

Set the database URI using the same credentials as `.env` and the `evolution` database name:

```env
AUTHENTICATION_API_KEY=<generated-key>
DATABASE_CONNECTION_URI=postgresql://chatwoot:<postgres-password>@postgres:5432/evolution
CACHE_REDIS_URI=redis://:<redis-password>@redis:6379/1
```

> ℹ️ `SERVER_URL` is set automatically by `docker-compose.yml` from `DOMAIN` — do not add it to `evolution.env`.

---

### 5. Create acme.json (TLS certificate storage)

Traefik requires this file to exist with strict permissions before it starts:

```bash
install -m 600 /dev/null acme.json
```

---

### 6. Start PostgreSQL and Redis

```bash
docker compose up -d postgres redis
```

Wait until both are healthy:

```bash
docker compose ps
```

Expected: both show `healthy`.

---

### 7. Create the evolution database

The `chatwoot` database is created **automatically** by Docker (via `POSTGRES_DB: chatwoot` in `docker-compose.yml`). The `evolution` database must be created once manually:

```bash
docker compose exec postgres psql -U chatwoot -c "CREATE DATABASE evolution;"
```

You can verify both databases exist:

```bash
docker compose exec postgres psql -U chatwoot -c "\l"
```

---

### 8. Start all services

```bash
docker compose up -d
```

On first start, the `chatwoot` container automatically runs `bundle exec rails db:chatwoot_prepare` before starting the web server. This creates all tables and applies the full schema — it may take 1–3 minutes. The `chatwoot-worker` container waits until the web server is healthy before it starts, ensuring migrations always complete first.

Follow the startup logs to confirm everything is working:

```bash
docker compose logs -f chatwoot
```

Look for a line like:
```
* Listening on http://0.0.0.0:3000
```

Once it appears, `chatwoot-worker` will start automatically. Open `https://app.chat.yourdomain.com` in your browser. Traefik issues the TLS certificate automatically via Let's Encrypt (may take up to 60 seconds on first request — DNS must be live).

> ⚠️ DNS A records for both `app.chat.yourdomain.com` and `evo.chat.yourdomain.com` must resolve to your server IP before Traefik can complete the ACME challenge.

---

## Management

### View logs

```bash
# All services
docker compose logs -f

# Chatwoot web server
docker compose logs -f chatwoot

# Chatwoot background worker
docker compose logs -f chatwoot-worker

# Evolution API
docker compose logs -f evolution

# Postgres / Redis
docker compose logs -f postgres
docker compose logs -f redis
```

### Rails console (advanced operations)

```bash
docker exec -it chatwoot bundle exec rails console
```

### Restart a service

```bash
docker compose restart chatwoot
docker compose restart evolution
```

### Service status

```bash
docker compose ps
```

---

## Upgrading

Pull the latest images and restart:

```bash
docker compose pull chatwoot chatwoot-worker evolution traefik
docker compose up -d
```

The `chatwoot` web container automatically applies pending database migrations (`db:chatwoot_prepare`) on every restart. The `chatwoot-worker` waits for the web container to become healthy before starting, so migrations always complete before Sidekiq processes any jobs — no manual migration step is needed.

To upgrade PostgreSQL or Redis, pull and restart those services individually:

```bash
docker compose pull postgres redis
docker compose up -d postgres redis
```

---

## Backup and restore

### Backup the Chatwoot database

```bash
docker compose exec postgres \
  pg_dump -U chatwoot -d chatwoot \
  | gzip > backups/chatwoot_$(date +%Y%m%d_%H%M%S).sql.gz
```

### Backup the Evolution API database

```bash
docker compose exec postgres \
  pg_dump -U chatwoot -d evolution \
  | gzip > backups/evolution_$(date +%Y%m%d_%H%M%S).sql.gz
```

### Restore a Chatwoot backup

```bash
gunzip -c backups/chatwoot_<timestamp>.sql.gz \
  | docker compose exec -T postgres \
      psql -U chatwoot -d chatwoot
```

### Backup uploaded files (local storage)

```bash
docker run --rm \
  -v chatwoot_chatwoot_storage:/data \
  -v "$(pwd)/backups":/backups \
  alpine \
  tar czf /backups/chatwoot_storage_$(date +%Y%m%d_%H%M%S).tar.gz -C /data .
```

---

## Connecting Evolution API to a WhatsApp number

1. Open `https://evo.chat.yourdomain.com` in your browser.
2. Authenticate with the `AUTHENTICATION_API_KEY` from `evolution.env`.
3. Create a new instance, scan the QR code with WhatsApp.
4. Link the instance to Chatwoot via **Settings → Integrations → Evolution API** inside Chatwoot, or via the Evolution API REST endpoint:

```bash
# Read your Evolution API key
EVO_KEY=$(grep AUTHENTICATION_API_KEY evolution.env | cut -d= -f2)

# Link instance to Chatwoot
# Replace <instance>, <chatwoot-account-id>, and <chatwoot-agent-token>
curl -s -X POST \
  "https://evo.chat.yourdomain.com/chatwoot/set/<instance>" \
  -H "apikey: $EVO_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "enabled": true,
    "accountId": "<chatwoot-account-id>",
    "token": "<chatwoot-agent-token>",
    "url": "http://chatwoot:3000",
    "signMsg": true,
    "reopenConversation": true,
    "conversationPending": false,
    "nameInbox": "WhatsApp",
    "importContacts": true,
    "importMessages": true,
    "daysLimitImportMessages": 3,
    "autoCreate": true
  }'
```

> �� Obtain the Chatwoot `accountId` and `token` from **Settings → Integrations → API** in the Chatwoot UI.

---

## Troubleshooting

### Chatwoot takes a long time to start

On first start, `db:chatwoot_prepare` loads the full database schema. This is normal and takes 1–3 minutes. Follow the logs with `docker compose logs -f chatwoot`.

### `Error: Database provider  invalid` (Evolution API exits with code 1)

This means `DATABASE_PROVIDER` in `evolution.env` is empty or unset. This often happens when the file was transferred from Windows and contains CRLF line endings that confuse the env parser.

Check the value:

```bash
grep DATABASE_PROVIDER evolution.env
```

If the output is `DATABASE_PROVIDER=` (empty) or the value shows invisible characters, fix it:

```bash
# Set correct value
sed -i 's/\r//' evolution.env            # strip Windows CRLF if present
sed -i 's/^DATABASE_PROVIDER=.*/DATABASE_PROVIDER=postgresql/' evolution.env
docker compose up -d evolution
```

If you are creating the file from scratch, ensure the line is exactly:
```
DATABASE_PROVIDER=postgresql
```

### `middleware "redirect-https@docker" does not exist` (Traefik)

This error appears when the Evolution API container starts before the Chatwoot container (which previously defined the shared `redirect-https` middleware). Fixed in commit `514f1a7` and later — each service now defines the middleware independently. Pull the latest changes and re-deploy:

```bash
git pull
docker compose up -d
```



`ACME_EMAIL` in `.env` is empty or has a display-name format:

```bash
nano .env
# Must be a plain address:
#   ✔  ACME_EMAIL=you@yourdomain.com
#   ✖  ACME_EMAIL=Your Name <you@yourdomain.com>

docker compose restart traefik
```

### `contact email has forbidden domain "example.com"`

`ACME_EMAIL` still contains the placeholder. Set a real address in `.env` and restart Traefik.

### `permissions 755 for /acme.json are too open`

```bash
chmod 600 acme.json
docker compose restart traefik
```

### Traefik shows "404 page not found" on `https://app.chat.yourdomain.com`

Traefik returns 404 when no router matches the incoming request. This almost always means the `chatwoot` container is not running or is still starting up. Check service status:

```bash
docker compose ps
docker compose logs chatwoot
```

Common causes and fixes:

| Symptom | Cause | Fix |
|---|---|---|
| `chatwoot` in "Created" or "Exited" state | A dependency (postgres/redis) was unhealthy | `docker compose up -d` — starts remaining services |
| `chatwoot` container keeps restarting | Startup error (DB not ready) | Check `docker compose logs chatwoot` for the error |
| Traefik running, chatwoot running, but still 404 | DNS A record for `app.chat.yourdomain.com` not pointing to this server | Verify DNS: `dig app.chat.yourdomain.com` |
| `DOMAIN` placeholder not replaced | `.env` still has `DOMAIN=chat.yourdomain.com` | Edit `.env` with your real domain, then `docker compose up -d` |


### TLS certificate not issued

1. Confirm DNS has propagated: `dig app.chat.yourdomain.com`
2. Confirm port 80 is reachable from the internet.
3. Check Traefik logs: `docker compose logs traefik | grep -i acme`

### Chatwoot is not sending e-mails

SMTP is not configured or is misconfigured. Edit `chatwoot.env`, update the `SMTP_*` block, then restart:

```bash
docker compose restart chatwoot
```

### `FATAL: database "chatwoot" does not exist`

The postgres container was started without the `POSTGRES_DB: chatwoot` environment variable. Remove the volume and let it re-initialise:

```bash
docker compose down -v
docker compose up -d postgres redis
# Wait for healthy, then:
docker compose exec postgres psql -U chatwoot -c "CREATE DATABASE evolution;"
docker compose up -d
```

### `FATAL: database "evolution" does not exist`

The evolution database was not created. While postgres is running:

```bash
docker compose exec postgres psql -U chatwoot -c "CREATE DATABASE evolution;"
docker compose restart evolution
```

### Redis `WARNING Memory overcommit must be enabled!`

This warning is a cosmetic kernel advisory. To silence it permanently on the host:

```bash
echo 'vm.overcommit_memory = 1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## Security notes

- `.env`, `chatwoot.env`, and `evolution.env` are listed in `.gitignore` — never commit them.
- `acme.json` is also gitignored — it contains your TLS private keys.
- Generate unique cryptographic secrets for each deployment.
- PostgreSQL and Redis have **no published ports** — accessible only inside `chatwoot-net`.
- Traefik only routes containers carrying the `traefik.enable=true` label.
- Back up your env files and `acme.json` — losing them means losing access to your data and TLS certificates.

---

## Env file reference

### .env

| Variable | Required | Description |
|---|---|---|
| `DOMAIN` | ✅ | Base domain; Chatwoot served at `app.<DOMAIN>`, Evolution at `evo.<DOMAIN>` (e.g. `chat.yourdomain.com`) |
| `ACME_EMAIL` | ✅ | Plain e-mail for Let's Encrypt certificate registration |
| `POSTGRES_USERNAME` | ✅ | PostgreSQL superuser name |
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
| `POSTGRES_DATABASE` | ✅ | Must be `chatwoot` |
| `POSTGRES_USERNAME` | ✅ | Same as `.env` |
| `POSTGRES_PASSWORD` | ✅ | Same as `.env` |
| `REDIS_URL` | ✅ | `redis://:<password>@redis:6379/0` |
| `SMTP_ADDRESS` | ✅ | SMTP server hostname |
| `SMTP_PORT` | ✅ | SMTP port (usually 587) |
| `SMTP_USERNAME` | ✅ | SMTP username |
| `SMTP_PASSWORD` | ✅ | SMTP password |
| `MAILER_SENDER_EMAIL` | ✅ | Sender address for outbound e-mails |

### evolution.env

| Variable | Required | Description |
|---|---|---|
| `AUTHENTICATION_API_KEY` | ✅ | Master API key (`openssl rand -hex 32`) |
| `DATABASE_CONNECTION_URI` | ✅ | PostgreSQL URI using the `evolution` database |
| `CACHE_REDIS_URI` | ✅ | Redis URI using DB index 1 |
| `CHATWOOT_ENABLED` | ✅ | Must be `true` to enable the Chatwoot integration |
| `DEL_INSTANCE` | — | `false` — preserve instances across restarts |
