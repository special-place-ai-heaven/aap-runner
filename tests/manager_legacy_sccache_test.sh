#!/bin/bash
# remove_legacy_sccache_tree: the sccache tree the manager kept on the work
# disk before zccache is removed once, with a log line; nothing else under the
# work mount is touched, and a second start is a silent no-op.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../distro/manager.sh
source "${here}/../distro/manager.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
WORK_MOUNT=${work}
mkdir -p "${work}/sccache/default/a" "${work}/docker"
echo cached > "${work}/sccache/default/a/obj"
echo keep > "${work}/docker/keep"

out=$(remove_legacy_sccache_tree 2>&1)
[[ ! -e "${work}/sccache" ]] || fail "the old sccache tree is still there"
[[ -f "${work}/docker/keep" ]] || fail "a sibling of the sccache tree was removed"
[[ "${out}" == "removing the old sccache tree ${work}/sccache; zccache keeps a private root per job" ]] \
  || fail "unexpected log: ${out}"

out=$(remove_legacy_sccache_tree 2>&1)
[[ -z "${out}" ]] || fail "a start without the tree logged: ${out}"

echo "legacy sccache tree removal ok"
