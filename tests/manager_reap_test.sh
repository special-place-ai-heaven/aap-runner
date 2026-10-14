#!/bin/bash
# Ghost runner reap with curl and docker stubbed: the runner list is paged,
# only offline, idle aap-crrr-* runners with no container here are deleted,
# 404 is gone, the token never reaches argv, --reap starts no pool, and the
# pool loop reaps at start and then only every REAP_INTERVAL_SECONDS.
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
calls="${RUN_DIR}/calls"
log="${RUN_DIR}/log"
AAP_GITHUB_ORG=example-org
AAP_RUNNER_BASE_LABEL=fresh

# shellcheck disable=SC2317
mint_installation_token() {
  echo test-installation-token
}
# GET prints PAGE_<n> and exits LIST_RC. DELETE prints 404 for id 21, else 204.
# shellcheck disable=SC2317
curl() {
  local a hdr page="" url="${*: -1}"
  hdr=$(cat)
  for a in "$@"; do
    if [[ "${a}" == *test-installation-token* || "${a}" == *Bearer* ]]; then
      echo "TOKEN IN ARGV" >> "${calls}"
    fi
    [[ "${a}" == page=* ]] && page=${a#page=}
  done
  [[ "${hdr}" == "Authorization: Bearer test-installation-token" ]] && echo "stdin header" >> "${calls}"
  if [[ " $* " != *" --connect-timeout 5 "* || " $* " != *" --max-time "* ]]; then
    echo "NO TIMEOUT" >> "${calls}"
  fi
  if [[ " $* " == *" -X DELETE "* ]]; then
    echo "DELETE ${url##*/}" >> "${calls}"
    if [[ "${url}" == */21 ]]; then printf 404; else printf 204; fi
    return 0
  fi
  [[ " $* " == *" per_page=100 "* ]] || echo "NO PER_PAGE" >> "${calls}"
  echo "GET page=${page} ${url}" >> "${calls}"
  local var="PAGE_${page}"
  printf '%s' "${!var:-}"
  return "${LIST_RC:-0}"
}
# ps -aq lists container c1; inspect maps c1 -> livehost1, slotname -> slothost.
# shellcheck disable=SC2317
docker() {
  echo "docker $*" >> "${log}"
  case "$1" in
    ps) [[ "${DOCKER_PS_RC:-0}" -eq 0 ]] || return 1; echo c1 ;;
    inspect)
      case "${*: -1}" in
        c1) echo livehost1 ;;
        slotname) echo slothost ;;
        *) return 1 ;;
      esac
      ;;
  esac
}
count() {
  grep -c "$1" "${calls}" || true
}

# Page 1 is exactly 100 runners, so page 2 is read; page 2 has 2, so no page 3.
# Page 1: 96 online, a ghost (11), a busy offline one (12), another prefix
# (13), and the runner of live container c1 (14). Page 2: a ghost that is
# already gone (21, 404), the runner of slot 1's container (22), another
# host's runner labelled crrr65734 (23), and one with no labels (24). All
# but 23 and 24 carry this host's base label, fresh.
PAGE_1=$(jq -cn --argjson l '[{"name":"self-hosted"},{"name":"fresh"}]' '{runners: ([range(0; 96)] | map({id: (1000 + .), name: ("aap-crrr-on" + tostring), status: "online", busy: false}))
  + [{id: 11, name: "aap-crrr-ghost1", status: "offline", busy: false, labels: $l},
     {id: 12, name: "aap-crrr-busy1", status: "offline", busy: true, labels: $l},
     {id: 13, name: "other-runner", status: "offline", busy: false, labels: $l},
     {id: 14, name: "aap-crrr-livehost1", status: "offline", busy: false, labels: $l}]}')
# curl reads it as ${!var}.
# shellcheck disable=SC2034
PAGE_2='{"runners":[{"id":21,"name":"aap-crrr-ghost2","status":"offline","busy":false,"labels":[{"name":"self-hosted"},{"name":"fresh"}]},{"id":22,"name":"aap-crrr-slothost","status":"offline","busy":false,"labels":[{"name":"self-hosted"},{"name":"fresh"}]},{"id":23,"name":"aap-crrr-otherhost","status":"offline","busy":false,"labels":[{"name":"self-hosted"},{"name":"crrr65734"}]},{"id":24,"name":"aap-crrr-nolabels","status":"offline","busy":false}]}'
[[ "$(jq '.runners | length' <<< "${PAGE_1}")" -eq 100 ]] || fail "page 1 fixture is not 100 runners"
printf 'listening 1 slotname\n' > "${RUN_DIR}/slot-1"

