#!/bin/bash
# Hermetic checks of parity/workloads/linux/lib.sh and the entry's selection guards: verdict lines and exit codes,
# path and ANSI normalization, the cause line run writes for a failing tool, die running wl_cleanup, a missing oracle
# key counting as a failure, helpers working with an empty PATH, and invoke-workloads.sh refusing an empty selection
# or a non-empty output folder. Needs bash, python3 and coreutils only (no toolchain, network or root).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "${here}/../../../.." && pwd)
lib="${repo}/parity/workloads/linux/lib.sh"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# wl BODY [WL_START ARGS...]: runs BODY between wl_start and wl_end in a new bash; the log is in ${tmp}/log, the
# observed facts in ${tmp}/obs/test__one.observed.json; returns the workload's exit code
wl() {
  rm -rf "${tmp}/w" "${tmp}/obs"
  mkdir -p "${tmp}/w"
  local rc=0
  BODY=$1 PARITY_OBS_DIR="${tmp}/obs" bash -c '. "$1"; shift; wl_start --work "$0" --id test/one "$@"; eval "${BODY}"; wl_end' \
    "${tmp}/w" "${lib}" "${@:2}" > "${tmp}/log" 2>&1 || rc=$?
  return "${rc}"
}
has() { grep -qxF -- "$1" "${tmp}/log" || fail "log lacks '$1':"$'\n'"$(cat "${tmp}/log")"; }
obs() { python3 -B -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "${tmp}/obs/test__one.observed.json" "$1"; }

# all facts met: exit 0, verdict line, the fact in the observed file
wl 'fact a.b x x; observe c.d "v1
v2"' || fail "met facts exited $?"
has 'ok   a.b = x'
has 'obs  c.d = v1,v2'
has 'workload test/one: all oracle checks met'
[ "$(obs 'd["facts"]["a.b"]["ok"], d["facts"]["c.d"]["observed"], d["failures"]')" = "(True, 'v1,v2', [])" ] || fail 'observed file'

# a failing fact: exit 1, the oracle error line, counted
rc=0; wl 'fact a.b seen wanted; fact_re c.d abc "^b"' || rc=$?
[ "${rc}" = 1 ] || fail "failing fact exited ${rc}"
has "error: oracle a.b expected 'wanted' observed 'seen'"
has "error: oracle c.d expected /^b/ observed 'abc'"
has 'workload test/one: 2 oracle check(s) not met'

# norm: work and repo paths, ANSI colours
wl 'line "$(norm "${WORK}/f ${REPO}/g "$'"'"'\x1b[31mred\x1b[0m'"'"')"' || fail 'norm workload failed'
has '<work>/f <repo>/g red'

# run: a failing tool ends the workload with its cause line, not its last line; nothing after it runs
rc=0; wl 'run sh -c "echo starting; echo fatal: thing failed; echo trailing; exit 3"; line after' || rc=$?
[ "${rc}" = 1 ] || fail "failing run exited ${rc}"
has 'error: sh exited with code 3: fatal: thing failed'
! grep -qx after "${tmp}/log" || fail 'run continued after a failure'

# die runs wl_cleanup and records the exception
rc=0; wl 'wl_cleanup() { line cleaned; }; die "named reason"' || rc=$?
[ "${rc}" = 1 ] || fail "die exited ${rc}"
has 'error: named reason'
has 'cleaned'
[ "$(obs 'd["failures"]')" = "['exception']" ] || fail 'die not recorded'

# a wl_cleanup that itself dies runs once and the workload still ends
rc=0; wl 'wl_cleanup() { line cleaned; die "cleanup failed"; }; die first' || rc=$?
[ "${rc}" = 1 ] || fail "dying cleanup exited ${rc}"
[ "$(grep -cx cleaned "${tmp}/log")" = 1 ] || fail 'wl_cleanup ran more than once'
has 'error: cleanup failed'

# oracle: values, lists and members; a missing key fails the workload even from inside $(...)
wl 'fact gcc "$(oracle versions/gcc)" 13.3.0; fact n "$(oracle_list java_home_vars | wc -l)" 5; fact k "$(oracle_keys services | grep -c "^docker$")" 1' \
  || fail 'oracle lookups failed'
rc=0; wl 'x=$(oracle no/such); fact x "${x}" ""' || rc=$?
[ "${rc}" = 1 ] || fail "missing oracle key exited ${rc}"
[ "$(obs 'd["failures"]')" = "['oracle-key:no/such']" ] || fail 'missing oracle key not recorded'

# a sabotage may empty PATH: the helpers still log, judge and write the observed file
rc=0; wl 'PATH=/nonexistent; fact v "$(oracle versions/cmake)" 3.31.6; run nosuchtool --flag' || rc=$?
[ "${rc}" = 1 ] || fail "empty PATH exited ${rc}"
has 'ok   v = 3.31.6'
has 'error: nosuchtool exited with code 127: nosuchtool: not found on PATH'
[ -f "${tmp}/obs/test__one.observed.json" ] || fail 'no observed file with an empty PATH'

# sabotage and extra arguments arrive as SABOTAGE and ARG_<name>
wl 'fact s "${SABOTAGE}" bogus; fact a "${ARG_sdk_band}" 8.0.100' --sabotage bogus --sdk-band 8.0.100 || fail 'arguments'

# the entry refuses an empty selection, an unknown name and a non-empty output folder
entry="${repo}/parity/workloads/linux/invoke-workloads.sh"
[ "$(bash "${entry}" --list | wc -l)" -eq 46 ] || fail 'list does not show 46 definitions'
bash "${entry}" --list | grep -qx 'xwin/sdk-cross  (unqualified: .*)' || fail 'unqualified not marked in --list'
rc=0; out=$(bash "${entry}" --name nosuch/workload --out "${tmp}/o1" 2>&1) || rc=$?
[ "${rc}" != 0 ] && [[ ${out} == *"no workload matches 'nosuch/workload'"* ]] || fail "unknown name: ${rc} ${out}"
rc=0; out=$(bash "${entry}" --name , --out "${tmp}/o2" 2>&1) || rc=$?
[ "${rc}" != 0 ] && [[ ${out} == *'no workload selected'* ]] || fail "empty selection: ${rc} ${out}"
mkdir -p "${tmp}/o3" && touch "${tmp}/o3/x"
rc=0; out=$(bash "${entry}" --name linux/gcc --out "${tmp}/o3" 2>&1) || rc=$?
[ "${rc}" != 0 ] && [[ ${out} == *'is not empty'* ]] || fail "non-empty out: ${rc} ${out}"
echo "lib_test: ok"
