#!/bin/bash
# Pool size, per-slot limit split, slot names, and runner uid checks in
# manager.sh. Sources the manager; its main loop does not run when sourced.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../manager.sh
source "${here}/../manager.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: got '$1', want '$2'"
}

# split CPUS MEMORY [COUNT]. No COUNT means the key is absent from manager.conf.
split() {
  AAP_JOB_CPUS=$1
  AAP_JOB_MEMORY=$2
  AAP_JOB_PIDS_LIMIT=4096
  AAP_JOB_TIMEOUT_MINUTES=120
  finish_job_limits
  unset AAP_RUNNER_COUNT
  if [[ "$#" -ge 3 ]]; then
    AAP_RUNNER_COUNT=$3
  fi
  finish_runner_count
}

refused() {
  if split "$@" 2>/dev/null; then
    fail "split $* was accepted"
  fi
}

split 6 12g
assert_eq "${AAP_RUNNER_COUNT}" 1 "absent count"
assert_eq "${SLOT_CPUS}/${SLOT_MEMORY}" 6/12g "absent count keeps limits"
for n in 1 2 3 4; do
  split 24 72g "${n}"
  assert_eq "${AAP_RUNNER_COUNT}" "${n}" "count ${n}"
done
for bad in 0 5 2.0 abc "" " 2" 02 -1; do
  refused 24 72g "${bad}"
done
echo "runner count ok"

unset AAP_RUNNER_COUNT
apply_config_line "AAP_RUNNER_COUNT="
if finish_runner_count 2>/dev/null; then
  fail "an empty AAP_RUNNER_COUNT= line was accepted"
fi
unset AAP_RUNNER_COUNT
apply_config_line "AAP_RUNNER_COUNT=3"
assert_eq "${AAP_RUNNER_COUNT}" 3 "config line"
echo "config key ok"

split 2.5 12g 1
assert_eq "${SLOT_CPUS}/${SLOT_MEMORY}" 2.5/12g "one slot is verbatim"
split 24 72g 3
assert_eq "${SLOT_CPUS}/${SLOT_MEMORY}" 8/24g "24/72g over 3"
split 24 72g 4
assert_eq "${SLOT_CPUS}/${SLOT_MEMORY}" 6/18g "24/72g over 4"
split 6 12g 4
assert_eq "${SLOT_CPUS}/${SLOT_MEMORY}" 1/3g "6/12g over 4 rounds cpus down"
split 6 10g 4
assert_eq "${SLOT_CPUS}/${SLOT_MEMORY}" 1/2560m "10g over 4 is whole MiB"
split 8 4096M 2
assert_eq "${SLOT_CPUS}/${SLOT_MEMORY}" 4/2g "M suffix"
split 8 4294967296 2
assert_eq "${SLOT_CPUS}/${SLOT_MEMORY}" 4/2g "bytes"
split 8 4194304k 4
assert_eq "${SLOT_CPUS}/${SLOT_MEMORY}" 2/1g "k suffix at exactly 1g"
refused 1 12g 2
refused 3 12g 4
refused 8 1g 2
refused 8 3g 4
refused 8 999999999999999999g 2
echo "limit split ok"

# Pin the clock so every name is made in the same second, as when the pool
# starts all slots at once. Only the slot index can tell them apart.
names=$(
  date() { echo 1700000000; }
  for s in 1 2 3 4; do job_name "${s}"; done
)
assert_eq "$(sort -u <<< "${names}" | wc -l)" 4 "names of 4 slots started in the same second"
assert_eq "$(head -1 <<< "${names}")" "aap-crrr-1-1700000000-$$" "slot 1 name"
echo "slot names ok"

assert_eq "$(slot_restart_delay 1)" 10 "first restart delay"
assert_eq "$(slot_restart_delay 4)" 40 "fourth restart delay"
assert_eq "$(slot_restart_delay 9)" 60 "restart delay cap"
echo "restart backoff ok"

runner_uid_ok 1000 || fail "uid 1000 was refused"
for bad in 0 "" abc "uid=1000" "1000 " -1 01; do
  if runner_uid_ok "${bad}"; then
    fail "runner uid '${bad}' was accepted"
  fi
done
echo "runner uid ok"

# The cache must sit on the work disk that disk_ok verifies, and never under
# /mnt, which assert_no_mnt_mounts refuses after docker create.
[[ "${SCCACHE_HOST_DIR}" == "${WORK_MOUNT}"/* ]] || fail "sccache source ${SCCACHE_HOST_DIR} is not under ${WORK_MOUNT}"
if mount_source_forbidden "${SCCACHE_HOST_DIR}"; then
  fail "the sccache source ${SCCACHE_HOST_DIR} is refused by assert_no_mnt_mounts"
fi
[[ "${SCCACHE_CONTAINER_DIR}" != /mnt* ]] || fail "sccache target ${SCCACHE_CONTAINER_DIR} is under /mnt"
echo "sccache mount source ok"

echo "manager pool tests ok"
