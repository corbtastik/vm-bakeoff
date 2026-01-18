#!/usr/bin/env bash
set -euo pipefail
vm="${1:?VM required}"
VM="${vm}" ./drivers/lima.sh down
