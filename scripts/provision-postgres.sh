#!/usr/bin/env bash
set -euo pipefail

vm="${1:?VM required}"
VM="${vm}"

# shellcheck disable=SC1090
source "vms/${VM}.env"
: "${HAS_DATA_DISK:=1}"
: "${DATA_DISK_NAME:=${VM}-data}"

# shellcheck disable=SC1090
source "software/postgres.env"

if [[ "${HAS_DATA_DISK}" == "1" ]]; then
  DATA_SRC="/mnt/lima-${DATA_DISK_NAME}"
else
  DATA_SRC=""
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
  cat scripts/guest/provision-postgres.sh
) | VM="${VM}" ./drivers/lima.sh run_stdin
