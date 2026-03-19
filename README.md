# Chatwoot — Multi-Tenant Self-Hosted Docker Compose

Self-hosted [Chatwoot](https://www.chatwoot.com/) platform that runs **multiple isolated company instances** behind a single **Traefik** reverse proxy, sharing one PostgreSQL cluster and one Redis instance. Each company instance includes an **Evolution API** container that bridges WhatsApp (via Baileys) with Chatwoot over the internal Docker network.

```
Internet
    │
    ▼
Traefik  (ports 80 / 443, automatic TLS via Let's Encrypt)
    │
    ├── company1.chat.yourdomain.com  →  chatwoot_company1_web
    └── company2.chat.yourdomain.com  →  chatwoot_company2_web

Internal Docker network (chatwoot-net)  ←→  WhatsApp servers (outbound)
    ├── chatwoot_company1_evolution  (internal only — not exposed to internet)
    └── chatwoot_company2_evolution  (internal only — not exposed to internet)

Shared infrastructure  (infra/)
    ├── PostgreSQL 16  (chatwoot_<company> + evolution_<company> databases)
    └── Redis 7        (DB 0 for Chatwoot, DB 1 for Evolution API)
```

---

## Directory structure

```
chatwoot-platform/
│
├── infra/
│   ├── docker-compose.yml   # Traefik + PostgreSQL + Redis (all-in-one)
│   ├── traefik.yml          # Traefik static config
│   ├── .env.example         # → copy to .env, fill in all four values
│   └── acme.json            # Let's Encrypt cert store (create manually, chmod 600)
│
├── chatwoot-template/
│   ├── docker-compose.yml   # Shared template — same for every company
│   │                        # (web + worker + evolution services)
│   └── example.env          # Company env template
│
├── companies/               # Per-company .env files (all gitignored)
│   └── .gitkeep
│
├── scripts/
│   ├── create-company.sh    # Provision DBs + env + start containers (incl. Evolution API)
│   └── backup-postgres.sh   # Dump company databases to backups/
│
└── backups/                 # Backup output directory
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

### 2. Configure the infrastructure

Copy the example env and fill in all four values:

```bash
cp infra/.env.example infra/.env
```

Edit `infra/.env`:

```env
ACME_EMAIL=you@yourdomain.com             # ← your real e-mail (for Let's Encrypt)
POSTGRES_USERNAME=chatwoot
POSTGRES_PASSWORD=<strong-password>       # generate: openssl rand -hex 32
REDIS_PASSWORD=<strong-password>          # generate: openssl rand -hex 32
```

> ⚠️ **Do not use an `@example.com` address for `ACME_EMAIL`.** Let's Encrypt will reject the
> account registration with `contact email has forbidden domain "example.com"`.

Create the certificate storage file with strict permissions (required by Traefik):

```bash
install -m 600 /dev/null infra/acme.json
```

---

### 3. Start the infrastructure

```bash
docker compose -f infra/docker-compose.yml up -d
```

This starts Traefik, PostgreSQL, and Redis in one step. Verify everything is healthy:

```bash
docker compose -f infra/docker-compose.yml ps
```

Expected: all three containers show `Up` or `Up (healthy)`.

---

### 4. Create your first company

Use the provided script — it handles database creation, secret generation, and
container startup automatically:

```bash
scripts/create-company.sh company1 company1.chat.yourdomain.com
```

What the script does:
1. Creates the database `chatwoot_company1` in PostgreSQL.
2. Creates the database `evolution_company1` in PostgreSQL (for Evolution API).
3. Copies `chatwoot-template/example.env` to `companies/company1.env` and
   substitutes all values (credentials from `infra/.env`, freshly generated
   crypto secrets, and Evolution API key).
4. Runs `rails db:chatwoot_prepare` (schema migration) as a one-off container
   **before** starting persistent processes — prevents the
   `FATAL: database does not exist` flood that occurs when the app starts
   before its schema is provisioned.
5. Starts `chatwoot_company1_web`, `chatwoot_company1_worker`, and
   `chatwoot_company1_evolution`.

After the script completes, open `https://company1.chat.yourdomain.com` in your
browser. The TLS certificate is issued automatically via Let's Encrypt (may take
up to 60 seconds on first request).

> ⚠️ **DNS must resolve** before Traefik can complete the ACME HTTP-01 challenge
> and issue the certificate. Make sure the DNS A record is live.

---

### 5. Create additional companies

Repeat step 4 for each company. Each one gets its own databases, its own
isolated containers (Chatwoot + Evolution API), and its own TLS certificate —
all served from the same server and reverse proxy.

