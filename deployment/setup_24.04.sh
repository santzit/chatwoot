#!/usr/bin/env bash
# =============================================================================
# deployment/setup_24.04.sh
#
# Description : Bootstrap a multi-tenant Chatwoot Docker Compose stack on a
#               fresh Ubuntu 24.04 LTS (Noble Numbat) server.
# OS          : Ubuntu 24.04 LTS
# Script Ver  : 1.0.0
# Run as      : root
#
# What this script does
# ---------------------
#  1. Validates that the OS is Ubuntu 24.04.
#  2. Installs Docker Engine (CE) + Compose plugin from the official Docker repo.
#  3. Installs ufw (if absent) and opens ports 22, 80 and 443.
#  4. Prompts for shared secrets and writes .env + per-tenant env files.
#  5. Creates traefik/acme.json with the required 0600 permissions.
#  6. Optionally starts the stack with `docker compose up -d` and runs
#     Rails DB migrations for each tenant.
#
# Usage
# -----
#   sudo bash deployment/setup_24.04.sh [--help] [--skip-docker] [--skip-firewall]
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/chatwoot-setup.log"
REQUIRED_OS_ID="ubuntu"
REQUIRED_OS_VERSION="24.04"
REQUIRED_OS_CODENAME="noble"
DOCKER_GPG_KEY="/etc/apt/keyrings/docker.gpg"
DOCKER_APT_LIST="/etc/apt/sources.list.d/docker.list"

# Parsed flags
OPT_SKIP_DOCKER=false
OPT_SKIP_FIREWALL=false
OPT_HELP=false

# ---------------------------------------------------------------------------
# Colour helpers (disabled when not a TTY)
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
# Logging
# ---------------------------------------------------------------------------
setup_logging() {
  touch "$LOG_FILE"
  # Tee every subsequent line to the log file as well.
  exec > >(tee -a "$LOG_FILE") 2>&1
}

# ---------------------------------------------------------------------------
# Exit handler
# ---------------------------------------------------------------------------
exit_handler() {
  local code=$?
  if [ $code -ne 0 ]; then
    error "Setup failed (exit $code). Full log: $LOG_FILE"
  fi
}
trap exit_handler EXIT

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: sudo bash deployment/setup_24.04.sh [OPTIONS]

Bootstrap the multi-tenant Chatwoot Docker Compose stack on Ubuntu 24.04 LTS.

Options:
  --skip-docker     Skip Docker Engine installation (Docker already installed)
  --skip-firewall   Skip ufw firewall configuration
  -v, --version     Print script version
  -h, --help        Show this help message

Exit status: 0 on success, non-zero on error.

Full log written to: $LOG_FILE
Report issues at: https://github.com/santzit/chatwoot/issues
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-docker)    OPT_SKIP_DOCKER=true;    shift ;;
      --skip-firewall)  OPT_SKIP_FIREWALL=true;  shift ;;
      -v|--version)     echo "setup_24.04.sh v$SCRIPT_VERSION"; exit 0 ;;
      -h|--help)        OPT_HELP=true;            shift ;;
      *) die "Unknown option: $1  (use --help for usage)" ;;
    esac
  done

  if $OPT_HELP; then usage; exit 0; fi
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root.  Try: sudo bash $0"
  fi
}

check_os() {
  info "Checking OS compatibility…"

  if ! command -v lsb_release &>/dev/null; then
    apt-get install -y -qq lsb-release &>/dev/null
  fi

  local os_id os_version os_codename
  os_id=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
  os_version=$(lsb_release -sr)
  os_codename=$(lsb_release -sc | tr '[:upper:]' '[:lower:]')

  if [[ "$os_id" != "$REQUIRED_OS_ID" ]]; then
    die "Unsupported OS: $os_id. This script requires Ubuntu 24.04 LTS."
  fi

  if [[ "$os_version" != "$REQUIRED_OS_VERSION" ]]; then
    die "Unsupported Ubuntu version: $os_version. This script requires Ubuntu $REQUIRED_OS_VERSION."
  fi

  if [[ "$os_codename" != "$REQUIRED_OS_CODENAME" ]]; then
    die "Unexpected codename '$os_codename'. Expected '$REQUIRED_OS_CODENAME'."
  fi

  success "OS check passed: Ubuntu $os_version ($os_codename)"
}

