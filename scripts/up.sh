#!/usr/bin/env bash
set -euo pipefail
platform="${1:?platform required}"
"./drivers/${platform}.sh" up
