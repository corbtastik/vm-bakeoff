#!/usr/bin/env bash
set -euo pipefail

vm="${1:-}"
if [[ -z "${vm}" ]]; then
  echo "❌ VM required. Example: ./scripts/lima-gen-yaml.sh mongodb"
  exit 1
fi

VM="${vm}"
# shellcheck disable=SC1090
source "vms/${VM}.env"

: "${VM_NAME:=${VM}-vz}"
: "${VM_KIND:=ubuntu}"
: "${CPUS:=4}"
: "${MEMORY:=6GiB}"
: "${ROOT_DISK_SIZE:=20GiB}"
: "${FORWARDS:=}"
: "${HAS_DATA_DISK:=1}"
: "${DATA_DISK_NAME:=${VM}-data}"

OUT="platforms/lima/vms/${VM}.yaml"
mkdir -p "$(dirname "${OUT}")"

case "${VM_KIND}" in
  ubuntu)
    # shellcheck disable=SC1090
    source "platforms/lima/images/ubuntu.env"
    IMG_URL="${UBUNTU_URL}"
    IMG_DIGEST="sha256:${UBUNTU_SHA256}"
    ;;
  *)
    echo "❌ Unsupported VM_KIND=${VM_KIND} (supported: ubuntu)"
    exit 1
    ;;
esac

{
  cat <<EOF
vmType: "vz"
cpus: ${CPUS}
memory: "${MEMORY}"
disk: "${ROOT_DISK_SIZE}"

images:
  - location: "${IMG_URL}"
    arch: "aarch64"
    digest: "${IMG_DIGEST}"
EOF

  if [[ "${HAS_DATA_DISK}" == "1" ]]; then
    : "${DATA_DISK_SIZE:=20GiB}"
    cat <<EOF

additionalDisks:
  - name: "${DATA_DISK_NAME}"
    format: true
    fsType: "ext4"
EOF
  fi

  if [[ -n "${FORWARDS}" ]]; then
    echo
    echo "portForwards:"
    for p in ${FORWARDS}; do
      guest="${p%%:*}"
      host="${p##*:}"
      cat <<EOF
  - guestPort: ${guest}
    hostPort: ${host}
EOF
    done
  fi
} > "${OUT}"

echo "📝 Wrote ${OUT}"