# ---------------------------------------------------------------------------
# Docker Engine installation
# Follows the official Docker documentation for Ubuntu 24.04:
# https://docs.docker.com/engine/install/ubuntu/
# ---------------------------------------------------------------------------
install_docker() {
  if $OPT_SKIP_DOCKER; then
    warn "Skipping Docker installation (--skip-docker)"
    return
  fi

  if command -v docker &>/dev/null; then
    local ver
    ver=$(docker --version 2>&1 | awk '{print $3}' | tr -d ',')
    warn "Docker is already installed ($ver). Skipping Docker installation."
    warn "To force re-install, remove Docker first and re-run without --skip-docker."
    return
  fi

  info "Installing Docker Engine…"

  # Remove conflicting legacy packages if present.
  local legacy_pkgs=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)
  for pkg in "${legacy_pkgs[@]}"; do
    apt-get remove -y "$pkg" &>/dev/null || true
  done

  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release

  # Add Docker's official GPG key.
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor --yes -o "$DOCKER_GPG_KEY"
  chmod a+r "$DOCKER_GPG_KEY"

  # Add Docker's APT repository (Noble / 24.04).
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_GPG_KEY}] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" \
    > "$DOCKER_APT_LIST"

  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker

  success "Docker Engine installed successfully."
  docker --version
  docker compose version
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
configure_firewall() {
  if $OPT_SKIP_FIREWALL; then
    warn "Skipping firewall configuration (--skip-firewall)"
    return
  fi

  info "Configuring ufw firewall…"

  if ! command -v ufw &>/dev/null; then
    apt-get install -y -qq ufw
  fi

  # Ensure SSH is always allowed before enabling ufw to prevent lock-outs.
  ufw allow OpenSSH
  ufw allow 80/tcp   comment 'HTTP  – Traefik'
  ufw allow 443/tcp  comment 'HTTPS – Traefik'

  ufw --force enable
  ufw status verbose

  success "Firewall configured."
}

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------

# Read a non-empty value from stdin; re-prompt on empty input.
# Usage: prompt_required VAR_NAME "Prompt text"
prompt_required() {
  local varname="$1"
  local prompt="$2"
  local value=""
  while [[ -z "$value" ]]; do
    read -rp "$prompt: " value
    if [[ -z "$value" ]]; then
      warn "This value cannot be empty. Please try again."
    fi
  done
  printf -v "$varname" '%s' "$value"
}

# Read a silent (password) value from stdin; re-prompt on empty input.
prompt_secret() {
  local varname="$1"
  local prompt="$2"
  local value=""
  while [[ -z "$value" ]]; do
    read -rsp "$prompt: " value
    echo
    if [[ -z "$value" ]]; then
      warn "This value cannot be empty. Please try again."
    fi
  done
  printf -v "$varname" '%s' "$value"
}

# Like prompt_secret but allows an empty answer (caller handles the empty case).
prompt_secret_optional() {
  local varname="$1"
  local prompt="$2"
  local value=""
  read -rsp "$prompt: " value
  echo
  printf -v "$varname" '%s' "$value"
}

# ---------------------------------------------------------------------------
# Generate random secrets
# ---------------------------------------------------------------------------
gen_hex()  { openssl rand -hex "$1"; }   # hex string of length 2*$1 chars
gen_pass() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32; }

# ---------------------------------------------------------------------------
# Write .env (shared infra)
# ---------------------------------------------------------------------------
write_shared_env() {
  local pg_user="$1" pg_pass="$2" redis_pass="$3"

  cat > .env <<EOF
# =============================================================================
# .env  –  Shared infrastructure secrets (auto-generated by setup_24.04.sh)
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

POSTGRES_USERNAME=${pg_user}
POSTGRES_PASSWORD=${pg_pass}
REDIS_PASSWORD=${redis_pass}
EOF
  chmod 600 .env
}

