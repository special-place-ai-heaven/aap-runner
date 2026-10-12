#!/bin/bash
# Drain with docker and the job stubbed: the drain file stops new job runs, a
# running job finishes untouched, a listening runner (no job) has its
# container removed and then its registration deleted by runner name, and
# the manager exits 0 and keeps the drain file. run_one starts no container
# while draining. Also --drain and --undrain. Uses the real slot_loop and
# run_pool.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../manager.sh
source "${here}/../manager.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

RUN_DIR=$(mktemp -d)
log="${RUN_DIR}/log"
err="${RUN_DIR}/err"
trap 'rm -rf "${RUN_DIR}"' EXIT
STATUS_TICK_SECONDS=0.2
: > "${log}"

runs() {
  grep -c "^run $1\$" "${log}" || true
}

# Stubs for the docker side of the pool.
# shellcheck disable=SC2317
disk_ok() {
  return 0
}
# shellcheck disable=SC2317,SC2329
remove_job_containers() {
  echo removed >> "${log}"
}
# shellcheck disable=SC2317
remove_slot_containers() {
  echo "cleaned $1" >> "${log}"
}
# The runner name comes from the container's hostname, not its name.
# shellcheck disable=SC2317
docker() {
  if [[ "$1" == inspect ]]; then
    echo "host${4##*-}"
  fi
}
# shellcheck disable=SC2317
deregister_runner() {
  echo "deregister $1" >> "${log}"
}
# Slot 1 runs a 2 s job. Slot 2's runner listens and never gets a job.
# shellcheck disable=SC2317
run_one() {
  echo "run $1" >> "${log}"
  if [[ "$1" == 1 ]]; then
    set_slot_state 1 running aap-crrr-1-busy build
    sleep 2
    echo "finished 1" >> "${log}"
    set_slot_state 1 idle
    return 0
  fi
  set_slot_state 2 listening aap-crrr-2-idle
  echo "listener ${BASHPID}" >> "${log}"
  sleep 30
}

# A drain file present before a slot loops: no run, exit 0.
: > "${RUN_DIR}/drain"
rc=0
(slot_loop 1) 2>/dev/null || rc=$?
[[ "${rc}" -eq 0 ]] || fail "a drained slot exited ${rc}; want 0"
[[ "$(runs 1)" -eq 0 ]] || fail "a drained slot started a job run"
echo "drained slot starts no run ok"

# Drained before the pool starts: every slot exits 0, then the manager.
: > "${log}"
AAP_RUNNER_COUNT=2
rc=0
(run_pool) 2> "${err}" || rc=$?
[[ "${rc}" -eq 0 ]] || fail "run_pool exited ${rc} with the drain file present; want 0: $(cat "${err}")"
[[ "$(runs 1)" -eq 0 && "$(runs 2)" -eq 0 ]] || fail "a job run started while drained"
[[ -e "${RUN_DIR}/drain" ]] || fail "the manager removed the drain file"
[[ ! -e "${RUN_DIR}/status.json" ]] || fail "status.json was left after a drained exit"
echo "drained pool exits 0 ok"

# Drain while slot 1 has a job and slot 2 listens.
rm -f "${RUN_DIR}/drain"
: > "${log}"
(run_pool) 2> "${err}" &
pool=$!
for _ in $(seq 1 50); do
  [[ -f "${RUN_DIR}/status.json" && "$(jq -r .busy "${RUN_DIR}/status.json")" == 1 ]] \
    && grep -q '^listener ' "${log}" && break
  sleep 0.1
done
[[ "$(jq -r '.state + "/" + .job' "${RUN_DIR}/status.json")" == running/build ]] \
  || fail "status before the drain: $(cat "${RUN_DIR}/status.json")"
: > "${RUN_DIR}/drain"
sleep 0.6
[[ "$(jq -r '.state + "/" + .job + "/" + (.busy | tostring)' "${RUN_DIR}/status.json")" == draining/build/1 ]] \
  || fail "status while draining: $(cat "${RUN_DIR}/status.json")"
