#!/usr/bin/env bash
set -euo pipefail

: "${CPUS:=4}"
: "${MEMORY:=6GiB}"
: "${HOST_HTTP:=8080}"
: "${HOST_API:=8081}"
: "${HOST_MDB:=37017}"
: "${DATA_DISK_NAME:=ubuntu-todo-data-lima}"
: "${DATA_DISK_SIZE:=20GiB}"

: "${UBUNTU_DIST:=noble}"
: "${UBUNTU_VER:=24.04}"
: "${UBUNTU_BUILD:=20251213}"


UBUNTU_DIR="release-${UBUNTU_BUILD}"
UBUNTU_IMG="ubuntu-${UBUNTU_VER}-server-cloudimg-arm64.img"
UBUNTU_BASE="https://cloud-images.ubuntu.com/releases/${UBUNTU_DIST}/${UBUNTU_DIR}"
UBUNTU_URL="${UBUNTU_BASE}/${UBUNTU_IMG}"
UBUNTU_SUMS="${UBUNTU_BASE}/SHA256SUMS"

OUT="platforms/lima/lima.yaml"
mkdir -p "$(dirname "$OUT")"

echo "🔎 Fetching SHA256 for ${UBUNTU_IMG} from ${UBUNTU_SUMS}"
SHA="$(http -b "$UBUNTU_SUMS" | awk "/${UBUNTU_IMG}\$/{print \$1}")"

if [[ -z "${SHA}" ]]; then
  echo "❌ Could not find SHA for ${UBUNTU_IMG}"
  exit 1
fi

echo "✅ SHA256=${SHA}"

cat > "$OUT" <<EOF
vmType: "vz"
cpus: ${CPUS}
memory: "${MEMORY}"
disk: "20GiB"
images:
  - location: "${UBUNTU_URL}"
    arch: "aarch64"
    digest: "sha256:${SHA}"

additionalDisks:
  - name: "${DATA_DISK_NAME}"
    format: true
    fsType: "ext4"

portForwards:
  - guestPort: 80
    hostPort: ${HOST_HTTP}
  - guestPort: 3000
    hostPort: ${HOST_API}
  - guestPort: 27017
    hostPort: ${HOST_MDB}    
EOF



echo "📝 Wrote ${OUT}"
