#!/usr/bin/env bash
set -euo pipefail

: "${UBUNTU_DIST:=noble}"
: "${UBUNTU_VER:=24.04}"
: "${UBUNTU_BUILD:=20251213}"

UBUNTU_DIR="release-${UBUNTU_BUILD}"
UBUNTU_IMG="ubuntu-${UBUNTU_VER}-server-cloudimg-arm64.img"
UBUNTU_BASE="https://cloud-images.ubuntu.com/releases/${UBUNTU_DIST}/${UBUNTU_DIR}"
UBUNTU_URL="${UBUNTU_BASE}/${UBUNTU_IMG}"
UBUNTU_SUMS="${UBUNTU_BASE}/SHA256SUMS"

OUT="platforms/lima/images/ubuntu.env"
mkdir -p "$(dirname "${OUT}")"

echo "🔎 Fetching SHA256 for ${UBUNTU_IMG} from ${UBUNTU_SUMS}"
SHA="$(http -b "${UBUNTU_SUMS}" | awk "/${UBUNTU_IMG}\$/{print \$1}")"

if [[ -z "${SHA}" ]]; then
  echo "❌ Could not find SHA for ${UBUNTU_IMG}"
  exit 1
fi

cat > "${OUT}" <<EOF
UBUNTU_DIST="${UBUNTU_DIST}"
UBUNTU_VER="${UBUNTU_VER}"
UBUNTU_BUILD="${UBUNTU_BUILD}"
UBUNTU_IMG="${UBUNTU_IMG}"
UBUNTU_URL="${UBUNTU_URL}"
UBUNTU_SHA256="${SHA}"
EOF

echo "✅ Wrote ${OUT}"
