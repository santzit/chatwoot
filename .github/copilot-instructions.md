# Copilot Instructions

## Repository overview

This repository is a **Docker Compose production deployment** for a self-hosted [Chatwoot](https://www.chatwoot.com/) instance. It is **not** the Chatwoot application source code. The repo contains infrastructure configuration only: compose files, environment templates, Traefik config, and a CI workflow.

Chatwoot is served at `https://app.<DOMAIN>` behind a Traefik v3 reverse proxy with automatic Let's Encrypt TLS.

---

## Stack

| Container | Image | Purpose |
|---|---|---|
| `chatwoot_traefik` | `traefik:v3.6` | Reverse proxy, TLS termination (Let's Encrypt) |
| `chatwoot_postgres` | `pgvector/pgvector:pg16` | Relational database — **must be pgvector**, not plain postgres |
| `chatwoot_redis` | `redis:7-alpine` | Cache and Sidekiq job queues |
| `chatwoot_rails` | `chatwoot/chatwoot:v4.11.2-ce` | Rails web server |
| `chatwoot_sidekiq` | `chatwoot/chatwoot:v4.11.2-ce` | Sidekiq background worker |

---

## Key files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Main production compose file |
| `docker-compose.ci.yml` | CI-only overlay (publishes port 3000 to the runner host) |
| `traefik.yml` | Traefik v3 static configuration |
| `.env.example` | Infrastructure secrets template (copy to `.env`) |
| `chatwoot.env.example` | Chatwoot app secrets template (copy to `chatwoot.env`) |
| `.github/workflows/ci.yml` | GitHub Actions CI — starts the stack and validates it |

`.env` and `chatwoot.env` are gitignored — **never commit them**.

---

## Environment variable conventions

- **Infrastructure secrets** (Traefik domain, Postgres credentials, Redis password) live in `.env`.
- **Application secrets** (Rails keys, DB connection, Redis URL, SMTP) live in `chatwoot.env`.
- `FRONTEND_URL`, `NODE_ENV`, `RAILS_ENV`, and `INSTALLATION_ENV` are injected by `docker-compose.yml` — do not duplicate them in `chatwoot.env`.
- Chatwoot's Rails app reads `POSTGRES_DATABASE` (not `POSTGRES_DB`) for the database name.
- Chatwoot uses `POSTGRES_USERNAME` (not `POSTGRES_USER`) for the DB user.
- Redis URL format: `redis://:<REDIS_PASSWORD>@redis:6379/0` — use the Docker Compose service name `redis`, not the container name `chatwoot_redis`. Alpine musl rejects underscores in hostnames per RFC 952.

---

## Docker Compose conventions

- The `x-base` YAML anchor holds the shared `image`, `env_file`, `networks`, and `volumes` for `rails` and `sidekiq`.
- `entrypoint` must use **exec list form** `["sh", "-c"]`, not a bare string. String-form entrypoints break `$@` passing and `$RAILS_ENV` checks inside the official `rails.sh` entrypoint.
- `command` for the `redis` service must also use list form — string/block-scalar form passes the whole command through `/bin/sh -c`, bypassing the Redis entrypoint's user setup.
- Use Docker Compose service names (`postgres`, `redis`) as hostnames in env files — never container names with underscores.
- `REDIS_PASSWORD` must be declared in the `redis` service `environment` block so the healthcheck shell (`$$REDIS_PASSWORD`) can read it.

---

## Database migrations

- On first deploy, run: `docker compose run --rm rails bundle exec rails db:chatwoot_prepare`
- This is the only manual step needed — subsequent restarts run it automatically at startup.
- Both `rails` and `sidekiq` run `db:chatwoot_prepare` on start. Rails advisory locking prevents schema conflicts between the two concurrent runs.
- In CI, the `sidekiq` `db:chatwoot_prepare` call is overridden to avoid a `UniqueViolation` on `pg_stat_statements` that causes Rails to restart-loop.

---

## Traefik / TLS

- `ACME_EMAIL` must be a plain address — no display name, no angle brackets.
- The ACME email is injected via a CLI flag in `docker-compose.yml`; `traefik.yml` does **not** expand `${}` variables.
- Traefik only routes containers with the `traefik.enable=true` label.
- The `acme.json` file must exist with mode `600` before starting Traefik: `install -m 600 /dev/null acme.json`.

---

## CI workflow

- Workflow file: `.github/workflows/ci.yml`
- Uses `docker compose -f docker-compose.yml -f docker-compose.ci.yml up -d rails` (no Traefik, no sidekiq).
- `docker-compose.ci.yml` publishes port `3000` to the host and sets `FRONTEND_URL=http://localhost:3000`.
- Wait strategy: poll `http://localhost:3000/auth/sign_in` for HTTP 200, then poll `rails runner "Account.count"` for DB readiness.
- Tear-down always runs with `docker compose ... down -v` to remove volumes.

---

## Security notes

- `.env`, `chatwoot.env`, `evolution.env`, and `acme.json` are gitignored — **never commit secrets**.
- PostgreSQL and Redis have no published ports — accessible only inside `chatwoot-net`.
- Generate unique cryptographic secrets per deployment with `openssl rand -hex 64` (SECRET_KEY_BASE) and `openssl rand -hex 32` (all other keys).
- `ENABLE_ACCOUNT_SIGNUP=false` by default in self-hosted deployments — the `/auth/sign_up` endpoint is disabled.
