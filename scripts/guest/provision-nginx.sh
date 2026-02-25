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

: "${NGINX_PORT:=80}"

need_root

log "Installing nginx"
ensure_pkg nginx

systemctl enable nginx
systemctl restart nginx

log "nginx running on port ${NGINX_PORT}"
