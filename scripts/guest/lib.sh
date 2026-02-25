#!/usr/bin/env bash
# Shared library for guest provisioning scripts

# -----------------------------
# Logging
# -----------------------------
log() {
  local prefix="${LOG_PREFIX:->>}"
  echo "${prefix} $*"
}

# -----------------------------
# Root check
# -----------------------------
need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root (this script is meant to be run via sudo)."
    exit 1
  fi
}

# -----------------------------
# Password generation
# -----------------------------
rand_pw() {
  # `head` closes the pipe early; with `pipefail` that can surface as SIGPIPE (141).
  # Temporarily disable pipefail for this pipeline.
  set +o pipefail
  local pw
  pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  set -o pipefail
  printf '%s' "$pw"
}

# -----------------------------
# Data disk mounting
# -----------------------------
# Usage: setup_data_mount "/mnt/lima-diskname" "/data"
# If DATA_SRC is empty, just creates DATA_MNT directory on OS disk
setup_data_mount() {
  local data_src="${1:-}"
  local data_mnt="${2:-/data}"

  if [[ -n "${data_src}" ]]; then
    log "Ensuring attached disk exists at ${data_src}"
    if [[ ! -d "${data_src}" ]]; then
      echo "Expected Lima disk mount not found: ${data_src}"
      echo "   Check inside VM: ls -la /mnt | grep lima-"
      exit 1
    fi

    log "Creating mountpoint ${data_mnt}"
    mkdir -p "${data_mnt}"

    if ! mountpoint -q "${data_mnt}"; then
      log "Bind-mounting ${data_src} -> ${data_mnt}"
      mount --bind "${data_src}" "${data_mnt}"
    fi

    local fstab_line="${data_src} ${data_mnt} none bind 0 0"
    if ! grep -Fxq "${fstab_line}" /etc/fstab; then
      log "Persisting bind mount in /etc/fstab"
      echo "${fstab_line}" >> /etc/fstab
    fi
  else
    log "No data source provided - using OS disk (no additional persistent disk)"
    mkdir -p "${data_mnt}"
  fi
}

# -----------------------------
# Package installation
# -----------------------------
ensure_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    log "Installing package: ${pkg}"
    apt-get update -y
    apt-get install -y "$pkg"
  fi
}
