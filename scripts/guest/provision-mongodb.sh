#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
set -euo pipefail

# -----------------------------
# Defaults (override-able)
# -----------------------------
: "${DATA_SRC:=}"                                 # If set: /mnt/lima-<diskname>
: "${DATA_MNT:=/data}"                            # Canonical mountpoint
: "${MONGO_DBPATH:=/data/mongodb}"
: "${MONGO_LOGPATH:=/data/mongodb-log/mongod.log}"

: "${MONGO_MAJOR:=8.0}"
: "${DB_NAME:=todo}"
: "${DB_ADMIN_USER:=dbAdmin}"
: "${DB_USER:=dbUser}"
: "${SECRETS_FILE:=/etc/todo-secrets.env}"

# -----------------------------
# Helpers
# -----------------------------
need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ Please run as root (this script is meant to be run via sudo)."
    exit 1
  fi
}

log() { echo "🧩 $*"; }

rand_pw() {
  # `head` closes the pipe early; with `pipefail` that can surface as SIGPIPE (141).
  # Temporarily disable pipefail for this pipeline.
  set +o pipefail
  local pw
  pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  set -o pipefail
  printf '%s' "$pw"
}

ensure_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    log "Installing package: ${pkg}"
    apt-get update -y
    apt-get install -y "$pkg"
  fi
}

wait_for_mongo() {
  log "Waiting for mongod to accept connections on 127.0.0.1:27017..."
  for _ in {1..60}; do
    if mongosh --quiet --eval "db.runCommand({ ping: 1 }).ok" 2>/dev/null | grep -q '^1$'; then
      log "✅ mongod is ready"
      return 0
    fi
    sleep 1
  done
  echo "❌ mongod did not become ready in time."
  systemctl status mongod --no-pager || true
  journalctl -u mongod -n 200 --no-pager || true
  exit 1
}

# Deterministic auth toggling:
# - Removes any existing `security:` blocks (avoids YAML duplicates)
# - Appends a single canonical `security.authorization: <mode>` at end
set_auth() {
  local mode="${1:?enabled|disabled}"

  if grep -q '^security:' "${CONF}"; then
    awk '
      BEGIN{insec=0}
      /^security:/ {insec=1; next}
      insec && /^[^[:space:]]/ {insec=0}
      !insec {print}
    ' "${CONF}" > "${CONF}.tmp" && mv "${CONF}.tmp" "${CONF}"
  fi

  cat >> "${CONF}" <<EOF

security:
  authorization: ${mode}
EOF
}

# -----------------------------
# 0) Must be root
# -----------------------------
need_root

# -----------------------------
# 1) If DATA_SRC is provided, bind-mount it to /data persistently.
#    If not provided, use OS disk paths (still under /data by default).
# -----------------------------
if [[ -n "${DATA_SRC}" ]]; then
  log "Ensuring attached disk exists at ${DATA_SRC}"
  if [[ ! -d "${DATA_SRC}" ]]; then
    echo "❌ Expected Lima disk mount not found: ${DATA_SRC}"
    echo "   Check inside VM: ls -la /mnt | grep lima-"
    exit 1
  fi

  log "Creating mountpoint ${DATA_MNT}"
  mkdir -p "${DATA_MNT}"

  if ! mountpoint -q "${DATA_MNT}"; then
    log "Bind-mounting ${DATA_SRC} -> ${DATA_MNT}"
    mount --bind "${DATA_SRC}" "${DATA_MNT}"
  fi

  FSTAB_LINE="${DATA_SRC} ${DATA_MNT} none bind 0 0"
  if ! grep -Fxq "${FSTAB_LINE}" /etc/fstab; then
    log "Persisting bind mount in /etc/fstab"
    echo "${FSTAB_LINE}" >> /etc/fstab
  fi
else
  log "No DATA_SRC provided — using OS disk (no additional persistent disk)"
  mkdir -p "${DATA_MNT}"
fi

log "Creating MongoDB directories on ${DATA_MNT}"
mkdir -p "${MONGO_DBPATH}"
mkdir -p "$(dirname "${MONGO_LOGPATH}")"

# -----------------------------
# 2) Install MongoDB Community (MongoDB apt repo)
# -----------------------------
log "Installing MongoDB Community (mongodb-org ${MONGO_MAJOR})"

