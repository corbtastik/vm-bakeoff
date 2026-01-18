#!/usr/bin/env bash
set -euo pipefail
vm="${1:?VM required}"
shift
cmd="${*:?command required}"
VM="${vm}" ./drivers/lima.sh run "${cmd}"
