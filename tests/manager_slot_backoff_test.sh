#!/bin/bash
# A slot whose runner never registers (network or container create, the
# token mint, config.sh) backs off 5 s, 10 s, 20 s ... capped at 300 s, names
# the failing stage, and exits after SLOT_PREJOB_MAX_FAILS in a row; run_pool
# counts that exit toward retirement however long the attempts took. A job
# that ran, or a successful run, resets the count.
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
RUN_DIR="${work}/run"
mkdir -p "${RUN_DIR}"
sleeps="${work}/sleeps"
err="${work}/err"

# shellcheck disable=SC2317
write_status() { :; }
# shellcheck disable=SC2317
draining() { return 1; }
# shellcheck disable=SC2317
disk_ok() { return 0; }
# shellcheck disable=SC2317
clean_after_job() { :; }
# shellcheck disable=SC2317
sleep() { printf '%s ' "$1" >> "${sleeps}"; }

# PLAN is one letter per run_one call: f a pre-job failure, j a job that ran
# and exited non-zero, s a success. Past the plan run_one exits 99, which ends
# the loop.
PLAN=""
calls=0
# shellcheck disable=SC2317
run_one() {
  local step=${PLAN:calls:1}
  calls=$((calls + 1))
  case "${step}" in
    f) RUN_ONE_STAGE="registration token mint"; return 1 ;;
    j) RUN_ONE_STAGE=job; return 1 ;;
    s) RUN_ONE_STAGE=job; return 0 ;;
  esac
  exit 99
}

loop() {
  PLAN="$1"
  : > "${sleeps}"
  rc=0
  (slot_loop 1) 2> "${err}" || rc=$?
}

gave_up=${SLOT_GAVE_UP_EXIT:-75}
max=${SLOT_PREJOB_MAX_FAILS:-5}

loop ffffffffff
[[ "${rc}" -eq "${gave_up}" ]] || fail "ten pre-job failures: slot_loop exited ${rc}; want ${gave_up} after ${max} ($(cat "${err}"))"
[[ "$(cat "${sleeps}")" == "5 10 20 40 " ]] || fail "backoff was '$(cat "${sleeps}")'; want '5 10 20 40 '"
grep -q 'registration token mint' "${err}" || fail "the failing stage is not logged: $(cat "${err}")"
if grep -q 'runner container exited non-zero' "${err}"; then
  fail "a mint failure was logged as a runner container exit"
fi
echo "pre-job failures back off and give up ok"

loop ffffsffffj
[[ "${rc}" -eq 99 ]] || fail "a success between failures did not reset the count (rc ${rc})"
[[ "$(cat "${sleeps}")" == "5 10 20 40 5 10 20 40 5 " ]] || fail "backoff after a success was '$(cat "${sleeps}")'"
loop ffffjffff
[[ "${rc}" -eq 99 ]] || fail "a job that ran did not reset the count (rc ${rc})"
loop jjjjjjjj
[[ "${rc}" -eq 99 ]] || fail "failed jobs counted as pre-job failures (rc ${rc})"
[[ "$(cat "${sleeps}")" == "5 5 5 5 5 5 5 5 " ]] || fail "failed jobs slept '$(cat "${sleeps}")'; want 5 s each"
echo "a job or a success resets the count ok"

[[ "$(prejob_backoff_delay 1)" == 5 ]] || fail "first delay is not 5"
[[ "$(prejob_backoff_delay 6)" == 160 ]] || fail "sixth delay is not 160"
[[ "$(prejob_backoff_delay 7)" == 300 ]] || fail "seventh delay is not capped at 300"
[[ "$(prejob_backoff_delay 40)" == 300 ]] || fail "a large count is not capped at 300"
echo "backoff cap ok"

