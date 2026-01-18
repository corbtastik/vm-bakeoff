#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
set -euo pipefail

: "${NGINX_PORT:=80}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "❌ Run as root"
  exit 1
fi

apt-get update -y
apt-get install -y nginx
systemctl enable nginx
systemctl restart nginx

echo "✅ nginx running on port ${NGINX_PORT}"
