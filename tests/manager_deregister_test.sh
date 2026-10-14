#!/bin/bash
# Runner deregistration with curl and docker stubbed: deregister_runner looks
# the runner up by name and DELETEs its id, treats 404 and "not listed" as
# gone, retries once, never fails the caller, and never prints the token.
# stop_pool deregisters the runners that had no job, inside its time bound.
# run_one deregisters a runner whose container ended without a job.
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
log="${RUN_DIR}/log"
err="${RUN_DIR}/err"
AAP_GITHUB_ORG=example-org

# shellcheck disable=SC2317
mint_installation_token() {
  echo test-installation-token
}
# Only the retry delay calls sleep here.
# shellcheck disable=SC2317
sleep() {
  echo "sleep $*" >> "${calls}"
}
# GET prints LIST_JSON and exits LIST_RC. DELETE prints DELETE_CODE (-w).
# Every call must carry the token on stdin, not in argv, and have timeouts.
# shellcheck disable=SC2317
curl() {
  local a hdr
  hdr=$(cat)
  for a in "$@"; do
    if [[ "${a}" == *test-installation-token* || "${a}" == *Bearer* ]]; then
      echo "TOKEN IN ARGV" >> "${calls}"
    fi
  done
  if [[ "${hdr}" == "Authorization: Bearer test-installation-token" ]]; then
    echo "stdin header" >> "${calls}"
  fi
  if [[ " $* " != *" --connect-timeout 5 "* || " $* " != *" --max-time "* ]]; then
    echo "NO TIMEOUT" >> "${calls}"
  fi
  if [[ " $* " == *" -X DELETE "* ]]; then
    echo "DELETE ${*: -1}" >> "${calls}"
    printf '%s' "${DELETE_CODE}"
    return 0
  fi
  for a in "$@"; do
    if [[ "${a}" == name=* ]]; then
      echo "GET ${a} ${*: -1}" >> "${calls}"
    fi
  done
  printf '%s' "${LIST_JSON}"
  return "${LIST_RC:-0}"
}

count() {
  grep -c "$1" "${calls}" || true
}

# dereg NAME: runs deregister_runner, keeps its output in ${out}.
dereg() {
  : > "${calls}"
  rc=0
  out=$(deregister_runner "$1" 2>&1) || rc=$?
  [[ "${rc}" -eq 0 ]] || fail "deregister_runner returned ${rc}; it must never fail the caller"
  [[ "${out}" != *test-installation-token* ]] || fail "the installation token was printed"
  [[ "$(count '^TOKEN IN ARGV')" -eq 0 ]] || fail "the token was in curl's argv"
  [[ "$(count '^NO TIMEOUT')" -eq 0 ]] || fail "a curl call has no timeout"
  [[ "$(count '^stdin header')" -eq $(($(count '^GET') + $(count '^DELETE'))) ]] \
    || fail "a curl call did not get the token on stdin: $(cat "${calls}")"
}

LIST_JSON='{"total_count":1,"runners":[{"id":42,"name":"aap-crrr-0123456789ab"}]}'
DELETE_CODE=204
dereg aap-crrr-0123456789ab
grep -qx 'GET name=aap-crrr-0123456789ab https://api.github.com/orgs/example-org/actions/runners' "${calls}" \
  || fail "the runner was not looked up by name: $(cat "${calls}")"
grep -qx 'DELETE https://api.github.com/orgs/example-org/actions/runners/42' "${calls}" \
  || fail "DELETE was not called with id 42: $(cat "${calls}")"
[[ "$(count '^DELETE')" -eq 1 && "$(count '^sleep')" -eq 0 ]] || fail "a found runner was retried: $(cat "${calls}")"
echo "found runner deleted by id ok"

DELETE_CODE=404
dereg aap-crrr-0123456789ab
[[ "$(count '^DELETE')" -eq 1 && "$(count '^sleep')" -eq 0 ]] || fail "a 404 was retried: $(cat "${calls}")"
[[ "${out}" == *'HTTP 404'* ]] || fail "a 404 was not treated as already gone: ${out}"
echo "404 is already gone ok"

LIST_JSON='{"total_count":1,"runners":[{"id":7,"name":"aap-crrr-0123456789abX"}]}'
dereg aap-crrr-0123456789ab
[[ "$(count '^DELETE')" -eq 0 ]] || fail "a runner with another name was deleted: $(cat "${calls}")"
[[ "${out}" == *'is not registered'* ]] || fail "an unlisted runner was not reported gone: ${out}"
echo "unlisted runner is already gone ok"

