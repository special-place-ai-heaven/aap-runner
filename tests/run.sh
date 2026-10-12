#!/bin/bash
# Runs every *_test.sh in this directory. Exits non-zero if any fails.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rc=0
for t in "${here}"/*_test.sh; do
  echo "== ${t##*/}"
  if ! bash "${t}"; then
    echo "FAILED: ${t##*/}" >&2
    rc=1
  fi
done
exit "${rc}"
