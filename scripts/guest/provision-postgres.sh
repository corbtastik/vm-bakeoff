#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
set -euo pipefail

: "${DATA_SRC:=}"
: "${DATA_MNT:=/data}"

: "${PG_MAJOR:=16}"
: "${PG_PORT:=5432}"
: "${PG_BIND:=127.0.0.1}"
: "${PG_DB:=todo_pg}"
: "${PG_USER:=todo_pg_user}"
: "${SECRETS_FILE:=/etc/todo-secrets.env}"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ Please run as root (meant to be run via sudo)."
    exit 1
  fi
}
log(){ echo "🐘 $*"; }

rand_pw() {
  set +o pipefail
  local pw
  pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  set -o pipefail
  printf '%s' "$pw"
}

need_root

# Mount persistent disk if provided
if [[ -n "${DATA_SRC}" ]]; then
  if [[ ! -d "${DATA_SRC}" ]]; then
    echo "❌ Expected Lima disk mount not found: ${DATA_SRC}"
    exit 1
  fi
  mkdir -p "${DATA_MNT}"
  if ! mountpoint -q "${DATA_MNT}"; then
    mount --bind "${DATA_SRC}" "${DATA_MNT}"
  fi
  line="${DATA_SRC} ${DATA_MNT} none bind 0 0"
  grep -Fxq "${line}" /etc/fstab || echo "${line}" >> /etc/fstab
else
  mkdir -p "${DATA_MNT}"
fi

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

log "✅ Postgres ready. Secrets: ${SECRETS_FILE}"
