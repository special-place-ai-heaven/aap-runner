#!/bin/bash
# repo and run_url in status.json: parsed from the job processes' environment
# (docker exec stubbed), validated strictly, retried until GITHUB_RUN_ID
# appears, tied to the job start, and cleared when the slot leaves running.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../distro/manager.sh
source "${here}/../distro/manager.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

RUN_DIR=$(mktemp -d)
trap 'rm -rf "${RUN_DIR}"' EXIT
calls="${RUN_DIR}/calls"
AAP_RUNNER_COUNT=1
AAP_JOB_CPUS=6
AAP_JOB_MEMORY=12g

valid=$'GITHUB_JOB=build\nGITHUB_REPOSITORY=octo/hello.world\nGITHUB_RUN_ID=123456\nGITHUB_SERVER_URL=https://github.com'
parse() {
  rc=0
  out=$(job_run_from_env <<< "$1") || rc=$?
}
parse "${valid}"
[[ "${rc}" -eq 0 && "${out}" == "octo/hello.world https://github.com/octo/hello.world/actions/runs/123456" ]] \
  || fail "valid set gave rc ${rc} '${out}'"
parse "${valid/https:\/\/github.com/https://github.example.com}"
[[ "${rc}" -eq 0 && -z "${out}" ]] || fail "a GHES server url was published: '${out}'"
parse "${valid/octo\/hello.world/octo/hello/x}"
[[ "${rc}" -eq 0 && -z "${out}" ]] || fail "a malformed repo was published: '${out}'"
parse "${valid/octo\/hello.world/..\/..}"
[[ "${rc}" -eq 0 && -z "${out}" ]] || fail "a ../.. repo was published: '${out}'"
parse "${valid/123456/12a}"
[[ "${rc}" -eq 0 && -z "${out}" ]] || fail "a non-numeric run id was published: '${out}'"
parse "${valid}"$'\nGITHUB_REPOSITORY=evil/repo'
[[ "${rc}" -eq 0 && -z "${out}" ]] || fail "two repositories were published: '${out}'"
parse $'GITHUB_REPOSITORY=octo/hello\nGITHUB_SERVER_URL=https://github.com'
[[ "${rc}" -eq 1 ]] || fail "no run id did not ask for a retry (rc ${rc})"
parse ""
[[ "${rc}" -eq 1 ]] || fail "no environment did not ask for a retry (rc ${rc})"
echo "env parsing ok"

# docker exec answers empty twice, then the full set. timeout runs its command.
# shellcheck disable=SC2317
timeout() {
  echo "timeout $1" >> "${calls}"
  shift
  "$@"
}
# shellcheck disable=SC2317
docker() {
  echo "docker $1 $2" >> "${calls}"
  local n
  n=$(grep -c '^docker exec' "${calls}")
  if [[ "${n}" -gt "${EMPTY_TRIES}" ]]; then
    printf '%s\n' "${ENV_OUT}"
  fi
}
# shellcheck disable=SC2317
sleep() {
  echo "sleep $*" >> "${calls}"
}
field() {
  jq -r ".$1" "${RUN_DIR}/status.json"
}

: > "${calls}"
EMPTY_TRIES=2
ENV_OUT=${valid}
set_slot_state 1 running c1 build
discover_job_run 1 c1 "$(slot_ns 1)"
[[ "$(grep -c '^docker exec c1' "${calls}")" -eq 3 && "$(grep -c '^sleep 5' "${calls}")" -eq 2 ]] \
  || fail "did not retry every 5 s until the run id appeared: $(cat "${calls}")"
[[ "$(grep -c '^timeout 10' "${calls}")" -eq 3 ]] || fail "docker exec was not bounded by timeout 10"
[[ "$(jq -r 'keys_unsorted | join(",")' "${RUN_DIR}/status.json")" == state,job,repo,run_url,busy,updated,runner_count,job_cpus,job_memory,job_io_mbps,sharing,schema,sampled_at,pool,slots ]] \
  || fail "keys: $(cat "${RUN_DIR}/status.json")"
[[ "$(field state)/$(field job)/$(field repo)/$(field run_url)" == "running/build/octo/hello.world/https://github.com/octo/hello.world/actions/runs/123456" ]] \
  || fail "status after discovery: $(cat "${RUN_DIR}/status.json")"
echo "discovery retry and status fields ok"

set_slot_state 1 idle
[[ ! -e "${RUN_DIR}/slot-1.run" && -z "$(field repo)" && -z "$(field run_url)" ]] \
  || fail "repo and run_url were not cleared when the slot finished: $(cat "${RUN_DIR}/status.json")"
echo "cleared on finish ok"

# Never found: 120 tries, 119 sleeps, nothing published, rc 0.
: > "${calls}"
EMPTY_TRIES=999
set_slot_state 1 running c1 build
discover_job_run 1 c1 "$(slot_ns 1)" || fail "discovery failed the caller"
[[ "$(grep -c '^docker exec' "${calls}")" -eq 120 && "$(grep -c '^sleep 5' "${calls}")" -eq 119 ]] \
  || fail "did not stop after 120 tries: $(cat "${calls}")"
[[ -z "$(field repo)" && -z "$(field run_url)" ]] || fail "published without a run id"
# A wrong server url publishes empty strings.
EMPTY_TRIES=0
ENV_OUT=${valid/https:\/\/github.com/https://evil.example}
discover_job_run 1 c1 "$(slot_ns 1)"
[[ -z "$(field repo)" && -z "$(field run_url)" && "$(field job)" == build ]] || fail "a wrong server url was published"
# A result for an earlier job start is never published.
ENV_OUT=${valid}
old=$(slot_ns 1)
set_slot_state 1 running c2 next
discover_job_run 1 c1 "${old}"
[[ -z "$(field repo)" ]] || fail "a stale job's repo was published"
# The newest running slot's fields win, as for job.
AAP_RUNNER_COUNT=2
discover_job_run 1 c2 "$(slot_ns 1)"
set_slot_state 2 running c3 other
[[ "$(field job)/$(field repo)" == "other/" ]] || fail "repo is not the newest job's: $(cat "${RUN_DIR}/status.json")"
echo "no run id, wrong server, stale job, newest job ok"

echo "manager job run tests ok"