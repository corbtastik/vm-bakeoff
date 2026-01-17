#!/usr/bin/env bash
set -euo pipefail

platform="${1:?platform required}"
shift
cmd="${*:?command required}"

"./drivers/${platform}.sh" run "${cmd}"

