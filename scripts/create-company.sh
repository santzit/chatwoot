#!/usr/bin/env bash
# =============================================================================
# scripts/create-company.sh
#
# Creates a new Chatwoot company instance, or restarts it if it already exists:
#   1. Creates a dedicated Postgres database (chatwoot_<company>).
#   2. Creates a dedicated Postgres database for Evolution API (evolution_<company>).
#   3. Generates companies/<company>.env     (Chatwoot vars) from example.env.
#   4. Generates companies/<company>_evo.env (Evolution API vars) from example_evo.env.
#   5. Starts the web + worker + evolution containers using the shared compose template.
#
# If companies/<company>.env already exists the script skips steps 1–3 and
# simply restarts the running containers (docker compose down → up), preserving
# all existing secrets and data.
#
# Usage:
#   scripts/create-company.sh <company-name> <domain>
#
# Example:
#   scripts/create-company.sh acme acme.chat.yourdomain.com
#
# Requirements:
#   • Run from the repository root.
#   • infra/ must already be running (docker compose -f infra/docker-compose.yml up -d).
#   • openssl must be available (installed by default on Ubuntu).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; RESET=''
fi

info()    { echo -e "${CYAN}➥ $*${RESET}"; }
success() { echo -e "${GREEN}✔  $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠  $*${RESET}"; }
error()   { echo -e "${RED}✖  $*${RESET}" >&2; }
die()     { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <company-name> <domain>"
  echo ""
  echo "Example:"
  echo "  $0 acme acme.chat.yourdomain.com"
  exit 1
fi

COMPANY="$1"
DOMAIN="$2"

# Validate company name: lowercase letters, digits, hyphens only.
if ! [[ "$COMPANY" =~ ^[a-z0-9-]+$ ]]; then
  die "Company name must contain only lowercase letters, digits, and hyphens. Got: '${COMPANY}'"
fi

# Export so all docker compose sub-commands inherit them for compose-file
# variable interpolation (env_file path, container names, Traefik labels).
export COMPANY DOMAIN

DB="chatwoot_${COMPANY}"
EVOLUTION_DB="evolution_${COMPANY}"
ENV_FILE="companies/${COMPANY}.env"
EVO_ENV_FILE="companies/${COMPANY}_evo.env"

# ---------------------------------------------------------------------------
# Detect update vs. fresh create
# ---------------------------------------------------------------------------
UPDATE=false
if [[ -f "$ENV_FILE" ]]; then
  UPDATE=true
  warn "${ENV_FILE} already exists — updating containers (env and secrets will NOT change)."
fi

# ---------------------------------------------------------------------------
# Read shared credentials from infra/.env
# ---------------------------------------------------------------------------
POSTGRES_USERNAME=$(grep -E '^POSTGRES_USERNAME=' infra/.env 2>/dev/null \
                    | sed 's/^POSTGRES_USERNAME=//' || true)
POSTGRES_PASSWORD=$(grep -E '^POSTGRES_PASSWORD=' infra/.env 2>/dev/null \
                    | sed 's/^POSTGRES_PASSWORD=//' || true)
REDIS_PASSWORD=$(grep -E '^REDIS_PASSWORD=' infra/.env 2>/dev/null \
                  | sed 's/^REDIS_PASSWORD=//' || true)

[[ -n "$POSTGRES_USERNAME" ]] || die "infra/.env is missing POSTGRES_USERNAME. Copy infra/.env.example to infra/.env and fill in the values."
[[ -n "$POSTGRES_PASSWORD" ]] || die "infra/.env is missing POSTGRES_PASSWORD. Copy infra/.env.example to infra/.env and fill in the values."
[[ -n "$REDIS_PASSWORD" ]]    || die "infra/.env is missing REDIS_PASSWORD. Copy infra/.env.example to infra/.env and fill in the values."

echo ""
echo -e "${CYAN}Creating company: ${COMPANY}${RESET}"
echo "  Domain:       ${DOMAIN}"
echo "  Evo domain:   evo.${DOMAIN}"
echo "  Database:     ${DB}"
echo "  Evolution DB: ${EVOLUTION_DB}"
echo "  Env file:     ${ENV_FILE}"
echo "  Evo env file: ${EVO_ENV_FILE}"
echo ""

# ---------------------------------------------------------------------------
# 1. Create the Postgres databases (skipped on update — they already exist)
# ---------------------------------------------------------------------------
if [[ "$UPDATE" == false ]]; then
info "Creating database ${DB}…"
if docker exec chatwoot_postgres psql -U "$POSTGRES_USERNAME" -d postgres \
    -c "CREATE DATABASE \"${DB}\";" 2>/dev/null; then
  success "Database ${DB} created."
else
  warn "Database ${DB} may already exist — continuing."
fi

info "Creating Evolution API database ${EVOLUTION_DB}…"
if docker exec chatwoot_postgres psql -U "$POSTGRES_USERNAME" -d postgres \
    -c "CREATE DATABASE \"${EVOLUTION_DB}\";" 2>/dev/null; then
  success "Database ${EVOLUTION_DB} created."
else
  warn "Database ${EVOLUTION_DB} may already exist — continuing."
fi
fi

# ---------------------------------------------------------------------------
# 2. Generate the company env files from the templates (skipped on update)
# ---------------------------------------------------------------------------
if [[ "$UPDATE" == false ]]; then
info "Generating ${ENV_FILE}…"

SECRET_KEY=$(openssl rand -hex 64)
ENC_DET=$(openssl rand -hex 32)
ENC_SALT=$(openssl rand -hex 32)
ENC_PRIM=$(openssl rand -hex 32)
EVOLUTION_API_KEY=$(openssl rand -hex 32)

cp chatwoot-template/example.env "$ENV_FILE"

# Substitute identity + auto-generated secrets
sed -i "s|^COMPANY_NAME=.*|COMPANY_NAME=${COMPANY}|"       "$ENV_FILE"
sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|"                    "$ENV_FILE"
sed -i "s|^POSTGRES_DATABASE=.*|POSTGRES_DATABASE=${DB}|"  "$ENV_FILE"
sed -i "s|^POSTGRES_USERNAME=.*|POSTGRES_USERNAME=${POSTGRES_USERNAME}|" "$ENV_FILE"
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" "$ENV_FILE"
sed -i "s|^REDIS_URL=.*|REDIS_URL=redis://:${REDIS_PASSWORD}@chatwoot_redis:6379/0|" "$ENV_FILE"
sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=${SECRET_KEY}|" "$ENV_FILE"
sed -i "s|^ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=.*|ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=${ENC_DET}|" "$ENV_FILE"
sed -i "s|^ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=.*|ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=${ENC_SALT}|" "$ENV_FILE"
sed -i "s|^ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=.*|ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=${ENC_PRIM}|" "$ENV_FILE"

chmod 600 "$ENV_FILE"
success "Generated ${ENV_FILE}."

info "Generating ${EVO_ENV_FILE}…"

cp chatwoot-template/example_evo.env "$EVO_ENV_FILE"

# Substitute Evolution API settings
sed -i "s|^AUTHENTICATION_API_KEY=.*|AUTHENTICATION_API_KEY=${EVOLUTION_API_KEY}|" "$EVO_ENV_FILE"
sed -i "s|^DATABASE_CONNECTION_URI=.*|DATABASE_CONNECTION_URI=postgresql://${POSTGRES_USERNAME}:${POSTGRES_PASSWORD}@chatwoot_postgres:5432/${EVOLUTION_DB}|" "$EVO_ENV_FILE"
sed -i "s|^DATABASE_CONNECTION_CLIENT_NAME=.*|DATABASE_CONNECTION_CLIENT_NAME=${EVOLUTION_DB}|" "$EVO_ENV_FILE"
sed -i "s|^CACHE_REDIS_URI=.*|CACHE_REDIS_URI=redis://:${REDIS_PASSWORD}@chatwoot_redis:6379/1|" "$EVO_ENV_FILE"
sed -i "s|^CACHE_REDIS_PREFIX_KEY=.*|CACHE_REDIS_PREFIX_KEY=evolution_${COMPANY}|" "$EVO_ENV_FILE"

chmod 600 "$EVO_ENV_FILE"
success "Generated ${EVO_ENV_FILE}."

echo ""
echo -e "${YELLOW}⚠  Review ${ENV_FILE} and update SMTP settings before going live.${RESET}"
echo -e "${YELLOW}⚠  Evolution API is publicly reachable at https://evo.${DOMAIN}${RESET}"
echo -e "${YELLOW}⚠  Your Evolution API key is stored in ${EVO_ENV_FILE} (AUTHENTICATION_API_KEY).${RESET}"
echo ""
fi

# ---------------------------------------------------------------------------
# 3. Provision the database schema (skipped on update)
# ---------------------------------------------------------------------------
if [[ "$UPDATE" == false ]]; then
info "Provisioning database schema for ${COMPANY}…"
if docker compose \
    --project-name "chatwoot_${COMPANY}" \
    -f chatwoot-template/docker-compose.yml \
    run --rm web bundle exec rails db:chatwoot_prepare; then
  success "Database schema provisioned."
else
  error "Database provisioning failed for ${COMPANY}."
  error "Re-run without --rm to inspect output:"
  error "  COMPANY=${COMPANY} DOMAIN=${DOMAIN} docker compose \\"
  error "    --project-name chatwoot_${COMPANY} \\"
  error "    -f chatwoot-template/docker-compose.yml \\"
  error "    run web bundle exec rails db:chatwoot_prepare"
  exit 1
fi
fi

# ---------------------------------------------------------------------------
# 4. Start (or restart) the company stack
# ---------------------------------------------------------------------------
if [[ "$UPDATE" == true ]]; then
  info "Restarting ${COMPANY} stack (down → up)…"
  docker compose \
    --project-name "chatwoot_${COMPANY}" \
    -f chatwoot-template/docker-compose.yml \
    down
fi
info "Starting ${COMPANY} stack…"
docker compose \
  --project-name "chatwoot_${COMPANY}" \
  -f chatwoot-template/docker-compose.yml \
  up -d

if [[ "$UPDATE" == true ]]; then
  success "${COMPANY} containers restarted at https://${DOMAIN}"
else
  success "${COMPANY} is running at https://${DOMAIN}"
fi
echo ""
echo "Useful commands:"
echo "  Logs:    COMPANY=${COMPANY} DOMAIN=${DOMAIN} docker compose --project-name chatwoot_${COMPANY} -f chatwoot-template/docker-compose.yml logs -f web"
echo "  Console: docker exec -it chatwoot_${COMPANY}_web bundle exec rails console"
echo "  Stop:    COMPANY=${COMPANY} DOMAIN=${DOMAIN} docker compose --project-name chatwoot_${COMPANY} -f chatwoot-template/docker-compose.yml down"
echo ""
echo "Evolution API (publicly accessible via Traefik):"
echo "  URL:      https://evo.${DOMAIN}"
echo "  Container: chatwoot_${COMPANY}_evolution"
echo "  API key:   see AUTHENTICATION_API_KEY in ${EVO_ENV_FILE}"
echo "  Logs:      docker logs -f chatwoot_${COMPANY}_evolution"
echo ""
echo -e "${YELLOW}Note: TLS certificate issuance may take up to 60 seconds on first start.${RESET}"
