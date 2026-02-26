#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
set -euo pipefail

# -----------------------------
# Shared library
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

LOG_PREFIX="[postgres]"

# -----------------------------
# Defaults (override-able)
# -----------------------------
: "${DATA_SRC:=}"                    # If set: /mnt/lima-<diskname>
: "${DATA_MNT:=/data}"               # Canonical mountpoint

: "${PG_MAJOR:=16}"
: "${PG_PORT:=5432}"
: "${PG_BIND:=127.0.0.1}"
: "${PG_DB:=app_pg}"
: "${PG_USER:=app_pg_user}"
: "${PG_POWER_USER:=app_pg_power}"
: "${SECRETS_FILE:=/etc/app-secrets.env}"

# -----------------------------
# 0) Must be root
# -----------------------------
need_root

# -----------------------------
# 1) Setup persistent data mount
# -----------------------------
setup_data_mount "${DATA_SRC}" "${DATA_MNT}"

# -----------------------------
# 2) Install PostgreSQL
# -----------------------------
log "Installing Postgres ${PG_MAJOR}"
ensure_pkg "postgresql-${PG_MAJOR}"
ensure_pkg "postgresql-client-${PG_MAJOR}"
ensure_pkg postgresql-contrib

# -----------------------------
# 3) Configure data directory
# -----------------------------
CONF_DIR="/etc/postgresql/${PG_MAJOR}/main"
PG_CONF="${CONF_DIR}/postgresql.conf"
PG_HBA="${CONF_DIR}/pg_hba.conf"

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

# -----------------------------
# 4) Configure bind + port + auth
# -----------------------------
log "Configuring postgresql.conf (listen_addresses/port/password_encryption)"
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

# -----------------------------
# 5) Secrets (source of truth)
# -----------------------------
log "Preparing secrets file ${SECRETS_FILE}"
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

# -----------------------------
# 6) Create/update roles + database
# -----------------------------
log "Creating/updating app user: ${PG_USER}"
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

# -----------------------------
# 7) Final summary
# -----------------------------
log "Done! Postgres ${PG_MAJOR} is ready."
echo "App user: ${PG_USER} (owns ${PG_DB})"
echo "Power user: ${PG_POWER_USER} (CREATEDB, CREATEROLE, full access)"
echo "Secrets: ${SECRETS_FILE}"
echo "Tip: source ${SECRETS_FILE} && echo \$POSTGRES_URI"
