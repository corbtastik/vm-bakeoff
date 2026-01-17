#!/usr/bin/env bash
set -euo pipefail

platform="${1:?platform required}"

# Ensure VM is up first
make up PLATFORM="${platform}"

# Stream the guest script into the VM and run it as root
"./drivers/${platform}.sh" run_stdin < ./scripts/guest/provision.sh
