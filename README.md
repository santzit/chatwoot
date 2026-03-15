# Chatwoot — Multi-Tenant Self-Hosted Docker Compose

Self-hosted [Chatwoot](https://www.chatwoot.com/) setup that runs **multiple isolated instances** behind a single **Traefik** reverse proxy, sharing one PostgreSQL cluster and one Redis instance.

```
Internet
    │
    ▼
Traefik  (ports 80 / 443, automatic TLS via Let's Encrypt)
    │
    ├── empresa1.chat.mysubdomain.com  →  chatwoot_empresa1_web
    ├── empresa2.chat.mysubdomain.com  →  chatwoot_empresa2_web
    └── empresa3.chat.mysubdomain.com  →  chatwoot_empresa3_web

Shared infrastructure
    ├── PostgreSQL 16  (separate database per tenant)
    └── Redis 7
```

---

## Directory structure

```
.
├── docker-compose.yml          # Full stack definition
├── .env.example                # Shared secrets template  →  copy to .env
├── deployment/
│   └── setup_24.04.sh          # One-command bootstrap for Ubuntu 24.04 LTS
├── traefik/
│   ├── traefik.yml             # Traefik static configuration
│   └── acme.json               # Let's Encrypt store (create manually, chmod 600)
├── scripts/
│   └── init-db.sh              # Creates per-tenant databases on first Postgres boot
└── env/
    ├── empresa1.env.example    # Empresa 1 secrets template  →  copy to empresa1.env
    ├── empresa2.env.example    # Empresa 2 secrets template  →  copy to empresa2.env
    └── empresa3.env.example    # Empresa 3 secrets template  →  copy to empresa3.env
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker ≥ 24 + Docker Compose v2 | `docker compose version` |
| Domain / DNS | Point `*.chat.mysubdomain.com` (or individual A records) to the server IP |
| Ports 80 and 443 open | Required by Traefik and the ACME HTTP-01 challenge |

---

## Quick start

### Option A — Automated setup on Ubuntu 24.04 LTS (recommended)

The script installs Docker Engine, configures the firewall, prompts you for all required values, writes the env files, and optionally starts the stack in one go:

```bash
git clone https://github.com/santzit/chatwoot.git
cd chatwoot
sudo bash deployment/setup_24.04.sh
```

The script accepts the following flags:

| Flag | Description |
|---|---|
| `--skip-docker` | Skip Docker installation (Docker already present) |
| `--skip-firewall` | Skip ufw firewall configuration |
| `--version` | Print script version |
| `--help` | Show usage |

A full log is written to `/var/log/chatwoot-setup.log`.

---

### Option B — Manual setup

### 1. Clone and enter the repository

```bash
git clone https://github.com/santzit/chatwoot.git
cd chatwoot
```

### 2. Configure shared secrets

```bash
cp .env.example .env
```

Edit `.env` and set:

| Variable | Description |
|---|---|
| `POSTGRES_USERNAME` | PostgreSQL superuser name |
| `POSTGRES_PASSWORD` | Strong password — `openssl rand -hex 32` |
| `REDIS_PASSWORD` | Strong password — `openssl rand -hex 32` |

### 3. Configure each Chatwoot instance

```bash
cp env/empresa1.env.example env/empresa1.env
cp env/empresa2.env.example env/empresa2.env
cp env/empresa3.env.example env/empresa3.env
```

For **each** instance file, update at minimum:

| Variable | Description |
|---|---|
| `FRONTEND_URL` | Public HTTPS URL for this instance |
| `SECRET_KEY_BASE` | `openssl rand -hex 64` (unique per instance) |
| `POSTGRES_USERNAME` / `POSTGRES_PASSWORD` | Same values as in `.env` |
| `REDIS_URL` | Replace the password placeholder with the value from `.env` |
| `ACTIVE_RECORD_ENCRYPTION_*` | Run `openssl rand -hex 32` for each (unique per instance) |
| `SMTP_*` | Your SMTP relay credentials |

> **Important:** every instance **must** have a unique `SECRET_KEY_BASE`.  
> Sharing the same key across instances is a security risk.

### 4. Set the ACME e-mail address

Edit `traefik/traefik.yml` and replace `admin@example.com` with a real e-mail address. Let's Encrypt uses this for certificate expiry notifications.

### 5. Create the Traefik certificate file

The file must exist **before** starting the stack and must be owned by root with mode `0600`:

```bash
touch traefik/acme.json
chmod 600 traefik/acme.json
```

### 6. Start the stack

```bash
docker compose up -d
```

Check that all containers are healthy:

```bash
docker compose ps
```

### 7. Run database migrations for each instance

On the very first boot, run the Rails migrations for each instance:

```bash
docker compose exec chatwoot_empresa1_web bundle exec rails db:chatwoot_prepare
docker compose exec chatwoot_empresa2_web bundle exec rails db:chatwoot_prepare
docker compose exec chatwoot_empresa3_web bundle exec rails db:chatwoot_prepare
```

### 8. Create the first admin user (per instance)

```bash
# Empresa 1
docker compose exec chatwoot_empresa1_web \
  bundle exec rails runner "User.create!(name:'Admin', email:'admin@empresa1.com', password:'changeme', role: :administrator)"

# Repeat for empresa2 and empresa3 as needed.
```

---

## Adding a new tenant

1. Add a new env file: `cp env/empresa1.env.example env/empresa4.env` and fill it in (use `chatwoot_empresa4` as `POSTGRES_DATABASE`).
2. Add the new database to the shared Postgres cluster:
   ```bash
   docker exec chatwoot_postgres \
     psql -U "$POSTGRES_USER" -c "CREATE DATABASE chatwoot_empresa4;"
   ```
3. Add the new `web` and `worker` services to `docker-compose.yml` following the existing pattern.
4. `docker compose up -d` — only the new containers are created.

---

## Updating Chatwoot

```bash
docker compose pull
docker compose up -d

# Run migrations for every instance after upgrading.
docker compose exec chatwoot_empresa1_web bundle exec rails db:migrate
docker compose exec chatwoot_empresa2_web bundle exec rails db:migrate
docker compose exec chatwoot_empresa3_web bundle exec rails db:migrate
```

---

## Useful commands

```bash
# View logs for a specific instance
docker compose logs -f chatwoot_empresa1_web

# Open a Rails console for empresa2
docker compose exec chatwoot_empresa2_web bundle exec rails console

# Connect to the shared Postgres cluster
docker compose exec postgres psql -U chatwoot -d chatwoot_empresa1

# Restart a single instance without affecting others
docker compose restart chatwoot_empresa1_web chatwoot_empresa1_worker
```

---

## Security notes

- **Never commit** `.env` or `env/*.env` files — they are listed in `.gitignore`.
- The `traefik/acme.json` file contains TLS private keys; it is also git-ignored.
- Each Chatwoot instance has an isolated database and a separate `SECRET_KEY_BASE`, so a compromise of one instance does not expose another.
- Traefik only exposes containers that carry the `traefik.enable=true` label; the database and Redis containers are not reachable from the internet.