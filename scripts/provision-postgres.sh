#!/usr/bin/env bash
set -euo pipefail

vm="${1:?VM required}"
VM="${vm}"

# Load VM config (for disk name -> DATA_SRC mapping)
# shellcheck disable=SC1090
source "vms/${VM}.env"
: "${HAS_DATA_DISK:=1}"
: "${DATA_DISK_NAME:=${VM}-data}"

# Load Postgres software config
# shellcheck disable=SC1090
source "software/postgres.env"

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
  echo "export PG_MAJOR=\"${PG_MAJOR}\""
  echo "export PG_PORT=\"${PG_PORT}\""
  echo "export PG_BIND=\"${PG_BIND}\""
  echo "export PG_DB=\"${PG_DB}\""
  echo "export PG_USER=\"${PG_USER}\""
  echo "export SECRETS_FILE=\"${SECRETS_FILE}\""
  # Inline the shared library (skip shebang)
  tail -n +2 scripts/guest/lib.sh
  # Inline the main script (skip shebang and lib.sh sourcing)
  awk 'NR>1 && !/source.*lib\.sh/' scripts/guest/provision-postgres.sh
) | VM="${VM}" ./drivers/lima.sh run_stdin
