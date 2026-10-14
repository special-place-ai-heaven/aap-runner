#!/bin/bash
# status.json for the Windows-side supervisor: the exact keys, each state,
# the job name taken from the runner's own "Running job: " line, mode 0644,
# and an atomic replace. Sources the manager; docker is stubbed.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../manager.sh
source "${here}/../manager.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

RUN_DIR=$(mktemp -d)
trap 'rm -rf "${RUN_DIR}"' EXIT
AAP_RUNNER_COUNT=2
AAP_JOB_CPUS=24
AAP_JOB_MEMORY=72g

field() {
  jq -r ".$1" "${RUN_DIR}/status.json"
}

expect() {
  local state="$1" job="$2" busy="$3" now
  [[ "$(field state)" == "${state}" ]] || fail "state is $(field state); want ${state}: $(cat "${RUN_DIR}/status.json")"
  [[ "$(field job)" == "${job}" ]] || fail "job is '$(field job)'; want '${job}'"
  [[ "$(field busy)" == "${busy}" ]] || fail "busy is $(field busy); want ${busy}"
  [[ "$(field slots)" == 2 ]] || fail "slots is $(field slots); want 2"
  now=$(date +%s)
  (( $(field updated) <= now && $(field updated) >= now - 5 )) || fail "updated $(field updated) is not now (${now})"
}

# Recorded format: "{DateTime.UtcNow:u}: <text>" (actions/runner v2.338.0).
feed() {
  printf '%s\n' "$2" | watch_runner_output "$1"
}

write_status
[[ "$(jq -r 'keys_unsorted | join(",")' "${RUN_DIR}/status.json")" == "state,job,repo,run_url,slots,busy,updated,runner_count,job_cpus,job_memory,job_io_mbps,sharing" ]] \
  || fail "keys are not state,job,repo,run_url,slots,busy,updated,runner_count,job_cpus,job_memory,job_io_mbps,sharing: $(cat "${RUN_DIR}/status.json")"
[[ "$(jq -c '[.runner_count, .job_cpus, .job_memory, .job_io_mbps]' "${RUN_DIR}/status.json")" == '[2,24,"72g",0]' ]] \
  || fail "effective limits in status.json: $(cat "${RUN_DIR}/status.json")"
jq -e '(.slots | type) == "number" and (.busy | type) == "number" and (.updated | type) == "number" and (.job | type) == "string"' \
  "${RUN_DIR}/status.json" >/dev/null || fail "a status field has the wrong JSON type"
[[ "$(stat -c '%a' "${RUN_DIR}/status.json")" == 644 ]] || fail "status.json is not mode 0644"
[[ "$(wc -l < "${RUN_DIR}/status.json")" -eq 1 ]] || fail "status.json is not one line"
expect starting "" 0
set_slot_state 1 starting
set_slot_state 2 starting
expect starting "" 0
echo "starting ok"

out=$(feed 1 '2026-10-12 21:00:00Z: Listening for Jobs')
[[ "${out}" == '2026-10-12 21:00:00Z: Listening for Jobs' ]] || fail "runner output was not passed through: ${out}"
expect idle "" 0
echo "idle ok"

feed 1 '2026-10-12 21:01:00Z: Running job: build (ubuntu, "1.2")' >/dev/null
expect running 'build (ubuntu, "1.2")' 1
feed 2 '2026-10-12 21:01:05Z: Running job: lint' >/dev/null
expect running lint 2
feed 2 '2026-10-12 21:03:00Z: Job lint completed with result: Succeeded' >/dev/null
expect running 'build (ubuntu, "1.2")' 1
echo "running and job name ok"

: > "${RUN_DIR}/drain"
write_status
expect draining 'build (ubuntu, "1.2")' 1
feed 1 '2026-10-12 21:09:00Z: Job build (ubuntu, "1.2") completed with result: Failed' >/dev/null
expect draining "" 0
rm -f "${RUN_DIR}/drain"
write_status
expect idle "" 0
echo "draining ok"

# run_one reads docker start's stdout. A container that dies mid-job prints
# no completed line; the slot still goes back to idle, and docker start's
# exit code is run_one's.
calls="${RUN_DIR}/calls"
# shellcheck disable=SC2317
docker() {
  printf '%s\n' "$*" >> "${calls}"
  if [[ "$1" == start ]]; then
    cat > /dev/null
    echo '2026-10-12 22:00:00Z: Listening for Jobs'
    echo '2026-10-12 22:00:09Z: Running job: test (mysql)'
    sleep 0.5
    cp "${RUN_DIR}/status.json" "${RUN_DIR}/during"
    return 7
  fi
  return 0
}
# shellcheck disable=SC2317
mint_registration_token() {
  echo test-registration-token
}
# shellcheck disable=SC2317
arm_wall_clock() {
  echo "$$"
}
# shellcheck disable=SC2317
disarm_wall_clock() {
  :
}
AAP_JOB_CPUS=6
AAP_JOB_MEMORY=12g
AAP_JOB_PIDS_LIMIT=4096
AAP_JOB_TIMEOUT_MINUTES=120
finish_job_limits
finish_runner_count
AAP_RUNNER_IMAGE=aap-crrr-runner:local
RUNNER_UID=$(id -u)
SCCACHE_HOST_DIR="${RUN_DIR}/sccache"
rm -f "${RUN_DIR}"/slot-[1-9]
rc=0
out=$(run_one 1 2>/dev/null) || rc=$?
[[ "${rc}" -eq 7 ]] || fail "run_one returned ${rc}; want docker start's 7"
[[ "${out}" == *'Running job: test (mysql)'* ]] || fail "run_one did not pass the runner output through"
[[ "$(jq -r '.state + "/" + .job' "${RUN_DIR}/during")" == "running/test (mysql)" ]] \
  || fail "status during the job was $(cat "${RUN_DIR}/during")"
[[ "$(slot_state 1)" == idle ]] || fail "slot 1 is $(slot_state 1) after its container died mid-job"
expect idle "" 0
echo "run_one job tracking ok"

# Readers only ever see a whole file: four writers race one reader.
for _ in 1 2 3 4; do
  (for _ in $(seq 1 40); do write_status; done) &
done
for _ in $(seq 1 200); do
  jq -e '.state' "${RUN_DIR}/status.json" >/dev/null 2>&1 || fail "a reader saw a partial status.json"
done
wait
if compgen -G "${RUN_DIR}/status.json.tmp.*" >/dev/null; then
  fail "a temp status file was left behind"
fi
echo "atomic write ok"

echo "manager status tests ok"
