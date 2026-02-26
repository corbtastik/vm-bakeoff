#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
set -euo pipefail

# -----------------------------
# Shared library
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

LOG_PREFIX="[nginx]"

# -----------------------------
# Defaults (override-able)
# -----------------------------
: "${NGINX_PORT:=80}"

# -----------------------------
# 0) Must be root
# -----------------------------
need_root

# -----------------------------
# 1) Install nginx
# -----------------------------
log "Installing nginx"
ensure_pkg nginx

# -----------------------------
# 2) Enable and start service
# -----------------------------
log "Enabling and starting nginx"
systemctl enable nginx
systemctl restart nginx

# -----------------------------
# 3) Final summary
# -----------------------------
log "Done! nginx is running on port ${NGINX_PORT}."