```bash
scripts/create-company.sh company2 company2.chat.yourdomain.com
scripts/create-company.sh company3 company3.chat.yourdomain.com
```

---

## Manual company setup (without the script)

If you prefer to set up a company manually instead of using
`scripts/create-company.sh`:

**1. Create the Postgres databases:**

```bash
docker exec chatwoot_postgres psql -U chatwoot \
  -c "CREATE DATABASE chatwoot_mycompany;"

docker exec chatwoot_postgres psql -U chatwoot \
  -c "CREATE DATABASE evolution_mycompany;"
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
| `POSTGRES_USERNAME` | Must match `POSTGRES_USERNAME` in `infra/.env` |
| `POSTGRES_PASSWORD` | Must match `POSTGRES_PASSWORD` in `infra/.env` |
| `REDIS_URL` | `redis://:<redis-password>@chatwoot_redis:6379/0` |
| `SECRET_KEY_BASE` | `openssl rand -hex 64` |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | `openssl rand -hex 32` |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | `openssl rand -hex 32` |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | `openssl rand -hex 32` |
| `SMTP_*` | Your SMTP relay credentials |
| `AUTHENTICATION_API_KEY` | `openssl rand -hex 32` |
| `DATABASE_CONNECTION_URI` | `postgresql://chatwoot:<pg-pass>@chatwoot_postgres:5432/evolution_mycompany` |
| `CACHE_REDIS_URI` | `redis://:<redis-password>@chatwoot_redis:6379/1` |

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
docker compose -f infra/docker-compose.yml ps

# Logs
docker compose -f infra/docker-compose.yml logs -f
docker compose -f infra/docker-compose.yml logs -f traefik
docker compose -f infra/docker-compose.yml logs -f postgres

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

# Follow Evolution API logs
docker logs -f chatwoot_company1_evolution

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
  echo "Upgrading $company..."
  COMPANY="$company" DOMAIN="$domain" \
    docker compose --project-name "chatwoot_${company}" \
    -f chatwoot-template/docker-compose.yml \
    pull
  COMPANY="$company" DOMAIN="$domain" \
    docker compose --project-name "chatwoot_${company}" \
    -f chatwoot-template/docker-compose.yml \
    up -d
  docker exec "chatwoot_${company}_web" bundle exec rails db:migrate
done
```

### Upgrade infrastructure

```bash
docker compose -f infra/docker-compose.yml pull
docker compose -f infra/docker-compose.yml up -d
```

---

## Evolution API — WhatsApp Integration

Each company stack includes a dedicated [Evolution API v2](https://doc.evolution-api.com/v2/en/integrations/chatwoot)
container (`chatwoot_<company>_evolution`) that acts as a bridge between
WhatsApp and Chatwoot.

### Connectivity model

```
WhatsApp servers  ←──── outbound WebSocket (Baileys) ────→  Evolution API
                                                               │  chatwoot-net
Chatwoot (web)   ←──── internal HTTP (port 8080) ────────────┘
```

- **Evolution API is NOT exposed to the internet.** There are no Traefik labels,
  no published ports, and no public DNS record needed for it.
- **Outbound access to WhatsApp** works via the Docker default NAT gateway —
  no extra firewall rules or configuration required.
- **Chatwoot ↔ Evolution API** communication travels entirely over the shared
  `chatwoot-net` Docker bridge using the internal container hostname
  `chatwoot_<company>_evolution:8080`.

### Connecting a WhatsApp number

Evolution API instances (one per WhatsApp number) are managed through its REST
API. You can call it from the Chatwoot Rails console, a one-off `curl` from the
host, or any HTTP client that can reach the Docker network:

```bash
# From the host — enter the evolution container's shell
docker exec -it chatwoot_company1_evolution sh

# Or call the API from the Chatwoot web container (same network)
EVOLUTION_API_KEY=$(grep '^AUTHENTICATION_API_KEY=' companies/company1.env | cut -d= -f2)
docker exec chatwoot_company1_web \
  curl -s -X GET http://chatwoot_company1_evolution:8080/ \
  -H "apikey: ${EVOLUTION_API_KEY}"
```

### Connecting Evolution API to Chatwoot

After creating a WhatsApp instance and scanning the QR code, link it to
Chatwoot. The `url` must be the **internal** Chatwoot address so the call
stays on the Docker network:

```bash
# Retrieve the Evolution API key from the company env file
EVOLUTION_API_KEY=$(grep '^AUTHENTICATION_API_KEY=' companies/company1.env | cut -d= -f2)

docker exec chatwoot_company1_web \
  curl -s -X POST \
  "http://chatwoot_company1_evolution:8080/chatwoot/set/support" \
  -H "apikey: ${EVOLUTION_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "enabled": true,
    "accountId": "1",
    "token": "<chatwoot-agent-token>",
    "url": "http://chatwoot_company1_web:3000",
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