LIST_JSON='{"total_count":1,"runners":[{"id":42,"name":"aap-crrr-0123456789ab"}]}'
DELETE_CODE=500
dereg aap-crrr-0123456789ab
[[ "$(count '^DELETE')" -eq 2 ]] || fail "a 500 was not retried exactly once: $(cat "${calls}")"
grep -qx 'sleep 5' "${calls}" || fail "the retry did not wait 5 s: $(cat "${calls}")"
[[ "${out}" == *'returned HTTP 500'* && "${out}" == *'could not deregister runner aap-crrr-0123456789ab'* ]] \
  || fail "the failed deregistration was not logged: ${out}"
LIST_JSON=''
LIST_RC=22
dereg aap-crrr-0123456789ab
[[ "$(count '^GET')" -eq 2 && "$(count '^DELETE')" -eq 0 ]] || fail "a failed lookup was not retried once: $(cat "${calls}")"
[[ "${out}" == *'could not deregister'* ]] || fail "the failed lookup was not logged: ${out}"
LIST_RC=0
echo "500 and lookup failure retried once, logged, rc 0 ok"
[[ "$(declare -f deregister_runner_once | grep -c 'per_page' || true)" -eq 0 ]] || fail "the runners GET still sets per_page"

# Both token POSTs: the JWT and the installation token go on stdin, with
# timeouts. A throwaway key signs the JWT.
# Re-source for the real mint_installation_token; keep this test's RUN_DIR.
saved_run_dir=${RUN_DIR}
# shellcheck source=SCRIPTDIR/../distro/manager.sh
source "${here}/../distro/manager.sh"
RUN_DIR=${saved_run_dir}
AAP_GITHUB_ORG=example-org
key="${RUN_DIR}/app.pem"
openssl genrsa -out "${key}" 2048 2>/dev/null
AAP_GITHUB_APP_PRIVATE_KEY_PATH=${key}
AAP_GITHUB_APP_ID=12345
AAP_GITHUB_APP_INSTALLATION_ID=67890
# shellcheck disable=SC2317
curl() {
  local a hdr url="${*: -1}"
  hdr=$(cat)
  for a in "$@"; do
    if [[ "${a}" == *Bearer* || "${a}" == *test-installation-token* ]]; then
      echo "TOKEN IN ARGV" >> "${calls}"
    fi
  done
  if [[ " $* " != *" --connect-timeout 5 --max-time 15 "* ]]; then
    echo "NO TIMEOUT ${url}" >> "${calls}"
  fi
  echo "POST ${url} ${hdr}" >> "${calls}"
  case "${url}" in
    */access_tokens) echo '{"token":"test-installation-token"}' ;;
    */registration-token) echo '{"token":"test-registration-token"}' ;;
  esac
}
: > "${calls}"
got=$(mint_registration_token) || fail "mint_registration_token failed"
[[ "${got}" == test-registration-token ]] || fail "registration token was '${got}'"
grep -q '^POST https://api.github.com/app/installations/67890/access_tokens Authorization: Bearer [A-Za-z0-9_-]*[.][A-Za-z0-9_-]*[.][A-Za-z0-9_-]*$' "${calls}" \
  || fail "the JWT did not reach the access_tokens POST on stdin: $(cat "${calls}")"
grep -qx 'POST https://api.github.com/orgs/example-org/actions/runners/registration-token Authorization: Bearer test-installation-token' "${calls}" \
  || fail "the installation token did not reach the registration-token POST on stdin: $(cat "${calls}")"
if grep -q '^TOKEN IN ARGV\|^NO TIMEOUT' "${calls}"; then
  fail "a token POST has the token in argv or no timeout: $(cat "${calls}")"
fi
echo "token POSTs send the token on stdin with timeouts ok"

unset -f sleep curl

# The runner name is aap-crrr-<container hostname>.
# shellcheck disable=SC2317
docker() {
  echo "docker $*" >> "${log}"
  if [[ "$1" == inspect ]]; then
    echo "host${4##*-}"
  fi
}
# shellcheck disable=SC2317,SC2329
remove_job_containers() {
  echo removed >> "${log}"
}
# The ghost reap has its own test; here it would reach the network.
# shellcheck disable=SC2317
reap_ghost_runners() {
  :
}
# Each deregistration hangs, so only the budget ends it.
# shellcheck disable=SC2317
deregister_runner() {
  echo "deregister $1" >> "${log}"
  exec sleep 60
}
# Slot 1 listens, slot 2 runs a job, slot 3 is registering.
# shellcheck disable=SC2317
slot_loop() {
  trap - EXIT TERM INT
  case "$1" in
    1) set_slot_state 1 listening aap-crrr-1-a ;;
    2) set_slot_state 2 running aap-crrr-2-b build ;;
    3) set_slot_state 3 starting aap-crrr-3-c ;;
  esac
  exec sleep 30
}
: > "${log}"
AAP_RUNNER_COUNT=3
DEREGISTER_BUDGET_SECONDS=1
(run_pool) 2> "${err}" &
pool=$!
for _ in $(seq 1 50); do
  [[ -f "${RUN_DIR}/slot-1" && -f "${RUN_DIR}/slot-2" && -f "${RUN_DIR}/slot-3" ]] && break
  command sleep 0.1
