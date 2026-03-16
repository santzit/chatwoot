#!/usr/bin/env bash
# =============================================================================
# scripts/backup-postgres.sh
#
# Dumps Chatwoot Postgres databases to compressed SQL files in backups/.
#
# Usage:
#   scripts/backup-postgres.sh                 # backs up ALL chatwoot_* databases
#   scripts/backup-postgres.sh <company-name>  # backs up a single company
#
# Example:
#   scripts/backup-postgres.sh acme            # creates backups/chatwoot_acme_<timestamp>.sql.gz
#   scripts/backup-postgres.sh                 # creates one file per chatwoot_* database
#
# Requirements:
#   • Run from the repository root.
#   • chatwoot_postgres container must be running.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; RESET='\033[0m'
else
  GREEN=''; CYAN=''; RED=''; RESET=''
fi

info()    { echo -e "${CYAN}➥ $*${RESET}"; }
success() { echo -e "${GREEN}✔  $*${RESET}"; }
error()   { echo -e "${RED}✖  $*${RESET}" >&2; }
die()     { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${REPO_ROOT}/backups"
mkdir -p "$BACKUP_DIR"

POSTGRES_USERNAME=$(grep -E '^POSTGRES_USERNAME=' infrastructure/postgres/.env 2>/dev/null \
                    | sed 's/^POSTGRES_USERNAME=//' || true)
[[ -n "$POSTGRES_USERNAME" ]] || die "infrastructure/postgres/.env missing POSTGRES_USERNAME."

# ---------------------------------------------------------------------------
# Backup function
# ---------------------------------------------------------------------------
backup_db() {
  local db="$1"
  local out="${BACKUP_DIR}/${db}_${TIMESTAMP}.sql.gz"

  info "Backing up ${db} → ${out}…"
  docker exec chatwoot_postgres pg_dump -U "$POSTGRES_USERNAME" "$db" \
    | gzip > "$out"
  success "Backup complete: ${out}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ $# -ge 1 ]]; then
  # Single company backup
  COMPANY="$1"
  backup_db "chatwoot_${COMPANY}"
else
  # Backup all chatwoot_* databases
  mapfile -t DBS < <(
    docker exec chatwoot_postgres psql \
      -U "$POSTGRES_USERNAME" -d postgres -tAc \
      "SELECT datname FROM pg_database WHERE datname LIKE 'chatwoot_%' ORDER BY datname;"
  )

  if [[ ${#DBS[@]} -eq 0 ]]; then
    echo "No chatwoot_* databases found."
    exit 0
  fi

  for db in "${DBS[@]}"; do
    backup_db "$db"
  done
fi

echo ""
success "All backups stored in ${BACKUP_DIR}"