listener=$(awk '/^listener / { print $2 }' "${log}")
if kill -0 "${listener}" 2>/dev/null; then
  fail "slot 2's listening runner was still running after the drain"
fi
[[ "$(grep -E '^(cleaned|deregister) ' "${log}" | tr '\n' ' ')" == "cleaned 2 deregister aap-crrr-hostidle " ]] \
  || fail "slot 2 was not removed then deregistered by runner name: $(cat "${log}")"
kill -0 "${pool}" 2>/dev/null || fail "the manager stopped while slot 1's job was running"
rc=0
wait "${pool}" || rc=$?
[[ "${rc}" -eq 0 ]] || fail "the drained manager exited ${rc}; want 0: $(cat "${err}")"
grep -qx 'finished 1' "${log}" || fail "slot 1's running job did not finish"
if grep -q '^cleaned 1$\|^deregister aap-crrr-hostbusy$' "${log}"; then
  fail "the drain touched slot 1, which had a job: $(cat "${log}")"
fi
[[ "$(runs 1)" -eq 1 ]] || fail "slot 1 started $(runs 1) job runs; a drain allows no new one"
[[ "$(runs 2)" -eq 1 ]] || fail "slot 2 started $(runs 2) job runs"
grep -qx 'slot 1 drained' "${err}" || fail "slot 1 did not exit through the drain: $(cat "${err}")"
grep -qx 'drained: no slot has a job; stopping the manager' "${err}" || fail "no drained stop line"
grep -qx removed "${log}" || fail "the pool was not cleaned up on the drained exit"
[[ -e "${RUN_DIR}/drain" ]] || fail "the manager removed the drain file"
[[ ! -e "${RUN_DIR}/status.json" ]] || fail "status.json was left after a drained exit"
echo "drain removes and deregisters the listener, lets the job finish, exits 0 ok"

# run_one while draining: the created container is removed before it starts,
# so no runner registers and no token is minted.
# Re-source for the real run_one; keep this test's RUN_DIR.
saved_run_dir=${RUN_DIR}
# shellcheck source=SCRIPTDIR/../manager.sh
source "${here}/../manager.sh"
RUN_DIR=${saved_run_dir}
calls="${RUN_DIR}/calls"
: > "${calls}"
# shellcheck disable=SC2317
docker() {
  printf '%s\n' "$*" >> "${calls}"
}
# shellcheck disable=SC2317
mint_registration_token() {
  echo minted >> "${calls}"
}
AAP_JOB_CPUS=6
AAP_JOB_MEMORY=12g
AAP_JOB_PIDS_LIMIT=4096
AAP_JOB_TIMEOUT_MINUTES=120
AAP_RUNNER_COUNT=1
finish_runner_count
RUNNER_UID=$(id -u)
SCCACHE_HOST_DIR="${RUN_DIR}/sccache"
: > "${RUN_DIR}/drain"
run_one 1 > /dev/null 2>&1 || fail "run_one failed while draining"
grep -q '^create ' "${calls}" || fail "the docker stub saw no create: $(cat "${calls}")"
if grep -q '^start \|^minted$' "${calls}"; then
  fail "run_one started a runner or minted a token while draining: $(cat "${calls}")"
fi
grep -q '^rm -f -v aap-crrr-1-' "${calls}" || fail "run_one left the created container while draining"
echo "run_one starts no runner while draining ok"

# The CLI the supervisor runs as root. id and install are stubbed so the
# test needs no root.
# shellcheck disable=SC2317
id() {
  echo 0
}
# shellcheck disable=SC2317
install() {
  mkdir -p "${!#}"
}
rm -f "${RUN_DIR}/drain"
(main --drain) > /dev/null || fail "--drain exited non-zero"
[[ -e "${RUN_DIR}/drain" ]] || fail "--drain did not create the drain file"
(main --undrain) || fail "--undrain exited non-zero"
[[ ! -e "${RUN_DIR}/drain" ]] || fail "--undrain did not remove the drain file"
echo "drain cli ok"

echo "manager drain tests ok"
