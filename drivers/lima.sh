#!/usr/bin/env bash
set -euo pipefail

: "${PLATFORM:=lima}"
: "${VM_NAME:=ubuntu-todo-vz-${PLATFORM}}"
: "${LIMA_YAML:=platforms/lima/lima.yaml}"

require() {
  command -v limactl >/dev/null 2>&1 || {
    echo "❌ limactl not found. Install: brew install lima"
    exit 1
  }
}

exists() {
  # Avoid --format for portability across Lima versions.
  # Parse first column (NAME) from `limactl list`, skipping header.
  limactl list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${VM_NAME}"
}


ensure_data_disk() {
  : "${DATA_DISK_NAME:=ubuntu-todo-data-${PLATFORM}}"
  : "${DATA_DISK_SIZE:=20GiB}"

  # `limactl disk list` output format varies by version; avoid --format for portability.
  # Extract disk names from the first column, skipping header lines.
  if limactl disk list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${DATA_DISK_NAME}"; then
    echo "✅ Data disk exists: ${DATA_DISK_NAME}"
  else
    echo "💾 Creating data disk: ${DATA_DISK_NAME} (${DATA_DISK_SIZE})"
    limactl disk create "${DATA_DISK_NAME}" --size "${DATA_DISK_SIZE}"
  fi
}

up() {
  require

  ensure_data_disk

  if [[ ! -f "${LIMA_YAML}" ]]; then
    echo "🧩 Missing ${LIMA_YAML} — generating via ./scripts/lima-pin-ubuntu.sh"
    ./scripts/lima-pin-ubuntu.sh
  fi

  if exists; then
    echo "▶️  Starting VM: ${VM_NAME}"
    limactl start --tty=false "${VM_NAME}"
  else
    echo "🚀 Creating VM (VZ): ${VM_NAME}"
    limactl start --name="${VM_NAME}" --tty=false "${LIMA_YAML}"
  fi
}



down() {
  require
  if exists; then
    echo "🛑 Stopping VM: ${VM_NAME}"
    limactl stop "${VM_NAME}"
  else
    echo "ℹ️  VM not found: ${VM_NAME}"
  fi
}

destroy() {
  require
  if exists; then
    echo "💣 Deleting VM: ${VM_NAME}"
    limactl delete -f "${VM_NAME}"
  else
    echo "ℹ️  VM not found: ${VM_NAME}"
  fi
}

status() {
  require
  limactl list "${VM_NAME}" || true
}

ssh() {
  require
  echo "🔐 Opening shell in: ${VM_NAME}"
  limactl shell "${VM_NAME}"
}

endpoints() {
  : "${HOST_HTTP:=8080}"
  : "${HOST_API:=8081}"

  echo "🌍 Web:  http://localhost:${HOST_HTTP}/"
  echo "🧪 API:  http://localhost:${HOST_API}/"
  echo "🔐 SSH:  make ssh PLATFORM=lima   (or: limactl shell ${VM_NAME})"
}

run() {
  require
  local cmd="${1:?cmd required}"
  # Older Lima versions may not support `limactl ssh`.
  # `limactl shell <name> -- <cmd>` runs a command inside the guest.
  limactl shell "${VM_NAME}" -- bash -lc "${cmd}"
}

run_stdin() {
  require

  # 1) Copy stdin into the VM as a file (no sudo, no TTY needed)
  limactl shell "${VM_NAME}" -- bash -lc 'cat > /tmp/provision.sh && chmod +x /tmp/provision.sh'

  # 2) Execute it with sudo (no stdin pipe involved)
  limactl shell "${VM_NAME}" -- bash -lc 'sudo /tmp/provision.sh; rc=$?; rm -f /tmp/provision.sh; exit $rc'
}


cmd="${1:-}"
case "${cmd}" in
  up|down|destroy|status|ssh|endpoints) "$cmd" ;;
  run) shift; run "$*" ;;
  run_stdin) run_stdin ;;
  *) echo "Unknown cmd: ${cmd}"; exit 2 ;;
esac


