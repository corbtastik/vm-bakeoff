#!/usr/bin/env bash
set -euo pipefail

require() {
  command -v limactl >/dev/null 2>&1 || {
    echo "❌ limactl not found. Install: brew install lima"
    exit 1
  }
}

need_vm() {
  if [[ -z "${VM:-}" ]]; then
    echo "❌ VM is required. Example: make up VM=mongodb"
    exit 1
  fi
}

load_vm_env() {
  need_vm
  local f="vms/${VM}.env"
  if [[ ! -f "${f}" ]]; then
    echo "❌ Missing VM config: ${f}"
    echo "   Create it (see examples in vms/)."
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${f}"
  # shellcheck disable=SC1091
  source "lib/defaults.env"
}

vm_exists() {
  limactl list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${VM_NAME}"
}

disk_exists() {
  limactl disk list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${DATA_DISK_NAME}"
}

ensure_data_disk() {
  if [[ "${HAS_DATA_DISK}" != "1" ]]; then
    return 0
  fi

  if disk_exists; then
    echo "✅ Data disk exists: ${DATA_DISK_NAME}"
  else
    echo "💾 Creating data disk: ${DATA_DISK_NAME} (${DATA_DISK_SIZE})"
    limactl disk create "${DATA_DISK_NAME}" --size "${DATA_DISK_SIZE}"
  fi
}

delete_data_disk() {
  if [[ "${HAS_DATA_DISK}" != "1" ]]; then
    return 0
  fi

  if [[ "${KEEP_DISK:-0}" == "1" ]]; then
    echo "🧊 KEEP_DISK=1 set — not deleting disk: ${DATA_DISK_NAME}"
    return 0
  fi

  if disk_exists; then
    echo "🗑️  Deleting data disk: ${DATA_DISK_NAME}"
    limactl disk delete -f "${DATA_DISK_NAME}"
  else
    echo "ℹ️  Disk not found: ${DATA_DISK_NAME}"
  fi
}

ensure_vm_yaml() {
  : "${LIMA_YAML:=platforms/lima/vms/${VM}.yaml}"
  if [[ ! -f "${LIMA_YAML}" ]]; then
    echo "🧩 Missing ${LIMA_YAML} — generating"
    ./scripts/lima-gen-yaml.sh "${VM}"
  fi
}

up() {
  require
  load_vm_env

  ensure_data_disk
  ensure_vm_yaml

  if vm_exists; then
    echo "▶️  Starting VM: ${VM_NAME}"
    limactl start --tty=false "${VM_NAME}"
  else
    echo "🚀 Creating VM: ${VM_NAME}"
    limactl start --name="${VM_NAME}" --tty=false "${LIMA_YAML}"
  fi
}

down() {
  require
  load_vm_env

  if vm_exists; then
    echo "🛑 Stopping VM: ${VM_NAME}"
    limactl stop "${VM_NAME}"
  else
    echo "ℹ️  VM not found: ${VM_NAME}"
  fi
}

destroy() {
  require
  load_vm_env

  if vm_exists; then
    echo "💣 Deleting VM: ${VM_NAME}"
    limactl delete -f "${VM_NAME}"
  else
    echo "ℹ️  VM not found: ${VM_NAME}"
  fi

  delete_data_disk
}

status() {
  require
  load_vm_env
  limactl list "${VM_NAME}" || true
}

ssh() {
  require
  load_vm_env
  echo "🔐 Opening shell in: ${VM_NAME}"
  limactl shell "${VM_NAME}"
}

endpoints() {
  require
  load_vm_env

  echo "🧠 VM: ${VM}  (name: ${VM_NAME})"
  echo "📦 Kind: ${VM_KIND}"
  if [[ "${HAS_DATA_DISK}" == "1" ]]; then
    echo "💾 Disk: ${DATA_DISK_NAME} (${DATA_DISK_SIZE})"
  else
    echo "💾 Disk: none"
  fi

  if [[ -z "${FORWARDS}" ]]; then
    echo "🌐 Port forwards: (none)"
    return 0
  fi

  echo "🌐 Port forwards:"
  for p in ${FORWARDS}; do
    guest="${p%%:*}"
    host="${p##*:}"
    echo "   host ${host} → guest ${guest}"
  done
}

run() {
  require
  load_vm_env

  local cmd="${1:?cmd required}"
  limactl shell "${VM_NAME}" -- bash -lc "${cmd}"
}

run_stdin() {
  require
  load_vm_env

  # Use unique temp file to avoid collisions with concurrent provisions
  local tmp_script="/tmp/provision-$$.sh"
  limactl shell "${VM_NAME}" -- bash -lc "cat > ${tmp_script} && chmod +x ${tmp_script}"
  limactl shell "${VM_NAME}" -- bash -lc "sudo ${tmp_script}; rc=\$?; rm -f ${tmp_script}; exit \$rc"
}

cmd="${1:-}"
case "${cmd}" in
  up|down|destroy|status|ssh|endpoints) "$cmd" ;;
  run) shift; run "$*" ;;
  run_stdin) run_stdin ;;
  *) echo "Unknown cmd: ${cmd}"; exit 2 ;;
esac