ensure_pkg ca-certificates
ensure_pkg gnupg
ensure_pkg curl

install -d -m 0755 /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/mongodb-server-${MONGO_MAJOR}.gpg ]]; then
  log "Adding MongoDB GPG key"
  curl -fsSL "https://pgp.mongodb.com/server-${MONGO_MAJOR}.asc" \
    | gpg --dearmor -o "/etc/apt/keyrings/mongodb-server-${MONGO_MAJOR}.gpg"
fi

REPO_FILE="/etc/apt/sources.list.d/mongodb-org-${MONGO_MAJOR}.list"
if [[ ! -f "${REPO_FILE}" ]]; then
  log "Adding MongoDB apt repo"
  echo "deb [ arch=arm64,armhf signed-by=/etc/apt/keyrings/mongodb-server-${MONGO_MAJOR}.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/${MONGO_MAJOR} multiverse" \
    > "${REPO_FILE}"
fi

apt-get update -y
apt-get install -y mongodb-org
systemctl enable mongod

# -----------------------------
# 3) Configure mongod to use /data (dbPath/logPath/bindIp)
# -----------------------------
CONF="/etc/mongod.conf"

log "Setting ownership on ${DATA_MNT} paths for mongodb user"
chown -R mongodb:mongodb "${MONGO_DBPATH}" "$(dirname "${MONGO_LOGPATH}")"

log "Configuring mongod.conf (dbPath/logPath/bindIp)"
if grep -q '^[[:space:]]*dbPath:' "${CONF}"; then
  sed -i.bak "s|^[[:space:]]*dbPath:.*|  dbPath: ${MONGO_DBPATH}|" "${CONF}"
else
  if grep -q '^storage:' "${CONF}"; then
    awk -v dbp="${MONGO_DBPATH}" '
      {print}
      /^storage:/ && !x {print "  dbPath: " dbp; x=1}
    ' "${CONF}" > "${CONF}.tmp" && mv "${CONF}.tmp" "${CONF}"
  else
    cat >> "${CONF}" <<EOF

storage:
  dbPath: ${MONGO_DBPATH}
EOF
  fi
fi

if grep -q '^[[:space:]]*path:' "${CONF}"; then
  awk -v lp="${MONGO_LOGPATH}" '
    BEGIN{inSys=0; done=0}
    /^systemLog:/ {inSys=1}
    inSys && /^[[:space:]]*path:/ && !done {
      sub(/path:.*/, "path: " lp); done=1
    }
    {print}
  ' "${CONF}" > "${CONF}.tmp" && mv "${CONF}.tmp" "${CONF}"
else
  cat >> "${CONF}" <<EOF

systemLog:
  destination: file
  path: ${MONGO_LOGPATH}
  logAppend: true
EOF
fi

if grep -q '^[[:space:]]*bindIp:' "${CONF}"; then
  sed -i.bak "s|^[[:space:]]*bindIp:.*|  bindIp: 127.0.0.1|" "${CONF}"
else
  if grep -q '^net:' "${CONF}"; then
    awk '
      {print}
      /^net:/ && !x {print "  bindIp: 127.0.0.1"; x=1}
    ' "${CONF}" > "${CONF}.tmp" && mv "${CONF}.tmp" "${CONF}"
  else
    cat >> "${CONF}" <<EOF

net:
  port: 27017
  bindIp: 127.0.0.1
EOF
  fi
fi

# -----------------------------
# 4) Secrets (source of truth) + deterministic user reconciliation
# -----------------------------
log "Preparing secrets file ${SECRETS_FILE}"
if [[ ! -f "${SECRETS_FILE}" ]]; then
  ADMIN_PASS="$(rand_pw)"
  USER_PASS="$(rand_pw)"
  cat > "${SECRETS_FILE}" <<EOF
DB_NAME="${DB_NAME}"
DB_ADMIN_USER="${DB_ADMIN_USER}"
DB_ADMIN_PASS="${ADMIN_PASS}"
DB_USER="${DB_USER}"
DB_USER_PASS="${USER_PASS}"
MONGODB_URI="mongodb://${DB_USER}:${USER_PASS}@127.0.0.1:27017/${DB_NAME}?authSource=${DB_NAME}"
EOF
  chmod 600 "${SECRETS_FILE}"
  log "✅ Wrote secrets to ${SECRETS_FILE} (root-only)"
