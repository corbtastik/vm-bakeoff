#!/usr/bin/env bash
set -euo pipefail

vm="${1:?VM required}"
VM="${vm}"

# Load VM config (for disk name → DATA_SRC mapping)
# shellcheck disable=SC1090
source "vms/${VM}.env"
: "${HAS_DATA_DISK:=1}"
: "${DATA_DISK_NAME:=${VM}-data}"

# Load Mongo software config
# shellcheck disable=SC1090
source "software/mongodb.env"

# If VM has a data disk, Lima mounts it as /mnt/lima-<diskname>.
# We'll bind-mount it to /data inside the guest provision script.
if [[ "${HAS_DATA_DISK}" == "1" ]]; then
  DATA_SRC="/mnt/lima-${DATA_DISK_NAME}"
else
  DATA_SRC=""  # guest script will use OS disk defaults
fi

(
  echo "#!/usr/bin/env bash"
  echo "export DEBIAN_FRONTEND=noninteractive"
  echo "set -euo pipefail"
  if [[ -n "${DATA_SRC}" ]]; then
    echo "export DATA_SRC=\"${DATA_SRC}\""
    echo "export DATA_MNT=\"/data\""
  fi
  echo "export MONGO_MAJOR=\"${MONGO_MAJOR}\""
  echo "export DB_NAME=\"${DB_NAME}\""
  echo "export DB_ADMIN_USER=\"${DB_ADMIN_USER}\""
  echo "export DB_USER=\"${DB_USER}\""
  echo "export SECRETS_FILE=\"${SECRETS_FILE}\""
  cat scripts/guest/provision-mongodb.sh
) | VM="${VM}" ./drivers/lima.sh run_stdin