done
started=${SECONDS}
kill -TERM "${pool}"
rc=0
wait "${pool}" || rc=$?
elapsed=$((SECONDS - started))
[[ "${rc}" -eq 143 ]] || fail "SIGTERM exit was ${rc}; want 143"
[[ "${elapsed}" -le 4 ]] || fail "stop took ${elapsed}s; the deregistration budget is 1s"
[[ "$(grep -E '^(removed|deregister )' "${log}" | sort | tr '\n' ' ')" == "deregister aap-crrr-hosta deregister aap-crrr-hostc removed " ]] \
  || fail "stop did not deregister exactly the slots without a job: $(cat "${log}")"
[[ "$(grep -nx removed "${log}" | cut -d: -f1)" -lt "$(grep -n '^deregister' "${log}" | head -1 | cut -d: -f1)" ]] \
  || fail "stop deregistered before removing the containers: $(cat "${log}")"
grep -q 'deregistration took over 1s; stopped it' "${err}" || fail "the over-budget deregistration was not logged: $(cat "${err}")"
echo "stop_pool deregisters runners without a job within its bound ok"

# SIGTERM while a drain's deregistration hangs: stop_pool kills that batch,
# runs the name again, and the stop still ends inside the budget.
# shellcheck disable=SC2317
slot_loop() {
  trap - EXIT TERM INT
  set_slot_state 1 listening aap-crrr-1-a
  exec sleep 30
}
: > "${log}"
: > "${err}"
rm -f "${RUN_DIR}"/slot-[1-9]
AAP_RUNNER_COUNT=1
DEREGISTER_BUDGET_SECONDS=2
STATUS_TICK_SECONDS=0.2
(run_pool) 2> "${err}" &
pool=$!
for _ in $(seq 1 50); do
  [[ -f "${RUN_DIR}/slot-1" ]] && break
  command sleep 0.1
done
: > "${RUN_DIR}/drain"
for _ in $(seq 1 50); do
  grep -qx 'deregister aap-crrr-hosta' "${log}" && break
  command sleep 0.1
done
grep -qx 'deregister aap-crrr-hosta' "${log}" || fail "the drain did not start deregistering: $(cat "${log}") $(cat "${err}")"
started=${SECONDS}
kill -TERM "${pool}"
rc=0
wait "${pool}" || rc=$?
elapsed=$((SECONDS - started))
rm -f "${RUN_DIR}/drain"
[[ "${rc}" -eq 143 ]] || fail "SIGTERM during the drain exited ${rc}; want 143: $(cat "${err}")"
[[ "${elapsed}" -le 4 ]] || fail "SIGTERM during the drain took ${elapsed}s; the budget is 2s"
[[ "$(grep -cx 'deregister aap-crrr-hosta' "${log}")" -eq 2 ]] \
  || fail "stop_pool did not take over the interrupted deregistration: $(cat "${log}")"
echo "sigterm during a hung drain deregistration stays in budget ok"

# run_one: the wall clock stopped a listener that never got a job.
# shellcheck source=SCRIPTDIR/../distro/manager.sh
source "${here}/../distro/manager.sh"
RUN_DIR=${log%/log}
: > "${log}"
# shellcheck disable=SC2317
docker() {
  echo "docker $*" >> "${log}"
  case "$1" in
    inspect) echo "host${4##*-}" ;;
    start)
      cat > /dev/null
      echo '2026-10-12 22:00:00Z: Listening for Jobs'
      return 143
      ;;
  esac
}
# shellcheck disable=SC2317
deregister_runner() {
  echo "deregister $1" >> "${log}"
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
AAP_RUNNER_COUNT=1
finish_runner_count
AAP_RUNNER_IMAGE=aap-crrr-runner:local
RUNNER_UID=$(id -u)
SCCACHE_HOST_DIR="${RUN_DIR}/sccache"
rc=0
run_one 1 > /dev/null 2>&1 || rc=$?
[[ "${rc}" -eq 143 ]] || fail "run_one returned ${rc}; want docker start's 143"
grep -q '^deregister aap-crrr-host[0-9]*$' "${log}" || fail "a runner that ended without a job was not deregistered: $(cat "${log}")"
[[ "$(grep -n '^docker rm -f -v' "${log}" | cut -d: -f1)" -lt "$(grep -n '^deregister' "${log}" | cut -d: -f1)" ]] \
  || fail "run_one deregistered before removing the container"
[[ "$(slot_state 1)" == idle ]] || fail "slot 1 is $(slot_state 1) after its listener ended"
echo "run_one deregisters a runner that ended without a job ok"

echo "manager deregister tests ok"