else
  log "✅ Secrets file already exists (reusing): ${SECRETS_FILE}"
fi

# shellcheck disable=SC1090
source "${SECRETS_FILE}"

# Ensure URI always matches where the app user is defined (dbUser lives in ${DB_NAME})
NEW_URI="mongodb://${DB_USER}:${DB_USER_PASS}@127.0.0.1:27017/${DB_NAME}?authSource=${DB_NAME}"
if grep -q '^MONGODB_URI=' "${SECRETS_FILE}"; then
  sed -i.bak "s|^MONGODB_URI=.*|MONGODB_URI=\"${NEW_URI}\"|" "${SECRETS_FILE}"
else
  echo "MONGODB_URI=\"${NEW_URI}\"" >> "${SECRETS_FILE}"
fi
source "${SECRETS_FILE}"

log "Starting mongod (ensure running)"
systemctl restart mongod
wait_for_mongo

log "Temporarily disabling auth to reconcile admin user with ${SECRETS_FILE}"
set_auth disabled
systemctl restart mongod
wait_for_mongo

log "Creating/updating admin user (root): ${DB_ADMIN_USER}"
mongosh --quiet <<EOF
use admin
const u = db.getUser("${DB_ADMIN_USER}");
if (!u) {
  db.createUser({ user: "${DB_ADMIN_USER}", pwd: "${DB_ADMIN_PASS}", roles: [ { role: "root", db: "admin" } ] });
} else {
  db.updateUser("${DB_ADMIN_USER}", { pwd: "${DB_ADMIN_PASS}", roles: [ { role: "root", db: "admin" } ] });
}
EOF

log "Enabling auth"
set_auth enabled
systemctl restart mongod
wait_for_mongo

log "Creating/updating app user: ${DB_USER} on DB ${DB_NAME}"
mongosh --quiet --username "${DB_ADMIN_USER}" --password "${DB_ADMIN_PASS}" --authenticationDatabase admin <<EOF
use ${DB_NAME}
const u = db.getUser("${DB_USER}");
if (!u) {
  db.createUser({ user: "${DB_USER}", pwd: "${DB_USER_PASS}", roles: [ { role: "readWrite", db: "${DB_NAME}" }, { role: "dbAdmin", db: "${DB_NAME}" } ] });
} else {
  db.updateUser("${DB_USER}", { pwd: "${DB_USER_PASS}", roles: [ { role: "readWrite", db: "${DB_NAME}" }, { role: "dbAdmin", db: "${DB_NAME}" } ] });
}
EOF

# -----------------------------
# 5) Final checks
# -----------------------------
log "Verifying authenticated access via MONGODB_URI"
mongosh --quiet "${MONGODB_URI}" --eval "db.runCommand({ping:1})" >/dev/null
log "✅ Authenticated ping succeeded"

# -----------------------------
# 6) Convenience aliases (Option A): /etc/profile.d/mongo-aliases.sh
# -----------------------------
log "Installing MongoDB aliases (mdb_user, mdb_admin) in /etc/profile.d"
cat > /etc/profile.d/mongo-aliases.sh <<'EOF'
# MongoDB helper aliases for the VM bakeoff series
# Uses /etc/todo-secrets.env (root-only) to avoid leaking creds in user dotfiles.

# Auth as app user (dbUser)
alias mdb_user='sudo bash -lc '"'"'source /etc/todo-secrets.env && mongosh "$MONGODB_URI"'"'"''

# Auth as admin (dbAdmin)
alias mdb_admin='sudo bash -lc '"'"'source /etc/todo-secrets.env && mongosh --host 127.0.0.1 --port 27017 --username "$DB_ADMIN_USER" --password "$DB_ADMIN_PASS" --authenticationDatabase admin'"'"''
EOF
chmod 0644 /etc/profile.d/mongo-aliases.sh

log "Done! 🎉 Next: use ${SECRETS_FILE} for app connection string."
echo "🔐 Secrets live at: ${SECRETS_FILE}"
echo "📌 Tip: from root shell, run: source ${SECRETS_FILE} && echo \$MONGODB_URI"
echo "✨ New shell aliases: mdb_user / mdb_admin (log out/in or run: source /etc/profile.d/mongo-aliases.sh)"
