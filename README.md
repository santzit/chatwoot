# Chatwoot — Multi-Tenant Self-Hosted Docker Compose

Self-hosted [Chatwoot](https://www.chatwoot.com/) setup that runs **multiple isolated instances** behind a single **Traefik** reverse proxy, sharing one PostgreSQL cluster and one Redis instance.

```
Internet
    │
    ▼
Traefik  (ports 80 / 443, automatic TLS via Let's Encrypt)
    │
    ├── empresa1.chat.mysubdomain.com  →  empresa1/  (web + worker)
    ├── empresa2.chat.mysubdomain.com  →  empresa2/  (web + worker)
    └── empresa3.chat.mysubdomain.com  →  empresa3/  (web + worker)

Shared infrastructure  (root docker-compose.yml)
    ├── PostgreSQL 16  (separate database per tenant)
    └── Redis 7
```

---

## Directory structure

```
/opt/chatwoot/
│
├── docker-compose.yml        # Shared infra: Traefik + PostgreSQL + Redis
├── .env.example              # Shared secrets template  →  copy to .env
├── traefik/
│   ├── traefik.yml           # Traefik static configuration
│   └── acme.json             # Let's Encrypt certificate store (create manually, chmod 600)
│
├── empresa1/
│   ├── docker-compose.yml    # Parameterized — identical across all tenants
│   └── .env.example          # Tenant config template  →  copy to empresa1/.env
│
├── empresa2/                 # (same structure as empresa1/)
├── empresa3/                 # (same structure as empresa1/)
│
└── deployment/
    └── setup_24.04.sh        # One-command bootstrap for Ubuntu 24.04 LTS
```

> **Key design principle:** every `empresaN/docker-compose.yml` is **identical**.
> All tenant-specific values live exclusively in `empresaN/.env` via just two
> routing variables:
>
> | Variable | Example | Purpose |
> |---|---|---|
> | `TENANT_SLUG` | `empresa1` | Container names, Traefik router/service labels |
> | `BASE_DOMAIN` | `chat.mysubdomain.com` | Shared base domain; full URL is `${TENANT_SLUG}.${BASE_DOMAIN}` |
>
> `FRONTEND_URL` and the Traefik `Host()` rule are **derived automatically** —
> you never need to write a full domain URL per tenant.
> Adding a new tenant is therefore just:
> ```bash
> cp -r empresa1 empresa4
> # Edit empresa4/.env: TENANT_SLUG=empresa4, POSTGRES_DATABASE=chatwoot_empresa4,
> # and regenerate the crypto keys.  BASE_DOMAIN stays the same for all tenants.
> docker compose --project-directory empresa4 up -d
> ```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker ≥ 24 + Docker Compose v2 | `docker compose version` |
| Wildcard / per-tenant DNS | Point `*.chat.mysubdomain.com` (or individual A records) to the server IP |
| Ports 80 and 443 open | Required by Traefik and the ACME HTTP-01 challenge |

---

## Quick start

### Option A — Automated setup on Ubuntu 24.04 LTS (recommended)

```bash
git clone https://github.com/santzit/chatwoot.git /opt/chatwoot
cd /opt/chatwoot
sudo bash deployment/setup_24.04.sh
```

The script:
1. Installs Docker Engine CE (official Docker APT repo, Noble/24.04)
2. Configures `ufw` (ports 22/80/443)
3. Prompts for Postgres, Redis, SMTP, ACME e-mail, and a **single** base domain
4. Writes `.env` and `empresa*/.env` (auto-generates all crypto secrets)
5. Patches `traefik/traefik.yml` with the real ACME e-mail
6. Creates `traefik/acme.json` with mode `0600`
7. Optionally starts infra + tenants and runs DB migrations

| Flag | Description |
|---|---|
| `--skip-docker` | Skip Docker installation |
| `--skip-firewall` | Skip ufw configuration |
| `--version` | Print script version |
| `--help` | Show usage |

Full log: `/var/log/chatwoot-setup.log`

---

### Option B — Manual setup

#### 1. Clone the repository

```bash
git clone https://github.com/santzit/chatwoot.git /opt/chatwoot
cd /opt/chatwoot
```

#### 2. Configure shared infra secrets

```bash
cp .env.example .env
```

Edit `.env` and set `POSTGRES_USERNAME`, `POSTGRES_PASSWORD`, and `REDIS_PASSWORD`.

#### 3. Set the ACME e-mail

Edit `traefik/traefik.yml` and replace `CHANGE_ME@example.com`.

#### 4. Create the Traefik certificate file

```bash
touch traefik/acme.json
chmod 600 traefik/acme.json
```

#### 5. Configure each tenant

```bash
cp empresa1/.env.example empresa1/.env
cp empresa2/.env.example empresa2/.env
cp empresa3/.env.example empresa3/.env
```

For **each** `.env`, set at minimum:

| Variable | Description |
|---|---|
| `TENANT_SLUG` | Unique slug — used for container + Traefik names (e.g. `empresa1`) |
| `BASE_DOMAIN` | Shared base domain (e.g. `chat.mysubdomain.com`) |
| `POSTGRES_DATABASE` | Unique DB name, e.g. `chatwoot_empresa1` |
| `POSTGRES_PASSWORD` | Must match `.env` |
| `REDIS_URL` | Paste the Redis password from `.env` |
| `SECRET_KEY_BASE` | `openssl rand -hex 64` (unique per tenant) |
| `ACTIVE_RECORD_ENCRYPTION_*` | `openssl rand -hex 32` each (unique per tenant) |
| `SMTP_*` | Your SMTP relay credentials |

> `FRONTEND_URL` is automatically set to `https://${TENANT_SLUG}.${BASE_DOMAIN}`
> by `docker-compose.yml` — you do not need to add it to `.env`.

#### 6. Start shared infra

```bash
docker compose up -d
```

#### 7. Start tenants

```bash
docker compose --project-directory empresa1 up -d
docker compose --project-directory empresa2 up -d
docker compose --project-directory empresa3 up -d
```

#### 8. Run database migrations (first boot only)

```bash
docker compose --project-directory empresa1 exec web bundle exec rails db:chatwoot_prepare
docker compose --project-directory empresa2 exec web bundle exec rails db:chatwoot_prepare
docker compose --project-directory empresa3 exec web bundle exec rails db:chatwoot_prepare
```

---

## Adding a new tenant

```bash
# 1. Copy an existing tenant directory
cp -r empresa1 empresa4

# 2. Edit the new tenant's env file — only these values need to change:
#    TENANT_SLUG=empresa4
#    POSTGRES_DATABASE=chatwoot_empresa4
#    SECRET_KEY_BASE=$(openssl rand -hex 64)
#    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$(openssl rand -hex 32)
#    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$(openssl rand -hex 32)
#    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$(openssl rand -hex 32)
#    BASE_DOMAIN, Postgres/Redis credentials, and SMTP stay the same.
nano empresa4/.env

# 3. Start the new tenant
docker compose --project-directory empresa4 up -d

# 4. Create and migrate the database
docker compose --project-directory empresa4 exec web bundle exec rails db:chatwoot_prepare
```

No changes to any other file are needed.  Traefik will automatically route
`empresa4.chat.mysubdomain.com` to the new container via the dynamic label.

---

## Useful commands

```bash
# Status of all services
docker compose ps                          # shared infra
docker compose --project-directory empresa1 ps

# Follow logs
docker compose --project-directory empresa1 logs -f web
docker compose --project-directory empresa1 logs -f worker

# Rails console for a tenant
docker compose --project-directory empresa1 exec web bundle exec rails console

# Connect to the shared Postgres cluster
docker compose exec postgres psql -U chatwoot -d chatwoot_empresa1

# Restart a single tenant without affecting others
docker compose --project-directory empresa1 restart
```

---

## Upgrading

```bash
# Upgrade shared infra
docker compose pull
docker compose up -d

# Upgrade each tenant and run migrations
for dir in empresa1 empresa2 empresa3; do
  docker compose --project-directory "$dir" pull
  docker compose --project-directory "$dir" up -d
  docker compose --project-directory "$dir" exec web bundle exec rails db:migrate
done
```

---

## Security notes

- **Never commit** `.env` or `empresa*/.env` — they are listed in `.gitignore`.
- `traefik/acme.json` is also git-ignored (it holds TLS private keys).
- Each tenant has a unique `SECRET_KEY_BASE` and `ACTIVE_RECORD_ENCRYPTION_*` set.
- Postgres and Redis containers have no published ports — only reachable inside `chatwoot-net`.
- Traefik only routes containers that carry the `traefik.enable=true` label.