> 💡 Obtain the Chatwoot `accountId` and `token` from **Settings → Integrations
> → API** inside the Chatwoot UI.

### Evolution API environment variables

The following variables in `companies/<company>.env` control Evolution API
behaviour. They are filled in automatically by `scripts/create-company.sh`:

| Variable | Purpose |
|---|---|
| `AUTHENTICATION_API_KEY` | Master API key (keep this secret) |
| `DATABASE_CONNECTION_URI` | PostgreSQL URI (`evolution_<company>` database) |
| `CACHE_REDIS_URI` | Redis URI (DB index 1, separate from Chatwoot's index 0) |
| `CACHE_REDIS_PREFIX_KEY` | Per-company key prefix (`evolution_<company>`) |
| `DEL_INSTANCE` | `false` — keep instances after container restart |

---

## Troubleshooting

### `unable to parse email address` (ACME / Let's Encrypt)

`ACME_EMAIL` in `infra/.env` is empty or uses a display-name format that the
ACME protocol does not accept.

```bash
nano infra/.env
# MUST be a plain address — no display name, no angle brackets:
#   ✔  ACME_EMAIL=you@yourdomain.com
#   ✖  ACME_EMAIL=Your Name <you@yourdomain.com>
#   ✖  ACME_EMAIL=          (empty)

docker compose -f infra/docker-compose.yml up -d --force-recreate traefik
```

---

### Chatwoot is not sending e-mails (invitations, login links, notifications)

SMTP is not configured. Open the company's env file and fill in the SMTP block:

```bash
nano companies/<company>.env
# Fill in every SMTP_* variable and MAILER_SENDER_EMAIL.
# Example using Gmail App Password:
#   SMTP_ADDRESS=smtp.gmail.com
#   SMTP_PORT=587
#   SMTP_DOMAIN=yourdomain.com
#   SMTP_USERNAME=you@gmail.com
#   SMTP_PASSWORD=<16-char app password>
#   SMTP_AUTHENTICATION=plain
#   SMTP_ENABLE_STARTTLS_AUTO=true
#   MAILER_SENDER_EMAIL=support@yourdomain.com

# Restart the company stack to pick up the new settings:
COMPANY=<company> DOMAIN=<domain> \
  docker compose --project-name chatwoot_<company> \
  -f chatwoot-template/docker-compose.yml \
  up -d
```

> 💡 Free SMTP relays: [Resend](https://resend.com), [SendGrid](https://sendgrid.com),
> [Mailgun](https://mailgun.com). All provide generous free tiers.

---

### Redis `WARNING Memory overcommit must be enabled!`

This is a Redis advisory about the host kernel parameter `vm.overcommit_memory`.
It is silenced automatically by the `--ignore-warnings OVERCOMMIT_MEMORY` flag
added to the Redis command in `infra/docker-compose.yml`.

If you see it on an older deployment, either recreate the Redis container:

```bash
docker compose -f infra/docker-compose.yml up -d --force-recreate redis
```

Or permanently fix it on the **host** (recommended for production):

```bash
echo 'vm.overcommit_memory = 1' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

### `contact email has forbidden domain "example.com"`

`ACME_EMAIL` in `infra/.env` is still set to the example.com placeholder.

```bash
nano infra/.env
# Set:  ACME_EMAIL=you@yourdomain.com

docker compose -f infra/docker-compose.yml up -d --force-recreate traefik
```

---

### `permissions 755 for /acme.json are too open`

The `acme.json` file must be readable only by root/Traefik.

```bash
chmod 600 infra/acme.json
docker compose -f infra/docker-compose.yml restart traefik
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
grep POSTGRES_USERNAME infra/.env

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
3. Check Traefik logs:
   ```bash
   docker compose -f infra/docker-compose.yml logs traefik 2>&1 | grep -i acme
   ```
4. If you see `acme.json` permission errors, run `chmod 600 infra/acme.json`
   and restart Traefik.

---

## Security notes

- `infra/.env` and `infra/acme.json` are listed in `.gitignore` and must **never** be committed.
- `companies/*.env` files are also gitignored — they contain per-company secrets.
- Each company has unique `SECRET_KEY_BASE` and `ACTIVE_RECORD_ENCRYPTION_*` keys.
- PostgreSQL and Redis have **no published ports** — only reachable inside `chatwoot-net`.
- Traefik only routes containers that carry the `traefik.enable=true` label.
- Back up `infra/.env` and `companies/*.env` — losing them means losing access to your data.