: > "${calls}"
: > "${log}"
rc=0
out=$(reap_ghost_runners 2>&1) || rc=$?
[[ "${rc}" -eq 0 ]] || fail "reap_ghost_runners returned ${rc}"
[[ "$(grep '^GET' "${calls}" | tr '\n' ' ')" == "GET page=1 https://api.github.com/orgs/example-org/actions/runners GET page=2 https://api.github.com/orgs/example-org/actions/runners " ]] \
  || fail "the list was not read as pages 1 and 2 only: $(cat "${calls}")"
[[ "$(grep '^DELETE' "${calls}" | tr '\n' ' ')" == "DELETE 11 DELETE 21 " ]] \
  || fail "deleted other than the two ghosts 11 and 21: $(cat "${calls}")"
[[ "${out}" == *'reaped 2 ghost runners'* ]] || fail "no summary line: ${out}"
[[ "${out}" == *'deregistered runner aap-crrr-ghost2 (id 21, HTTP 404)'* ]] || fail "404 was not taken as gone: ${out}"
[[ "${out}" != *test-installation-token* ]] || fail "the token was printed"
[[ "$(count '^TOKEN IN ARGV\|^NO TIMEOUT\|^NO PER_PAGE')" -eq 0 ]] || fail "a call had the token in argv, no timeout, or no per_page: $(cat "${calls}")"
[[ "$(count '^stdin header')" -eq 4 ]] || fail "not every call got the token on stdin: $(cat "${calls}")"
echo "pagination, prefix, base label, online, busy, live and slot containers, 404 ok"
# No base label: nothing is listed or deleted.
: > "${calls}"
AAP_RUNNER_BASE_LABEL=""
out=$(reap_ghost_runners 2>&1) || fail "reap failed the caller without a base label"
AAP_RUNNER_BASE_LABEL=fresh
[[ ! -s "${calls}" && "${out}" == *'no base label'* ]] || fail "reaped without a base label: ${out}"

# The list is read before docker, so a runner registered after the snapshot is not reaped.
[[ "$(grep -n '^docker ps' "${log}" | head -1 | cut -d: -f1)" -eq 1 ]] || fail "docker was read before the list: $(cat "${log}")"
# No docker snapshot: nothing is deleted.
: > "${calls}"
DOCKER_PS_RC=1
out=$(reap_ghost_runners 2>&1) || fail "reap failed the caller when docker ps failed"
DOCKER_PS_RC=0
[[ "$(count '^DELETE')" -eq 0 && "${out}" == *'docker ps failed'* ]] || fail "reaped without a docker snapshot: ${out}"
# A failed list: nothing is deleted.
: > "${calls}"
LIST_RC=22
out=$(reap_ghost_runners 2>&1) || fail "reap failed the caller when the list failed"
LIST_RC=0
[[ "$(count '^DELETE')" -eq 0 && "${out}" == *'could not list runners'* ]] || fail "reaped after a failed list: ${out}"
# Ten pages at most.
PAGE_FULL=$(jq -cn '{runners: [range(0; 100)] | map({id: (1000 + .), name: "x", status: "online", busy: false})}')
for i in $(seq 1 11); do printf -v "PAGE_${i}" '%s' "${PAGE_FULL}"; done
: > "${calls}"
reap_ghost_runners > /dev/null 2>&1
[[ "$(count '^GET')" -eq 10 ]] || fail "the list was not capped at 10 pages: $(count '^GET')"
echo "no docker, failed list, and 10-page cap delete nothing ok"

