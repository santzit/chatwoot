# Chatwoot — Multi-Tenant Self-Hosted Docker Compose

Self-hosted [Chatwoot](https://www.chatwoot.com/) platform that runs **multiple isolated company instances** behind a single **Traefik** reverse proxy, sharing one PostgreSQL cluster and one Redis instance.

```
Internet
    │
    ▼
Traefik  (ports 80 / 443, automatic TLS via Let's Encrypt)
    │
    ├── company1.chat.yourdomain.com  →  chatwoot_company1_web
    ├── company2.chat.yourdomain.com  →  chatwoot_company2_web
    └── company3.chat.yourdomain.com  →  chatwoot_company3_web

Shared infrastructure
    ├── PostgreSQL 16  (one database per company)
    └── Redis 7
```

---

## Directory structure

```
chatwoot-platform/
│
├── infrastructure/
│   ├── traefik/
│   │   ├── docker-compose.yml   # Traefik reverse proxy
│   │   ├── traefik.yml          # Traefik static config
│   │   ├── .env.example         # → copy to .env, set ACME_EMAIL
│   │   └── acme.json            # Let's Encrypt cert store (create manually, chmod 600)
│   │
│   ├── postgres/
│   │   ├── docker-compose.yml   # PostgreSQL shared cluster
│   │   └── .env.example         # → copy to .env, set POSTGRES_USERNAME / PASSWORD
│   │
│   └── redis/
│       ├── docker-compose.yml   # Redis shared instance
│       └── .env.example         # → copy to .env, set REDIS_PASSWORD
│
├── chatwoot-template/
│   ├── docker-compose.yml       # Shared template — same for every company
│   └── example.env              # Company env template
│
├── companies/                   # Per-company .env files (all gitignored)
│   └── .gitkeep
│
├── scripts/
│   ├── create-company.sh        # Provision DB + env + start containers
│   └── backup-postgres.sh       # Dump company databases to backups/
│
└── backups/                     # Backup output directory
    └── .gitkeep
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Ubuntu 22.04 or 24.04 LTS | Other Linux distros work too |
| Docker ≥ 24 + Docker Compose v2 | Install: `curl -fsSL https://get.docker.com \| sh` |
| DNS A record for each company | e.g. `company1.chat.yourdomain.com → <server-ip>` |
| Ports 80 and 443 open | Required by Traefik and the Let's Encrypt HTTP-01 challenge |

---

## Tutorial — First-time setup

### 1. Clone the repository

```bash
git clone https://github.com/santzit/chatwoot.git /opt/chatwoot
cd /opt/chatwoot
```

---

### 2. Configure Traefik

Copy the example env and fill in your real e-mail address.
Let's Encrypt sends certificate expiry notices to this address.

```bash
cp infrastructure/traefik/.env.example infrastructure/traefik/.env
```

Edit `infrastructure/traefik/.env`:

```env
ACME_EMAIL=you@yourdomain.com    # ← replace with your real e-mail
```

> ⚠️ **Do not use an `@example.com` address.** Let's Encrypt will reject the
> account registration with `contact email has forbidden domain "example.com"`.

Create the certificate storage file with strict permissions (required by Traefik):

```bash
install -m 600 /dev/null infrastructure/traefik/acme.json
```

---

### 3. Configure PostgreSQL

```bash
cp infrastructure/postgres/.env.example infrastructure/postgres/.env
```

Edit `infrastructure/postgres/.env`:

```env
POSTGRES_USERNAME=chatwoot
POSTGRES_PASSWORD=<strong-password>    # generate: openssl rand -hex 32
```

> ⚠️ **Remember this password** — every company env file must use the same value.

---

### 4. Configure Redis

```bash
cp infrastructure/redis/.env.example infrastructure/redis/.env
```

Edit `infrastructure/redis/.env`:

```env
REDIS_PASSWORD=<strong-password>    # generate: openssl rand -hex 32
```

---

### 5. Start the infrastructure

Start each component in order. Traefik must come first because it declares the
`chatwoot-net` Docker network that the other containers join.

```bash
# 1. Traefik (creates chatwoot-net)
docker compose -f infrastructure/traefik/docker-compose.yml up -d

# 2. PostgreSQL
docker compose -f infrastructure/postgres/docker-compose.yml up -d

# 3. Redis
docker compose -f infrastructure/redis/docker-compose.yml up -d
```

Verify everything is healthy:

```bash
docker compose -f infrastructure/traefik/docker-compose.yml ps
docker compose -f infrastructure/postgres/docker-compose.yml ps
docker compose -f infrastructure/redis/docker-compose.yml ps
```

Expected output for each: `Status: Up (healthy)` or `Up` for Traefik.

---

### 6. Create your first company

Use the provided script — it handles database creation, secret generation, and
container startup automatically:

```bash
scripts/create-company.sh company1 company1.chat.yourdomain.com
```

What the script does:
1. Creates the database `chatwoot_company1` in PostgreSQL.
2. Copies `chatwoot-template/example.env` to `companies/company1.env` and
   substitutes all values (credentials from infra `.env` files, freshly
   generated crypto secrets).
3. Runs `rails db:chatwoot_prepare` (schema migration) before starting
   persistent containers — prevents the `FATAL: database does not exist`
   flood that occurs when the app starts before its schema is provisioned.
4. Starts `chatwoot_company1_web` and `chatwoot_company1_worker`.

After the script completes, open `https://company1.chat.yourdomain.com` in your
browser. The TLS certificate is issued automatically via Let's Encrypt (may take
up to 60 seconds on first request).

