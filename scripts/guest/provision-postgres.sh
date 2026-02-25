#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
set -euo pipefail

# -----------------------------
# Shared library
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

# Set Postgres-specific log prefix
LOG_PREFIX="[postgres]"

: "${DATA_SRC:=}"
: "${DATA_MNT:=/data}"

: "${PG_MAJOR:=16}"
: "${PG_PORT:=5432}"
: "${PG_BIND:=127.0.0.1}"
: "${PG_DB:=app_pg}"
: "${PG_USER:=app_pg_user}"
: "${PG_POWER_USER:=app_pg_power}"
: "${SECRETS_FILE:=/etc/app-secrets.env}"

need_root

# Mount persistent disk if provided
setup_data_mount "${DATA_SRC}" "${DATA_MNT}"

log "Installing Postgres ${PG_MAJOR}"
apt-get update -y
apt-get install -y "postgresql-${PG_MAJOR}" "postgresql-client-${PG_MAJOR}" postgresql-contrib

CONF_DIR="/etc/postgresql/${PG_MAJOR}/main"
PG_CONF="${CONF_DIR}/postgresql.conf"
PG_HBA="${CONF_DIR}/pg_hba.conf"

# Persistent data dir if /data is real
PG_DATA_BASE="${DATA_MNT}/postgres"
PG_DATA_DIR="${PG_DATA_BASE}/${PG_MAJOR}/main"
PG_MARKER="${PG_DATA_BASE}/.initialized-${PG_MAJOR}"

mkdir -p "${PG_DATA_DIR}"
chown -R postgres:postgres "${PG_DATA_BASE}"
chmod 700 "${PG_DATA_DIR}"

# Move cluster to /data (only once)
if [[ ! -f "${PG_MARKER}" ]]; then
  systemctl stop postgresql || true

  # Drop the default cluster if it exists, then recreate on /data
  if pg_lsclusters | awk 'NR>1 {print $1,$2}' | grep -q "^${PG_MAJOR} main$"; then
    pg_dropcluster --stop "${PG_MAJOR}" main
  fi

  pg_createcluster --start --datadir "${PG_DATA_DIR}" "${PG_MAJOR}" main

  touch "${PG_MARKER}"
  chown postgres:postgres "${PG_MARKER}"
  chmod 600 "${PG_MARKER}"
fi

# Configure bind + port + scram
grep -qE '^[[:space:]]*listen_addresses[[:space:]]*=' "${PG_CONF}" \
  && sed -i.bak "s|^[[:space:]]*listen_addresses[[:space:]]*=.*|listen_addresses = '${PG_BIND}'|" "${PG_CONF}" \
  || echo "listen_addresses = '${PG_BIND}'" >> "${PG_CONF}"

grep -qE '^[[:space:]]*port[[:space:]]*=' "${PG_CONF}" \
  && sed -i.bak "s|^[[:space:]]*port[[:space:]]*=.*|port = ${PG_PORT}|" "${PG_CONF}" \
  || echo "port = ${PG_PORT}" >> "${PG_CONF}"

grep -qE '^[[:space:]]*password_encryption[[:space:]]*=' "${PG_CONF}" \
  && sed -i.bak "s|^[[:space:]]*password_encryption[[:space:]]*=.*|password_encryption = scram-sha-256|" "${PG_CONF}" \
  || echo "password_encryption = scram-sha-256" >> "${PG_CONF}"

grep -qE '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+scram-sha-256' "${PG_HBA}" \
  || echo "host all all 127.0.0.1/32 scram-sha-256" >> "${PG_HBA}"

systemctl enable postgresql
systemctl restart postgresql

# Secrets file (shared)
if [[ ! -f "${SECRETS_FILE}" ]]; then
  cat > "${SECRETS_FILE}" <<EOF
# Shared app secrets for VM bakeoff series
EOF
  chmod 600 "${SECRETS_FILE}"
fi

if ! grep -q '^PG_PASS=' "${SECRETS_FILE}"; then
  PG_PASS="$(rand_pw)"
  {
    echo "PG_DB=\"${PG_DB}\""
    echo "PG_USER=\"${PG_USER}\""
    echo "PG_PASS=\"${PG_PASS}\""
  } >> "${SECRETS_FILE}"
  chmod 600 "${SECRETS_FILE}"
fi

if ! grep -q '^PG_POWER_PASS=' "${SECRETS_FILE}"; then
  PG_POWER_PASS="$(rand_pw)"
  {
    echo "PG_POWER_USER=\"${PG_POWER_USER}\""
    echo "PG_POWER_PASS=\"${PG_POWER_PASS}\""
  } >> "${SECRETS_FILE}"
  chmod 600 "${SECRETS_FILE}"
fi

# shellcheck disable=SC1090
source "${SECRETS_FILE}"

PG_URI="postgresql://${PG_USER}:${PG_PASS}@127.0.0.1:${PG_PORT}/${PG_DB}"
if grep -q '^POSTGRES_URI=' "${SECRETS_FILE}"; then
  sed -i.bak "s|^POSTGRES_URI=.*|POSTGRES_URI=\"${PG_URI}\"|" "${SECRETS_FILE}"
else
  echo "POSTGRES_URI=\"${PG_URI}\"" >> "${SECRETS_FILE}"
fi
chmod 600 "${SECRETS_FILE}"

# -----------------------------------------
# Create/update role + database idempotently
# -----------------------------------------

# Role can be managed inside a DO block (transaction OK)
sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PG_USER}') THEN
    CREATE ROLE ${PG_USER} LOGIN PASSWORD '${PG_PASS}';
  ELSE
    ALTER ROLE ${PG_USER} LOGIN PASSWORD '${PG_PASS}';
  END IF;
END
\$\$;
EOF

# Power user: CREATEDB + CREATEROLE (not superuser)
log "Creating power user: ${PG_POWER_USER}"
sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PG_POWER_USER}') THEN
    CREATE ROLE ${PG_POWER_USER} LOGIN PASSWORD '${PG_POWER_PASS}' CREATEDB CREATEROLE;
  ELSE
    ALTER ROLE ${PG_POWER_USER} LOGIN PASSWORD '${PG_POWER_PASS}' CREATEDB CREATEROLE;
  END IF;
END
\$\$;
EOF

# Grant power user access to all existing databases
for db in $(sudo -u postgres psql -tAc "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres'"); do
  log "Granting ${PG_POWER_USER} full access to database: ${db}"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${db}" <<EOF
GRANT ALL PRIVILEGES ON DATABASE ${db} TO ${PG_POWER_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${PG_POWER_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${PG_POWER_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${PG_POWER_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${PG_POWER_USER};
EOF
done

# Database cannot be created in a DO block (CREATE DATABASE is not allowed in a transaction)
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" | grep -q 1; then
  log "Creating database: ${PG_DB} (owner: ${PG_USER})"
  sudo -u postgres createdb -O "${PG_USER}" "${PG_DB}"
else
  log "✅ Database already exists: ${PG_DB}"
fi

# Ensure ownership is correct (safe to rerun)
sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
ALTER DATABASE ${PG_DB} OWNER TO ${PG_USER};
EOF

log "✅ Postgres ready."
log "   App user: ${PG_USER} (owns ${PG_DB})"
log "   Power user: ${PG_POWER_USER} (CREATEDB, CREATEROLE, full access)"
log "   Secrets: ${SECRETS_FILE}"