# ---------------------------------------------------------------------------
# Write per-tenant env file
# ---------------------------------------------------------------------------
write_tenant_env() {
  local slug="$1"       # empresa1, empresa2, …
  local domain="$2"     # empresa1.chat.mysubdomain.com
  local pg_user="$3"
  local pg_pass="$4"
  local redis_pass="$5"
  local smtp_host="$6"
  local smtp_user="$7"
  local smtp_pass="$8"
  local smtp_sender="$9"

  local secret_key; secret_key=$(gen_hex 64)
  local enc_det;    enc_det=$(gen_hex 32)
  local enc_salt;   enc_salt=$(gen_hex 32)
  local enc_prim;   enc_prim=$(gen_hex 32)

  local outfile="env/${slug}.env"

  cat > "$outfile" <<EOF
# =============================================================================
# env/${slug}.env  –  Chatwoot instance: ${slug}
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

RAILS_ENV=production
RAILS_LOG_TO_STDOUT=true

FRONTEND_URL=https://${domain}

# Cryptographic secrets (auto-generated – do NOT share)
SECRET_KEY_BASE=${secret_key}
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=${enc_det}
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=${enc_salt}
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=${enc_prim}

# Database – shared PostgreSQL cluster, dedicated database
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_DATABASE=chatwoot_${slug}
POSTGRES_USERNAME=${pg_user}
POSTGRES_PASSWORD=${pg_pass}

# Redis – shared instance
REDIS_URL=redis://:${redis_pass}@redis:6379/0

# SMTP
SMTP_ADDRESS=${smtp_host}
SMTP_PORT=587
SMTP_USERNAME=${smtp_user}
SMTP_PASSWORD=${smtp_pass}
SMTP_AUTHENTICATION=plain
SMTP_ENABLE_STARTTLS_AUTO=true
MAILER_SENDER_EMAIL=${smtp_sender}
EOF
  chmod 600 "$outfile"
}

# ---------------------------------------------------------------------------
# Interactive configuration
# ---------------------------------------------------------------------------
configure_environment() {
  cat <<EOF

${CYAN}=============================================================================
  Chatwoot Environment Configuration
=============================================================================${RESET}

You will be asked for:
  • A PostgreSQL username and password (shared across all instances)
  • A Redis password                   (shared across all instances)
  • Per-tenant domain names
  • SMTP credentials                   (can be the same for all tenants)

Secrets that require uniqueness (SECRET_KEY_BASE, encryption keys) are
generated automatically with openssl.

EOF

  # --- Shared credentials ------------------------------------------------
  local pg_user pg_pass redis_pass
  prompt_required         pg_user    "PostgreSQL username          (e.g. chatwoot)"
  prompt_secret_optional  pg_pass    "PostgreSQL password          (press Enter to auto-generate)"
  [[ -z "$pg_pass" ]] && pg_pass=$(gen_pass) && echo "  → Auto-generated PostgreSQL password."

  prompt_secret_optional  redis_pass "Redis password               (press Enter to auto-generate)"
  [[ -z "$redis_pass" ]] && redis_pass=$(gen_pass) && echo "  → Auto-generated Redis password."

  # --- Traefik ACME e-mail -----------------------------------------------
  local acme_email
  prompt_required acme_email "ACME / Let's Encrypt e-mail (for cert expiry notifications)"
  sed -i "s/admin@example.com/${acme_email}/" traefik/traefik.yml

  # --- SMTP (shared default; user can edit per-tenant files later) -------
  local smtp_host smtp_user smtp_pass smtp_sender
  prompt_required smtp_host   "SMTP host                    (e.g. smtp.sendgrid.net)"
  prompt_required smtp_user   "SMTP username"
  prompt_secret   smtp_pass   "SMTP password"
  prompt_required smtp_sender "Default sender email address (e.g. support@example.com)"

  # --- Per-tenant domains ------------------------------------------------
  local tenants=("empresa1" "empresa2" "empresa3")
  declare -A tenant_domains

  echo ""
  info "Enter the public domain for each Chatwoot instance."
  info "These must resolve to this server's IP address."
  echo ""

  for slug in "${tenants[@]}"; do
    local domain
    prompt_required domain "Domain for ${slug} (e.g. ${slug}.chat.example.com)"
    tenant_domains[$slug]="$domain"

    # Patch docker-compose.yml router rule with the real domain.
    sed -i "s|${slug}\.chat\.mysubdomain\.com|${domain}|g" docker-compose.yml
  done

  # --- Write files -------------------------------------------------------
  info "Writing .env and tenant env files…"

  write_shared_env "$pg_user" "$pg_pass" "$redis_pass"

  for slug in "${tenants[@]}"; do
    write_tenant_env \
      "$slug" \
      "${tenant_domains[$slug]}" \
      "$pg_user" "$pg_pass" "$redis_pass" \
      "$smtp_host" "$smtp_user" "$smtp_pass" "$smtp_sender"
    success "Written env/${slug}.env"
  done

  success "Environment files ready."
}