> ⚠️ **DNS must resolve** before Traefik can complete the ACME HTTP-01 challenge
> and issue the certificate. Make sure the DNS A record is live.

---

### 7. Create additional companies

Repeat step 6 for each company. Each one gets its own database, its own
isolated containers, and its own TLS certificate — all served from the same
server and reverse proxy.

```bash
scripts/create-company.sh company2 company2.chat.yourdomain.com
scripts/create-company.sh company3 company3.chat.yourdomain.com
```

---

## Manual company setup (without the script)

If you prefer to set up a company manually instead of using
`scripts/create-company.sh`:

**1. Create the Postgres database:**

```bash
docker exec chatwoot_postgres psql -U chatwoot \
  -c "CREATE DATABASE chatwoot_mycompany;"
```

**2. Create the company env file:**

```bash
cp chatwoot-template/example.env companies/mycompany.env
chmod 600 companies/mycompany.env
```

Edit `companies/mycompany.env` and set at minimum:

| Variable | Value |
|---|---|
| `COMPANY_NAME` | `mycompany` |
| `DOMAIN` | `mycompany.chat.yourdomain.com` |
| `POSTGRES_DATABASE` | `chatwoot_mycompany` |
| `POSTGRES_USERNAME` | Must match `infrastructure/postgres/.env` |
| `POSTGRES_PASSWORD` | Must match `infrastructure/postgres/.env` |
| `REDIS_URL` | `redis://:<redis-password>@chatwoot_redis:6379/0` |
| `SECRET_KEY_BASE` | `openssl rand -hex 64` |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | `openssl rand -hex 32` |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | `openssl rand -hex 32` |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | `openssl rand -hex 32` |
| `SMTP_*` | Your SMTP relay credentials |

**3. Provision the database schema:**

Run `rails db:chatwoot_prepare` as a one-off container **before** starting the
persistent containers. This prevents the `FATAL: database does not exist` log
flood that occurs when the app starts without a provisioned schema.

```bash
COMPANY=mycompany DOMAIN=mycompany.chat.yourdomain.com \
  docker compose \
    --project-name chatwoot_mycompany \
    -f chatwoot-template/docker-compose.yml \
    run --rm web bundle exec rails db:chatwoot_prepare
```

**4. Start the company stack:**

```bash
COMPANY=mycompany DOMAIN=mycompany.chat.yourdomain.com \
  docker compose \
    --project-name chatwoot_mycompany \
    -f chatwoot-template/docker-compose.yml \
    up -d
```

---

## Useful commands

### Infrastructure

```bash
# Status
docker compose -f infrastructure/traefik/docker-compose.yml ps
docker compose -f infrastructure/postgres/docker-compose.yml ps
docker compose -f infrastructure/redis/docker-compose.yml ps

# Logs
docker compose -f infrastructure/traefik/docker-compose.yml logs -f
docker compose -f infrastructure/postgres/docker-compose.yml logs -f

# Connect to Postgres
docker exec -it chatwoot_postgres psql -U chatwoot
```

### Company instances

```bash
# Status
COMPANY=company1 DOMAIN=company1.chat.yourdomain.com \
  docker compose --project-name chatwoot_company1 \
  -f chatwoot-template/docker-compose.yml ps

# Follow web logs
docker logs -f chatwoot_company1_web

# Rails console
docker exec -it chatwoot_company1_web bundle exec rails console

# Restart
COMPANY=company1 DOMAIN=company1.chat.yourdomain.com \
  docker compose --project-name chatwoot_company1 \
  -f chatwoot-template/docker-compose.yml restart
```

