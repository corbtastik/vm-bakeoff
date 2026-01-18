#!/usr/bin/env bash
set -euo pipefail

vm="${1:?VM required}"
VM="${vm}"

# shellcheck disable=SC1090
source "software/nginx.env"

(
  echo "#!/usr/bin/env bash"
  echo "export DEBIAN_FRONTEND=noninteractive"
  echo "set -euo pipefail"
  echo "export NGINX_PORT=\"${NGINX_PORT}\""
  cat scripts/guest/provision-nginx.sh
) | VM="${VM}" ./drivers/lima.sh run_stdin
