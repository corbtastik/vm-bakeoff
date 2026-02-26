#!/usr/bin/env bash
set -euo pipefail

vm="${1:?VM required}"
VM="${vm}"

# Load nginx software config
# shellcheck disable=SC1090
source "software/nginx.env"

(
  echo "#!/usr/bin/env bash"
  echo "export DEBIAN_FRONTEND=noninteractive"
  echo "set -euo pipefail"
  echo "export NGINX_PORT=\"${NGINX_PORT}\""
  # Inline the shared library (skip shebang)
  tail -n +2 scripts/guest/lib.sh
  # Inline the main script (skip shebang and lib.sh sourcing)
  awk 'NR>1 && !/source.*lib\.sh/' scripts/guest/provision-nginx.sh
) | VM="${VM}" ./drivers/lima.sh run_stdin