### Stop / remove a company

```bash
COMPANY=company1 DOMAIN=company1.chat.yourdomain.com \
  docker compose --project-name chatwoot_company1 \
  -f chatwoot-template/docker-compose.yml down

# Remove the env file too (optional)
rm companies/company1.env
```

---

## Backup

Back up all company databases to `backups/`:

```bash
scripts/backup-postgres.sh
```

Back up a single company:

```bash
scripts/backup-postgres.sh company1
# creates: backups/chatwoot_company1_<timestamp>.sql.gz
```

Restore a backup:

```bash
gunzip -c backups/chatwoot_company1_20260101_120000.sql.gz \
  | docker exec -i chatwoot_postgres psql -U chatwoot -d chatwoot_company1
```

---

## Upgrading

### Upgrade all company containers

```bash
for env_file in companies/*.env; do
  company=$(basename "$env_file" .env)
  domain=$(grep '^DOMAIN=' "$env_file" | cut -d= -f2)
  echo "Upgrading $company…"
  COMPANY="$company" DOMAIN="$domain" \
    docker compose --project-name "chatwoot_${company}" \
    -f chatwoot-template/docker-compose.yml \
    pull
  COMPANY="$company" DOMAIN="$domain" \
    docker compose --project-name "chatwoot_${company}" \
    -f chatwoot-template/docker-compose.yml \
    up -d
  # Run any pending migrations
  docker exec "chatwoot_${company}_web" bundle exec rails db:migrate
done
```

### Upgrade infrastructure

```bash
docker compose -f infrastructure/traefik/docker-compose.yml pull && \
  docker compose -f infrastructure/traefik/docker-compose.yml up -d

docker compose -f infrastructure/postgres/docker-compose.yml pull && \
  docker compose -f infrastructure/postgres/docker-compose.yml up -d

docker compose -f infrastructure/redis/docker-compose.yml pull && \
  docker compose -f infrastructure/redis/docker-compose.yml up -d
```

---

## Troubleshooting

### `contact email has forbidden domain "example.com"`

Your `infrastructure/traefik/.env` still has the placeholder ACME e-mail.

```bash
# Fix:
nano infrastructure/traefik/.env
# Set:  ACME_EMAIL=you@yourdomain.com

docker compose -f infrastructure/traefik/docker-compose.yml up -d --force-recreate
```

---

### `permissions 755 for /acme.json are too open`

The `acme.json` file must be readable only by root/Traefik.

```bash
chmod 600 infrastructure/traefik/acme.json
docker compose -f infrastructure/traefik/docker-compose.yml restart
```

---

### `FATAL: database "chatwoot_company1" does not exist`

The database was not provisioned before the containers started. Run:

```bash
COMPANY=company1 DOMAIN=company1.chat.yourdomain.com \
  docker compose --project-name chatwoot_company1 \
  -f chatwoot-template/docker-compose.yml \
  run --rm web bundle exec rails db:chatwoot_prepare
```

---

### `Role "company1" does not exist`

`POSTGRES_USERNAME` in `companies/company1.env` was set to the company name
instead of the shared Postgres superuser. Fix it:

```bash
# Check the correct username
grep POSTGRES_USERNAME infrastructure/postgres/.env

# Fix the company env
sed -i "s/^POSTGRES_USERNAME=.*/POSTGRES_USERNAME=chatwoot/" companies/company1.env

# Restart
COMPANY=company1 DOMAIN=company1.chat.yourdomain.com \
  docker compose --project-name chatwoot_company1 \
  -f chatwoot-template/docker-compose.yml \
  up -d
```

---

### TLS certificate not issued

1. Confirm DNS is propagated: `dig company1.chat.yourdomain.com`
2. Confirm port 80 is reachable from the internet.
3. Check Traefik logs for ACME errors:
   ```bash
   docker logs chatwoot_traefik 2>&1 | grep -i acme
   ```
4. If you see `acme.json` permission errors, run `chmod 600 infrastructure/traefik/acme.json`
   and restart Traefik.

---

## Security notes

- All `.env` files and `acme.json` are listed in `.gitignore` and must **never** be committed.
- Each company has unique `SECRET_KEY_BASE` and `ACTIVE_RECORD_ENCRYPTION_*` keys.
- PostgreSQL and Redis have **no published ports** — only reachable inside `chatwoot-net`.
- Traefik only routes containers that carry the `traefik.enable=true` label.
- Back up `infrastructure/*.env` and `companies/*.env` — losing them means losing access to your data.