# tick_reap: no installation id, no reap; then one pass per interval; none
# while draining; a pass over the budget is stopped.
# shellcheck disable=SC2317
reap_ghost_runners() {
  echo reap >> "${log}"
}
reaps() {
  grep -cx reap "${log}" || true
}
settle() {
  [[ -z "${REAP_PID}" ]] || wait "${REAP_PID}" 2>/dev/null || true
}
: > "${log}"
AAP_GITHUB_APP_INSTALLATION_ID=""
REAP_NEXT=""
tick_reap; settle
[[ "$(reaps)" -eq 0 ]] || fail "reaped without an installation id"
AAP_GITHUB_APP_INSTALLATION_ID=67890
REAP_INTERVAL_SECONDS=600
# A pool that never reaped reaps on its first tick, whatever the clock reads:
# here it has stepped back to before the epoch the gate would compare with.
eval "real_$(declare -f now_s)"
[[ "$(real_now_s)" =~ ^[0-9]+$ ]] || fail "now_s is not whole seconds: $(real_now_s)"
fake_now=-5
# shellcheck disable=SC2317
now_s() { echo "${fake_now}"; }
tick_reap; settle
[[ "$(reaps)" -eq 1 ]] || fail "the first tick did not reap"
tick_reap; settle
tick_reap; settle
[[ "$(reaps)" -eq 1 ]] || fail "a tick inside the interval reaped again"
[[ "${REAP_NEXT}" -eq 595 ]] || fail "next reap is at ${REAP_NEXT}; want -5 + 600"
fake_now=594
tick_reap; settle
[[ "$(reaps)" -eq 1 ]] || fail "a tick 1s before the interval reaped"
fake_now=595
tick_reap; settle
[[ "$(reaps)" -eq 2 ]] || fail "a tick after the interval did not reap"
# shellcheck disable=SC2317
now_s() { real_now_s; }
REAP_NEXT=""
: > "${RUN_DIR}/drain"
tick_reap; settle
rm -f "${RUN_DIR}/drain"
[[ "$(reaps)" -eq 2 ]] || fail "reaped while draining"
# shellcheck disable=SC2317
reap_ghost_runners() {
  exec sleep 30
}
REAP_NEXT=""
DEREGISTER_BUDGET_SECONDS=0
tick_reap
slow=${REAP_PID}
REAP_NEXT=$(($(now_s) + 600))
tick_reap 2> "${RUN_DIR}/tickerr"
out=$(cat "${RUN_DIR}/tickerr")
kill -0 "${slow}" 2>/dev/null && fail "a reap over the budget was not stopped"
[[ -z "${REAP_PID}" ]] || fail "the stopped reap was not cleared"
[[ "${out}" == *'ghost reap stopped'* ]] || fail "the stopped reap was not logged: ${out}"
DEREGISTER_BUDGET_SECONDS=25
echo "tick reap gating, drain, and budget ok"

# run_pool reaps once at start, then not again inside the interval.
# shellcheck disable=SC2317
reap_ghost_runners() {
  echo reap >> "${log}"
}
# shellcheck disable=SC2317
slot_loop() {
  trap - EXIT TERM INT
  exec sleep 30
}
# shellcheck disable=SC2317,SC2329
remove_job_containers() {
  :
}
: > "${log}"
REAP_PID=""
REAP_NEXT=""
AAP_RUNNER_COUNT=1
STATUS_TICK_SECONDS=0.2
(run_pool) 2> /dev/null &
pool=$!
for _ in $(seq 1 50); do
  [[ "$(reaps)" -ge 1 ]] && break
  sleep 0.1
done
sleep 1
kill -TERM "${pool}"
wait "${pool}" || true
[[ "$(reaps)" -eq 1 ]] || fail "run_pool reaped $(reaps) times in ~1s; want once at start"
echo "run_pool reaps once at start ok"

# --reap: one pass, exit 0, no pool start and no container created.
# shellcheck disable=SC2317
id() {
  echo 0
}
# shellcheck disable=SC2317
load_config() {
  echo load_config >> "${log}"
}
# shellcheck disable=SC2317
check_key() {
  :
}
# shellcheck disable=SC2317
run_pool() {
  echo run_pool >> "${log}"
}
: > "${log}"
rc=0
(main --reap) > /dev/null 2>&1 || rc=$?
[[ "${rc}" -eq 0 ]] || fail "--reap exited ${rc}"
[[ "$(reaps)" -eq 1 ]] || fail "--reap did not reap once: $(cat "${log}")"
grep -q '^run_pool\|^docker create\|^docker rm' "${log}" && fail "--reap started the pool or touched containers: $(cat "${log}")"
rc=0
(main --reap-now) > /dev/null 2>&1 || rc=$?
[[ "${rc}" -eq 2 ]] || fail "an unknown argument exited ${rc}; want 2"
echo "--reap runs one pass and starts no pool ok"

echo "manager reap tests ok"