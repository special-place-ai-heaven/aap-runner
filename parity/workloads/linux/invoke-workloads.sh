#!/bin/bash
# Entrypoint of the P18 Linux, Actions and xwin parity workloads (see README.md and invoke_workloads.py).
#   bash parity/workloads/linux/invoke-workloads.sh [--name linux/gcc,actions/linux] [--out DIR] [--list]
set -euo pipefail
exec python3 -B -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/invoke_workloads.py" "$@"