# ---------------------------------------------------------------------------
# acme.json
# ---------------------------------------------------------------------------
prepare_traefik() {
  info "Preparing Traefik certificate storage…"
  touch traefik/acme.json
  chmod 600 traefik/acme.json
  success "traefik/acme.json created with mode 0600."
}

# ---------------------------------------------------------------------------
# Start stack
# ---------------------------------------------------------------------------
start_stack() {
  local answer
  read -rp $'\nStart the Chatwoot stack now? (yes/no): ' answer
  if [[ "$answer" != "yes" ]]; then
    warn "Skipping stack startup. Run 'docker compose up -d' manually when ready."
    return
  fi

  info "Pulling Docker images (this may take a few minutes)…"
  docker compose pull

  info "Starting services…"
  docker compose up -d

  info "Waiting for services to become healthy…"
  local timeout=120  # seconds
  local elapsed=0
  local all_healthy=false

  while [ $elapsed -lt $timeout ]; do
    # Count containers whose Health status is defined but not yet "healthy".
    # docker inspect outputs one JSON object per container; awk parses it
    # line-by-line without any external language runtime dependency.
    local unhealthy
    unhealthy=$(docker compose ps -q 2>/dev/null \
      | xargs -r docker inspect --format '{{.State.Health.Status}}' 2>/dev/null \
      | awk '!/^$/ && !/^healthy$/ {c++} END {print c+0}')

    if [[ "$unhealthy" == "0" ]]; then
      all_healthy=true
      break
    fi

    sleep 5
    elapsed=$((elapsed + 5))
    echo -n "."
  done
  echo

  if ! $all_healthy; then
    warn "Not all services reported healthy after ${timeout}s."
    warn "Run 'docker compose ps' and 'docker compose logs' to investigate."
  else
    success "All services are healthy."
  fi
}

# ---------------------------------------------------------------------------
# Database migrations (first-run)
# ---------------------------------------------------------------------------
run_migrations() {
  local answer
  read -rp $'\nRun database migrations for all tenants now? (yes/no): ' answer
  if [[ "$answer" != "yes" ]]; then
    warn "Skipping migrations. Run them manually per the README."
    return
  fi

  local tenants=("empresa1" "empresa2" "empresa3")
  for slug in "${tenants[@]}"; do
    local svc="chatwoot_${slug}_web"
    info "Running migrations for ${slug} (${svc})…"
    if docker compose exec "$svc" bundle exec rails db:chatwoot_prepare; then
      success "Migrations complete for ${slug}."
    else
      error "Migration failed for ${slug}. Check logs: docker compose logs ${svc}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  local public_ip
  public_ip=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null || echo "<server-ip>")

  cat <<EOF

${GREEN}=============================================================================
  🎉  Chatwoot multi-tenant stack is ready!
=============================================================================${RESET}

  Server IP : ${public_ip}

  Instances :
$(grep -oE 'Host\(`[^`]+`\)' docker-compose.yml | sed 's/Host(`//;s/`)//' | sort -u | awk '{print "    • https://"$1}')

  Useful commands:
    docker compose ps                          # service status
    docker compose logs -f chatwoot_empresa1_web
    docker compose exec chatwoot_empresa1_web bundle exec rails console
    docker compose pull && docker compose up -d  # upgrade

  Secrets are stored in:
    .env                (shared Postgres + Redis credentials)
    env/empresa*.env    (per-tenant secrets)

  Full setup log: ${LOG_FILE}

${YELLOW}⚠  Back up .env and env/*.env – losing them means losing access to your data.${RESET}
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  setup_logging

  echo ""
  echo "  Chatwoot Multi-Tenant Setup  •  v${SCRIPT_VERSION}  •  Ubuntu 24.04 LTS"
  echo ""

  check_root
  check_os

  info "Step 1/6 – Installing Docker Engine"
  install_docker

  info "Step 2/6 – Configuring firewall"
  configure_firewall

  info "Step 3/6 – Configuring environment"
  configure_environment

  info "Step 4/6 – Preparing Traefik"
  prepare_traefik

  info "Step 5/6 – Starting the stack"
  start_stack

  info "Step 6/6 – Running database migrations"
  run_migrations

  print_summary
}

main "$@"
