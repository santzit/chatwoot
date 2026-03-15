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

Shared infrastructure  (infra/)
    ├── PostgreSQL 16  (separate database per tenant)
    └── Redis 7
```

---

## Directory structure

```
/opt/chatwoot/
│
├── infra/
│   ├── docker-compose.yml        # Traefik + PostgreSQL + Redis
│   ├── .env.example              # Shared secrets template  →  copy to infra/.env
│   └── traefik/
│       ├── traefik.yml           # Traefik static configuration
│       └── acme.json             # Let's Encrypt store (create manually, chmod 600)
│
├── empresa1/
│   ├── docker-compose.yml        # Parameterized — identical across all tenants
│   └── .env.example              # Tenant config template  →  copy to empresa1/.env
│
├── empresa2/
│   ├── docker-compose.yml        # (identical to empresa1/)
│   └── .env.example
│
├── empresa3/
│   ├── docker-compose.yml        # (identical to empresa1/)
│   └── .env.example
│
└── deployment/
    └── setup_24.04.sh            # One-command bootstrap for Ubuntu 24.04 LTS
```

> **Key design principle:** every `empresaN/docker-compose.yml` is **identical**.
> All tenant-specific values (`TENANT_SLUG`, `DOMAIN`, `POSTGRES_DATABASE`,
> cryptographic secrets, etc.) live exclusively in `empresaN/.env`.
> Adding a new tenant is therefore just:
> ```bash
> cp -r empresa1 empresa4
> # Edit empresa4/.env
> docker compose --project-directory empresa4 up -d
> ```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker ≥ 24 + Docker Compose v2 | `docker compose version` |
| Domain / DNS | Point each `empresaN.chat.mysubdomain.com` A record to the server IP |
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
3. Prompts for Postgres, Redis, SMTP, ACME e-mail, and per-tenant domains
4. Writes `infra/.env` and `empresa*/.env` (auto-generates all crypto secrets)
5. Patches `infra/traefik/traefik.yml` with the real ACME e-mail
6. Creates `infra/traefik/acme.json` with mode `0600`
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

#### 2. Configure infra secrets

```bash
cp infra/.env.example infra/.env
```

Edit `infra/.env` and set `POSTGRES_USERNAME`, `POSTGRES_PASSWORD`, and `REDIS_PASSWORD`.

#### 3. Set the ACME e-mail

Edit `infra/traefik/traefik.yml` and replace `admin@example.com`.

#### 4. Create the Traefik certificate file

```bash
touch infra/traefik/acme.json
chmod 600 infra/traefik/acme.json
```

#### 5. Configure each tenant

```bash
cp empresa1/.env.example empresa1/.env
cp empresa2/.env.example empresa2/.env
cp empresa3/.env.example empresa3/.env
```

For **each** `.env`, update at minimum:

| Variable | Description |
|---|---|
| `TENANT_SLUG` | Unique slug — used for container + Traefik names |
| `DOMAIN` | Public hostname (must match your DNS record) |
| `FRONTEND_URL` | Same as `https://<DOMAIN>` |
| `POSTGRES_DATABASE` | Unique DB name, e.g. `chatwoot_empresa1` |
| `POSTGRES_PASSWORD` | Must match `infra/.env` |
| `REDIS_URL` | Paste the Redis password from `infra/.env` |
| `SECRET_KEY_BASE` | `openssl rand -hex 64` (unique per tenant) |
| `ACTIVE_RECORD_ENCRYPTION_*` | `openssl rand -hex 32` each (unique per tenant) |
| `SMTP_*` | Your SMTP relay credentials |

#### 6. Start infra

```bash
docker compose --project-directory infra up -d
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

# 2. Edit the new tenant's env file
#    Change: TENANT_SLUG, DOMAIN, FRONTEND_URL, POSTGRES_DATABASE,
#            SECRET_KEY_BASE, ACTIVE_RECORD_ENCRYPTION_* keys
nano empresa4/.env

# 3. Start the new tenant
docker compose --project-directory empresa4 up -d

# 4. Create and migrate the database
docker compose --project-directory empresa4 exec web bundle exec rails db:chatwoot_prepare
```

No changes to any other file are needed.

---

## Useful commands

```bash
# Status of all services
docker compose --project-directory infra ps
docker compose --project-directory empresa1 ps

# Follow logs
docker compose --project-directory empresa1 logs -f web
docker compose --project-directory empresa1 logs -f worker

# Rails console for a tenant
docker compose --project-directory empresa1 exec web bundle exec rails console

# Connect to the shared Postgres cluster
docker compose --project-directory infra exec postgres psql -U chatwoot -d chatwoot_empresa1

# Restart a single tenant without affecting others
docker compose --project-directory empresa1 restart
```

---

## Upgrading

```bash
# Upgrade infra
docker compose --project-directory infra pull
docker compose --project-directory infra up -d

# Upgrade each tenant and run migrations
for dir in empresa1 empresa2 empresa3; do
  docker compose --project-directory "$dir" pull
  docker compose --project-directory "$dir" up -d
  docker compose --project-directory "$dir" exec web bundle exec rails db:migrate
done
```

---

## Security notes

- **Never commit** `infra/.env` or `empresa*/.env` — they are listed in `.gitignore`.
- `infra/traefik/acme.json` is also git-ignored (it holds TLS private keys).
- Each tenant has a unique `SECRET_KEY_BASE` and `ACTIVE_RECORD_ENCRYPTION_*` set.
- Postgres and Redis containers have no published ports — they are only reachable inside `chatwoot-net`.
- Traefik only routes containers that carry the `traefik.enable=true` label.