# The real run_one: each early failure names its stage.
unset -f run_one
source_run_one() {
  # shellcheck source=SCRIPTDIR/../distro/manager.sh
  source "${here}/../distro/manager.sh"
  write_status() { :; }
  arm_wall_clock() { echo "$$"; }
  disarm_wall_clock() { :; }
  AAP_JOB_CPUS=8
  AAP_JOB_MEMORY=16g
  AAP_JOB_PIDS_LIMIT=8192
  AAP_JOB_TIMEOUT_MINUTES=1
  RUN_DIR="${work}/run"
  finish_job_limits
  AAP_RUNNER_COUNT=1
  finish_runner_count
  AAP_GITHUB_ORG=example-org
  AAP_RUNNER_LABELS=self-hosted,linux,fresh
  AAP_RUNNER_GROUP=aap-crrr
  AAP_WORK_DISK_GIB=100
  AAP_DISK_FLOOR_GB=55
  AAP_RUNNER_IMAGE=aap-crrr-runner:local
}
stage_of() {
  local want="$1"
  RUN_ONE_STAGE=""
  if run_one 1 > /dev/null 2>&1; then
    fail "run_one succeeded; want a ${want} failure"
  fi
  [[ "${RUN_ONE_STAGE}" == "${want}" ]] || fail "stage was '${RUN_ONE_STAGE}'; want '${want}'"
}
source_run_one
# shellcheck disable=SC2317
docker() { [[ "$1" != create ]]; }
stage_of "container create"
# shellcheck disable=SC2317
docker() { [[ "$1 ${2-}" != "network create" ]]; }
stage_of "job network create"
# shellcheck disable=SC2317
docker() { return 0; }
# shellcheck disable=SC2317
mint_registration_token() { return 1; }
stage_of "registration token mint"
# config.sh failed in the container: it exited before the listener started.
# shellcheck disable=SC2317
mint_registration_token() { echo t; }
# shellcheck disable=SC2317
docker() { [[ "$1" != start ]]; }
stage_of "runner registration"
# A runner that listened, then exited non-zero, ran: that is a job exit.
# shellcheck disable=SC2317
docker() {
  if [[ "$1" == start ]]; then
    cat > /dev/null
    echo "2026-11-07 10:00:00Z: Listening for Jobs"
    return 1
  fi
  return 0
}
stage_of job
echo "run_one names the failing stage ok"

# run_pool: a slot that gave up counts toward retirement even when its
# attempts took longer than SLOT_FAST_SECONDS.
unset -f sleep
source "${here}/../distro/manager.sh"
# shellcheck disable=SC2317
remove_job_containers() { :; }
# shellcheck disable=SC2317
remove_slot_containers() { :; }
# shellcheck disable=SC2317
slot_restart_delay() { echo 0; }
# shellcheck disable=SC2317
slot_loop() {
  trap - EXIT TERM INT
  echo start >> "${work}/starts"
  exit "${gave_up}"
}
SLOT_FAST_SECONDS=0
AAP_RUNNER_COUNT=1
RUN_DIR="${work}/pool"
rc=0
: > "${work}/starts"
(run_pool) 2> "${err}" &
pool=$!
for _ in $(seq 1 100); do
  kill -0 "${pool}" 2>/dev/null || break
  [[ "$(wc -l < "${work}/starts" 2>/dev/null || echo 0)" -gt 20 ]] && break
  sleep 0.1
done
if kill -0 "${pool}" 2>/dev/null; then
  kill -TERM "${pool}" 2>/dev/null || true
  wait "${pool}" 2>/dev/null || true
  fail "a slot that kept giving up was restarted $(wc -l < "${work}/starts") times and never retired"
fi
wait "${pool}" || rc=$?
grep -q '^slot 1 retired' "${err}" || fail "slot 1 was not retired: $(cat "${err}")"
[[ "$(wc -l < "${work}/starts")" -eq "${SLOT_MAX_FAILS}" ]] || fail "slot started $(wc -l < "${work}/starts") times; want ${SLOT_MAX_FAILS}"
echo "a slot that gives up is retired ok"

echo "manager slot backoff tests ok"
