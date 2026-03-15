#!/usr/bin/env bash
# =============================================================================
# scripts/init-db.sh
#
# Runs automatically on the FIRST startup of the PostgreSQL container
# (when the data volume is empty). Creates one database per Chatwoot tenant
# so that each instance has an isolated data store within the shared cluster.
#
# To add a new tenant later (without re-initialising):
#   docker exec chatwoot_postgres \
#     psql -U "$POSTGRES_USER" -c "CREATE DATABASE chatwoot_empresa4;"
# =============================================================================
set -e

psql -v ON_ERROR_STOP=1 \
     --username "$POSTGRES_USER" \
     --dbname   "postgres" \
<<-SQL
  -- The SELECT returns a CREATE DATABASE statement only when the database does
  -- not already exist.  \gexec then executes whatever the query returned,
  -- making the whole block safe to re-run (idempotent).
  SELECT 'CREATE DATABASE chatwoot_empresa1'
  WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'chatwoot_empresa1'
  )\gexec

  SELECT 'CREATE DATABASE chatwoot_empresa2'
  WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'chatwoot_empresa2'
  )\gexec

  SELECT 'CREATE DATABASE chatwoot_empresa3'
  WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'chatwoot_empresa3'
  )\gexec
SQL
