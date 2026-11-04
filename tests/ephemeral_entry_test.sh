#!/bin/bash
# ephemeral-entry.sh and the zccache root: start_zccache creates the private
# root, runs `init` as the runner user from a clean environment with the budget
# docker passed in, and survives a failed init; the runner is started with only
# the disk bounds plus runner.env, never an sccache name. start_zccache is cut
# out of the script and run with runuser and install replaced by functions, so
# nothing here needs root or touches /var.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
entry="${here}/../distro/ephemeral-entry.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
calls="${work}/calls"
: > "${calls}"

fn=$(sed -n '/^start_zccache() {/,/^}/p' "${entry}")
[[ -n "${fn}" ]] || fail "ephemeral-entry.sh has no start_zccache"
eval "${fn}"

init_rc=0
# shellcheck disable=SC2317
install() { printf 'install %s\n' "$*" >> "${calls}"; }
# shellcheck disable=SC2317
runuser() {
  printf 'runuser %s\n' "$*" >> "${calls}"
  case "$*" in
    *" init "*) return "${init_rc}" ;;
    *" state "*) echo '{"state":"direct","detail":"no qualified compiler and invocation pair","bytes":null}' ;;
  esac
}

ZC_DIR=/usr/local/libexec/aap-guest/cache
ZC_ROOT=/var/cache/aap-zccache
export AAP_ZCCACHE_BUDGET_BYTES=9663676416

out=$(start_zccache 2>&1) || fail "start_zccache failed with a working init"
grep -qx "install -d -o runner -g runner -m 0700 ${ZC_ROOT}" "${calls}" || fail "the root is not created 0700 for the runner: $(cat "${calls}")"
grep -qx "runuser -u runner -- env -i PATH=/usr/bin:/bin HOME=/home/runner ${ZC_DIR}/aap-zccache.sh init ${ZC_DIR} ${ZC_ROOT} 9663676416" "${calls}" \
  || fail "init was not run as the runner from a clean environment with the budget: $(cat "${calls}")"
[[ "${out}" == "zccache: {\"state\":\"direct\""* ]] || fail "the state was not reported: ${out}"
echo "init ok"

: > "${calls}"
init_rc=1
out=$(start_zccache 2>&1) || fail "a failed init failed the job"
[[ "${out}" == *"init failed; compilers run directly"* ]] || fail "a failed init was not reported: ${out}"
echo "failed init ok"

: > "${calls}"
init_rc=0
unset AAP_ZCCACHE_BUDGET_BYTES
start_zccache > /dev/null 2>&1
grep -q " init ${ZC_DIR} ${ZC_ROOT} 0\$" "${calls}" || fail "a missing budget did not become 0: $(cat "${calls}")"
echo "missing budget ok"

# The runner gets the disk bounds and runner.env, and no sccache name.
if grep -qiE 'sccache|RUSTC_WRAPPER' "${entry}"; then
  fail "ephemeral-entry.sh still mentions sccache or RUSTC_WRAPPER"
fi
grep -q -- '--whitelist-environment=AAP_WORK_DISK_GIB,AAP_DISK_FLOOR_GB \\$' "${entry}" || fail "the run.sh whitelist is not the two disk bounds"
grep -qF "' bash \"\${ZC_ROOT}/state/runner.env\"" "${entry}" || fail "run.sh is not started with runner.env"
grep -qF '. "$1"' "${entry}" || fail "runner.env is not loaded before run.sh"
echo "runner environment ok"

echo "ephemeral entry tests ok"
