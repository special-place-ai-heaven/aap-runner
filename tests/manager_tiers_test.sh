#!/bin/bash
# Two Linux tiers in the manager (R1 step 2): AAP_LINUX_HEAVY_COUNT (0..2) and
# AAP_LINUX_LIGHT_COUNT (0..10) in place of AAP_RUNNER_COUNT. The tier is the
# slot number (heavy 1..H, light 3..2+L), so a 1+2 pool runs slots 1, 3, 4.
# Covers the grammar and its refusals, POOL_SLOTS, status.json, the docker
# create argv per tier in slice and fixed mode, the labels line, the IO and
# zccache split over H+L, --check-limits, and that run_pool, drain, stop,
# usage and the ghost reap reach slots above 5 (slot-10..12 files).
# Sources the manager; docker, curl and the slot loop are stubbed.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../distro/manager.sh
source "${here}/../distro/manager.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: got '$1', want '$2'"
}

work=$(mktemp -d)
RUN_DIR=${work}/run
mkdir -p "${RUN_DIR}"
trap 'rm -rf "${work}"' EXIT
log="${work}/log"
err="${work}/err"
calls="${work}/calls"
create_argv="${work}/create_argv"
: > "${log}"

# tier_conf HEAVY LIGHT: the load_config limit steps for a pool of 28 cpus and
# 80g with the live Fresh labels, then the tier split. HEAVY or LIGHT may be
# "-" for absent. A refusal leaves its message in ${err}.
tier_conf() {
  unset AAP_RUNNER_COUNT AAP_LINUX_HEAVY_COUNT AAP_LINUX_LIGHT_COUNT
  [[ "$1" == "-" ]] || AAP_LINUX_HEAVY_COUNT=$1
  [[ "$2" == "-" ]] || AAP_LINUX_LIGHT_COUNT=$2
  AAP_JOB_CPUS=${POOL_CPUS:-28}
  AAP_JOB_MEMORY=${POOL_MEMORY:-80g}
  AAP_JOB_PIDS_LIMIT=4096
  AAP_JOB_TIMEOUT_MINUTES=120
  AAP_JOB_IO_PERCENT=90
  AAP_POOL_SHARING=${SHARING:-slice}
  AAP_RUNNER_BASE_LABEL=${BASE:-fresh}
  AAP_RUNNER_EXTRA_LABELS=${EXTRA:-}
  AAP_RUNNER_LABELS=""
  POOL_SLOTS=()
  finish_job_limits 2>> "${err}" && finish_runner_count 2>> "${err}"
}

accepted() {
  : > "${err}"
  tier_conf "$1" "$2" || fail "tiers $1+$2 were refused: $(cat "${err}")"
}

refused() {
  local want="$1"
  shift
  : > "${err}"
  if tier_conf "$@"; then
    fail "tiers $1+$2 were accepted"
  fi
  grep -qF "refusing: ${want}" "${err}" || fail "tiers $1+$2 refusal does not say '${want}': $(cat "${err}")"
}

# --- Grammar ---------------------------------------------------------------
accepted 2 10
assert_eq "${AAP_RUNNER_COUNT}" 12 "2+10 count"
assert_eq "${POOL_SLOTS[*]}" "1 2 3 4 5 6 7 8 9 10 11 12" "2+10 slots"
accepted 1 0
assert_eq "${AAP_RUNNER_COUNT}" 1 "1+0 count"
assert_eq "${POOL_SLOTS[*]}" "1" "1+0 slots"
accepted 0 1
assert_eq "${AAP_RUNNER_COUNT}" 1 "0+1 count"
assert_eq "${POOL_SLOTS[*]}" "3" "0+1 slots"
accepted 1 2
assert_eq "${AAP_RUNNER_COUNT}" 3 "1+2 count"
assert_eq "${POOL_SLOTS[*]}" "1 3 4" "1+2 slots"
accepted 0 3
assert_eq "${POOL_SLOTS[*]}" "3 4 5" "0+3 slots"
# The live Fresh conf carries EXTRA=heavy; it stays valid and is ignored.
EXTRA=heavy accepted 1 1
echo "tier grammar and slots ok"

refused "AAP_LINUX_HEAVY_COUNT=3 is not 0..2" 3 1
refused "AAP_LINUX_LIGHT_COUNT=11 is not 0..10" 1 11
refused "AAP_LINUX_HEAVY_COUNT=1.0 is not 0..2" 1.0 1
refused "AAP_LINUX_LIGHT_COUNT=1.0 is not 0..10" 1 1.0
refused "AAP_LINUX_HEAVY_COUNT= is not 0..2" "" 1
refused "AAP_LINUX_LIGHT_COUNT= is not 0..10" 1 ""
refused "AAP_LINUX_HEAVY_COUNT=-1 is not 0..2" -1 1
refused "AAP_LINUX_LIGHT_COUNT=01 is not 0..10" 1 01
refused "AAP_LINUX_HEAVY_COUNT and AAP_LINUX_LIGHT_COUNT must both be set" 1 -
refused "AAP_LINUX_HEAVY_COUNT and AAP_LINUX_LIGHT_COUNT must both be set" - 2
refused "AAP_LINUX_HEAVY_COUNT and AAP_LINUX_LIGHT_COUNT cannot both be 0" 0 0
# A tier key beside AAP_RUNNER_COUNT, from either file, is refused.
: > "${err}"
tier_conf 1 2 || true
AAP_RUNNER_COUNT=3
if finish_runner_count 2>> "${err}"; then
  fail "a tier key beside AAP_RUNNER_COUNT was accepted"
fi
grep -qF "refusing: AAP_LINUX_HEAVY_COUNT and AAP_LINUX_LIGHT_COUNT cannot be combined with AAP_RUNNER_COUNT" "${err}" \
  || fail "no combination refusal: $(cat "${err}")"
BASE=crrr refused "tiers need AAP_RUNNER_BASE_LABEL=fresh" 1 1
EXTRA=other refused "tiers allow AAP_RUNNER_EXTRA_LABELS only empty or heavy" 1 1
EXTRA=heavy,other refused "tiers allow AAP_RUNNER_EXTRA_LABELS only empty or heavy" 1 1
# 2*20 + 10*3 = 70 GiB of reservations against a 60 GiB pool, in both modes.
POOL_MEMORY=60g refused "tier reservations 70g exceed AAP_JOB_MEMORY=60g" 2 10
POOL_MEMORY=60g SHARING=fixed refused "tier reservations 70g exceed AAP_JOB_MEMORY=60g" 2 10
POOL_MEMORY=70g accepted 2 10
POOL_MEMORY=61440m refused "tier reservations 70g exceed AAP_JOB_MEMORY=61440m" 2 10
POOL_MEMORY=72g accepted 2 10
echo "tier refusals ok"

# An untiered pool still ignores the tier machinery.
unset AAP_LINUX_HEAVY_COUNT AAP_LINUX_LIGHT_COUNT AAP_RUNNER_COUNT
AAP_RUNNER_COUNT=3
finish_runner_count
assert_eq "${POOL_SLOTS[*]}" "1 2 3" "untiered slots"
assert_eq "$(slot_tier 2)" "" "untiered slot tier"
echo "untiered slots ok"

# --- Config keys -----------------------------------------------------------
unset AAP_LINUX_HEAVY_COUNT AAP_LINUX_LIGHT_COUNT
apply_config_line "AAP_LINUX_HEAVY_COUNT=2"
apply_config_line "AAP_LINUX_LIGHT_COUNT=10"
assert_eq "${AAP_LINUX_HEAVY_COUNT}/${AAP_LINUX_LIGHT_COUNT}" "2/10" "config lines"
echo "config keys ok"

# --- Tier of a slot, labels, the log line -----------------------------------
accepted 1 2
assert_eq "$(slot_tier 1)" heavy "slot 1"
assert_eq "$(slot_tier 2)" heavy "slot 2"
assert_eq "$(slot_tier 3)" light "slot 3"
assert_eq "$(slot_tier 12)" light "slot 12"
assert_eq "$(slot_tier "")" "" "empty slot"
assert_eq "${AAP_LABELS_HEAVY}" "self-hosted,linux,x64,fresh,heavy" "heavy constant"
assert_eq "${AAP_LABELS_LIGHT}" "self-hosted,linux,x64,fresh,light" "light constant"
assert_eq "$(slot_labels 1)" "self-hosted,linux,x64,fresh,heavy" "heavy labels"
assert_eq "$(slot_labels 4)" "self-hosted,linux,x64,fresh,light" "light labels"
assert_eq "$(log_runner_labels 1)" "slot 1: runner labels: self-hosted,linux,x64,fresh,heavy" "heavy log line"
assert_eq "$(log_runner_labels 4)" "slot 4: runner labels: self-hosted,linux,x64,fresh,light" "light log line"
finish_runner_labels
assert_eq "${AAP_RUNNER_LABELS}" "self-hosted,linux,fresh" "tiered pool-level labels"
# Untiered: no slot prefix, the line the tray and the journal already show.
unset AAP_LINUX_HEAVY_COUNT AAP_LINUX_LIGHT_COUNT
AAP_RUNNER_COUNT=2
AAP_RUNNER_BASE_LABEL=fresh AAP_RUNNER_EXTRA_LABELS=heavy AAP_RUNNER_LABELS=""
finish_runner_labels
assert_eq "$(slot_labels 1)" "self-hosted,linux,fresh,heavy" "untiered slot labels"
assert_eq "$(log_runner_labels 1)" "runner labels: self-hosted,linux,fresh,heavy" "untiered log line"
assert_eq "$(log_runner_labels)" "runner labels: self-hosted,linux,fresh,heavy" "untiered log line, no slot"
echo "tier labels ok"

# --- status.json: the slot number carries the tier ---------------------------
accepted 1 2
write_status
[[ "$(jq -c '[.runner_count, .schema, [.slots[].slot]]' "${RUN_DIR}/status.json")" == '[3,4,[1,3,4]]' ]] \
  || fail "1+2 status: $(cat "${RUN_DIR}/status.json")"
[[ "$(jq '[.. | objects | has("tier")] | any' "${RUN_DIR}/status.json")" == false ]] \
  || fail "status.json grew a tier key: $(cat "${RUN_DIR}/status.json")"
[[ "$(jq -r 'keys_unsorted | join(",")' "${RUN_DIR}/status.json")" == "state,job,repo,run_url,busy,updated,runner_count,job_cpus,job_memory,job_io_mbps,sharing,schema,sampled_at,pool,slots,work_disk_gib,work_disk_free_gb,work_disk_floor_gb,cleaning" ]] \
  || fail "status.json keys changed: $(cat "${RUN_DIR}/status.json")"
printf 'running 5 aap-crrr-4-1-1 build\n' > "${RUN_DIR}/slot-4"
write_status
[[ "$(jq -c '[.slots[] | [.slot, .state]]' "${RUN_DIR}/status.json")" == '[[1,"idle"],[3,"idle"],[4,"running"]]' ]] \
  || fail "slot 4 is not reported by number: $(cat "${RUN_DIR}/status.json")"
[[ "$(jq -r '.busy' "${RUN_DIR}/status.json")" == 1 ]] || fail "slot 4's job is not counted busy"
rm -f "${RUN_DIR}/slot-4"
accepted 2 10
write_status
[[ "$(jq -c '[.runner_count, (.slots | length), .slots[-1].slot]' "${RUN_DIR}/status.json")" == '[12,12,12]' ]] \
  || fail "2+10 status: $(cat "${RUN_DIR}/status.json")"
rm -f "${RUN_DIR}"/status.json
echo "status.json slots ok"

# --- docker create argv per tier ---------------------------------------------
# shellcheck disable=SC2317
docker() {
  printf '%s\n' "$*" >> "${calls}"
  case "$1" in
    create) printf '%s\n' "$@" > "${create_argv}" ;;
    start) cat > /dev/null ;;
  esac
  return 0
}
# shellcheck disable=SC2317
mint_registration_token() { echo test-registration-token; }
# shellcheck disable=SC2317
arm_wall_clock() { echo "$$"; }
# shellcheck disable=SC2317
disarm_wall_clock() { :; }

AAP_GITHUB_ORG=example-org
AAP_RUNNER_GROUP=aap-crrr
AAP_WORK_DISK_GIB=100
AAP_DISK_FLOOR_GB=55
AAP_RUNNER_IMAGE=aap-crrr-runner:local
IO_DEVICE=""

create() {
  : > "${calls}"
  rm -f "${create_argv}"
  run_one "$1" > "${work}/run_one.out" 2>&1 || fail "run_one $1 failed: $(cat "${work}/run_one.out")"
  mapfile -t argv < "${create_argv}"
}
pair() {
  local i
  for ((i = 0; i < ${#argv[@]} - 1; i++)); do
    [[ "${argv[i]}" == "$1" && "${argv[i + 1]}" == "$2" ]] && return 0
  done
  fail "docker create argv has no '$1 $2': ${argv[*]}"
}
lacks() {
  local a
  for a in "${argv[@]}"; do
    [[ "${a}" != "$1" ]] || fail "docker create argv has '$1': ${argv[*]}"
  done
}

# Slice: the container may use the whole pool; the reservation is the soft share.
accepted 1 2
create 1
pair --cgroup-parent aap-runner-pool.slice
pair --memory 80g
pair --memory-swap 80g
pair --memory-reservation 20g
pair --cpus 28
pair --cpu-shares 2048
pair --label aap-crrr-slot=1
pair --env AAP_RUNNER_LABELS=self-hosted,linux,x64,fresh,heavy
grep -qx 'slot 1: runner labels: self-hosted,linux,x64,fresh,heavy' "${work}/run_one.out" || fail "heavy log line: $(cat "${work}/run_one.out")"
create 4
pair --cgroup-parent aap-runner-pool.slice
pair --memory 8g
pair --memory-swap 8g
pair --memory-reservation 3g
pair --cpus 4
pair --cpu-shares 512
pair --label aap-crrr-slot=4
pair --env AAP_RUNNER_LABELS=self-hosted,linux,x64,fresh,light
[[ "${argv[-1]}" == aap-crrr-runner:local ]] || fail "image is not the last argument"
echo "slice argv per tier ok"

# Fixed: the caps equal the reservations, so the pool never overcommits memory.
SHARING=fixed accepted 1 2
create 1
lacks --cgroup-parent
pair --memory 20g
pair --memory-swap 20g
pair --memory-reservation 20g
pair --cpus 8
pair --cpu-shares 2048
pair --env AAP_RUNNER_LABELS=self-hosted,linux,x64,fresh,heavy
create 3
lacks --cgroup-parent
pair --memory 3g
pair --memory-swap 3g
pair --memory-reservation 3g
pair --cpus 4
pair --cpu-shares 512
pair --env AAP_RUNNER_LABELS=self-hosted,linux,x64,fresh,light
# Every slot of a full pool: the fixed memory caps sum to the reservation total.
SHARING=fixed POOL_MEMORY=70g accepted 2 10
total=0
for s in "${POOL_SLOTS[@]}"; do
  create "${s}"
  for ((i = 0; i < ${#argv[@]} - 1; i++)); do
    if [[ "${argv[i]}" == --memory ]]; then
      mem=${argv[i + 1]}
      total=$((total + ${mem%g}))
    fi
  done
done
assert_eq "${total}" 70 "fixed memory caps of a 2+10 pool, GiB"
echo "fixed argv per tier ok"

# The IO share is the budget over H+L (1000 MiB/s * 90% / 3 = 300), fixed mode.
mbps_file="${work}/work-disk.mbps"
echo 1000 > "${mbps_file}"
WORK_DISK_MBPS_FILE=${mbps_file}
SHARING=fixed accepted 1 2
finish_io_limits
assert_eq "${SLOT_IO_MBPS}" 300 "1+2 io share"
IO_DEVICE=/dev/sde
create 3
pair --device-read-bps /dev/sde:300mb
pair --device-write-bps /dev/sde:300mb
pair --device-read-iops /dev/sde:2400
accepted 2 10
finish_io_limits
assert_eq "${SLOT_IO_MBPS}" 75 "2+10 io share"
assert_eq "${POOL_IO_MBPS}" 900 "2+10 io pool"
# status.json reports the share times the slots in fixed mode.
AAP_POOL_SHARING=fixed write_status
assert_eq "$(jq -r '.pool.io_mbps' "${RUN_DIR}/status.json")" 900 "fixed pool io in status"
rm -f "${RUN_DIR}/status.json"
IO_DEVICE=""
echo "io split over heavy plus light ok"

# The zccache budget is split over H+L too: 9216 MiB / 3 = 3072 MiB.
accepted 1 2
create 1
pair --env AAP_ZCCACHE_BUDGET_BYTES=3221225472
accepted 2 10
create 1
pair --env "AAP_ZCCACHE_BUDGET_BYTES=$((9216 / 12 * 1024 * 1024))"
echo "zccache split ok"

# --- A slot above 5 in the pool loop, drain and stop --------------------------
# shellcheck disable=SC2317
disk_ok() { return 0; }
# shellcheck disable=SC2317,SC2329
remove_job_containers() { echo removed >> "${log}"; }
# shellcheck disable=SC2317,SC2329
remove_slot_containers() { echo "cleaned $1" >> "${log}"; }
# The runner name is the container's hostname: aap-crrr-<slot>-c<slot> -> hostc<slot>.
# shellcheck disable=SC2317
docker() {
  if [[ "$1" == inspect ]]; then
    echo "host${4##*-}"
  fi
}
# shellcheck disable=SC2317
deregister_runner() { echo "deregister $1" >> "${log}"; }
# shellcheck disable=SC2317
slot_loop() {
  trap - EXIT TERM INT
  echo "slot_loop $1" >> "${log}"
  set_slot_state "$1" listening "aap-crrr-$1-c$1"
  exec sleep 30
}
STATUS_TICK_SECONDS=0.2
DEREGISTER_BUDGET_SECONDS=3

wait_for_slots() {
  local s i ok
  for i in $(seq 1 60); do
    ok=1
    for s in "$@"; do
      [[ -f "${RUN_DIR}/slot-${s}" ]] || ok=0
    done
    # Every slot's last write_status is in: status.json shows them all listening.
    if ((ok)) && [[ "$(jq -r '[.slots[] | select(.state == "idle")] | length' "${RUN_DIR}/status.json" 2> /dev/null)" == "$#" ]]; then
      sleep 0.3
      return 0
    fi
    sleep 0.1
  done
  fail "slots $* never listened: $(cat "${log}" "${err}")"
}

# Drain a 1+2 pool: slots 1, 3 and 4 are started, stopped, cleaned and deregistered.
accepted 1 2
: > "${log}"
: > "${err}"
rm -f "${RUN_DIR}"/slot-*
(run_pool) 2> "${err}" &
pool=$!
wait_for_slots 1 3 4
[[ "$(grep -c '^slot_loop' "${log}")" -eq 3 ]] || fail "run_pool did not start exactly three slots: $(cat "${log}")"
[[ ! -e "${RUN_DIR}/slot-2" ]] || fail "run_pool started slot 2 of a 1+2 pool"
[[ "$(jq -c '[.slots[].slot]' "${RUN_DIR}/status.json")" == '[1,3,4]' ]] || fail "status of the running pool: $(cat "${RUN_DIR}/status.json")"
: > "${RUN_DIR}/drain"
rc=0
wait "${pool}" || rc=$?
rm -f "${RUN_DIR}/drain"
[[ "${rc}" -eq 0 ]] || fail "the drained pool exited ${rc}; want 0: $(cat "${err}")"
[[ "$(grep -E '^cleaned ' "${log}" | sort | tr '\n' ' ')" == "cleaned 1 cleaned 3 cleaned 4 " ]] \
  || fail "the drain did not reach slots 1, 3 and 4: $(cat "${log}")"
[[ "$(grep -E '^deregister ' "${log}" | sort | tr '\n' ' ')" == "deregister aap-crrr-hostc1 deregister aap-crrr-hostc3 deregister aap-crrr-hostc4 " ]] \
  || fail "the drain did not deregister slot 4's runner: $(cat "${log}")"
[[ ! -e "${RUN_DIR}/slot-4" ]] || fail "slot-4 was left after the drain"
echo "drain reaches slot 4 of a 1+2 pool ok"

# Stop (SIGTERM) a 1+2 pool: the job containers are removed, slot 4's status
# file goes and slot 4's runner is deregistered with the others.
: > "${log}"
: > "${err}"
rm -f "${RUN_DIR}"/slot-*
(run_pool) 2> "${err}" &
pool=$!
wait_for_slots 1 3 4
kill -TERM "${pool}"
rc=0
wait "${pool}" || rc=$?
[[ "${rc}" -eq 143 ]] || fail "SIGTERM of a 1+2 pool exited ${rc}; want 143: $(cat "${err}")"
grep -qx removed "${log}" || fail "stop did not remove the job containers: $(cat "${log}")"
[[ "$(grep -E '^deregister ' "${log}" | sort | tr '\n' ' ')" == "deregister aap-crrr-hostc1 deregister aap-crrr-hostc3 deregister aap-crrr-hostc4 " ]] \
  || fail "stop did not deregister slot 4's runner: $(cat "${log}")"
[[ -z "$(find "${RUN_DIR}" -maxdepth 1 -name 'slot-*')" ]] || fail "stop left slot files: $(ls "${RUN_DIR}")"
echo "stop reaches slot 4 of a 1+2 pool ok"

# Stop a 2+10 pool with stale files above slot 9: run_pool clears them at
# start, stop_pool clears the slot-10..12 files and deregisters slot 12's runner.
accepted 2 10
: > "${log}"
: > "${err}"
printf 'idle 1 - \n' > "${RUN_DIR}/slot-11"
printf '1 repo url\n' > "${RUN_DIR}/slot-11.run"
(run_pool) 2> "${err}" &
pool=$!
wait_for_slots 1 2 3 4 5 6 7 8 9 10 11 12
[[ "$(grep -c '^slot_loop' "${log}")" -eq 12 ]] || fail "run_pool did not start twelve slots: $(grep -c '^slot_loop' "${log}")"
[[ ! -e "${RUN_DIR}/slot-11.run" ]] || fail "run_pool left a stale slot-11.run"
[[ "$(jq -r '.slots | length' "${RUN_DIR}/status.json")" == 12 ]] || fail "status of 12 slots: $(cat "${RUN_DIR}/status.json")"
printf '1 repo url\n' > "${RUN_DIR}/slot-12.run"
kill -TERM "${pool}"
rc=0
wait "${pool}" || rc=$?
[[ "${rc}" -eq 143 ]] || fail "SIGTERM exit was ${rc}; want 143: $(cat "${err}")"
leftover=$(find "${RUN_DIR}" -maxdepth 1 \( -name 'slot-*' -o -name status.json -o -name usage \) | tr '\n' ' ')
[[ -z "${leftover}" ]] || fail "stop_pool left ${leftover}"
[[ "$(grep -c '^deregister aap-crrr-hostc' "${log}")" -eq 12 ]] \
  || fail "stop did not deregister all 12 listening runners: $(cat "${log}")"
grep -qx 'deregister aap-crrr-hostc12' "${log}" || fail "slot 12's runner was not deregistered"
echo "run_pool and stop reach slots 10..12 ok"

# --- usage and the ghost reap read slot-10..12 --------------------------------
printf 'running 1 aap-crrr-12-1-1 build\n' > "${RUN_DIR}/slot-12"
got=$(printf 'aap-crrr-12-1-1\t50.00%%\t1GiB / 8GiB\n' | usage_lines)
assert_eq "${got}" "12 aap-crrr-12-1-1 0.5 1.0" "usage line for slot 12"
rm -f "${RUN_DIR}/slot-12"
echo "usage sample reaches slot 12 ok"

# shellcheck disable=SC2317
mint_installation_token() { echo test-installation-token; }
# One offline, idle runner whose name is the hostname of slot 12's container.
# shellcheck disable=SC2317
curl() {
  local url="${*: -1}"
  cat > /dev/null
  if [[ " $* " == *" -X DELETE "* ]]; then
    echo "DELETE ${url##*/}" >> "${calls}"
    printf 204
    return 0
  fi
  case " $* " in
    *" page=1 "*) printf '%s' '{"runners":[{"id":31,"name":"aap-crrr-slot12host","status":"offline","busy":false,"labels":[{"name":"fresh"}]},{"id":32,"name":"aap-crrr-ghost","status":"offline","busy":false,"labels":[{"name":"fresh"}]}]}' ;;
  esac
}
# shellcheck disable=SC2317
docker() {
  case "$1" in
    ps) ;;
    inspect) [[ "${*: -1}" == slot12name ]] && echo slot12host || return 1 ;;
  esac
}
AAP_GITHUB_ORG=example-org
AAP_RUNNER_BASE_LABEL=fresh
printf 'starting 1 slot12name\n' > "${RUN_DIR}/slot-12"
: > "${calls}"
reap_ghost_runners > /dev/null 2>&1
[[ "$(grep '^DELETE' "${calls}" | tr '\n' ' ')" == "DELETE 32 " ]] \
  || fail "the ghost reap deleted other than the one ghost (slot 12's runner must stay): $(cat "${calls}")"
rm -f "${RUN_DIR}/slot-12"
echo "ghost reap sees slot 12's container ok"

# --- Container names and slot labels for slots 10..12 ---------------------------
# Containers are found by the exact label aap-crrr-slot=<N> (docker matches the
# whole value), runners by hostname, usage by the slot file: nothing parses the
# slot out of a name. Slot 12's container must be removed with slot 12, never
# with slot 1, and by the label-wide removal. The real functions run in a
# subshell, past the stubs above.
(
  # shellcheck source=SCRIPTDIR/../distro/manager.sh
  source "${here}/../distro/manager.sh"
  slog="${work}/slotlog"
  : > "${slog}"
  # c1 is slot 1's container and c12 slot 12's; --filter label=K=V is an exact match.
  # shellcheck disable=SC2317
  docker() {
    local a want="" ids
    case "$1" in
      ps)
        for a in "$@"; do
          [[ "${a}" == label=aap-crrr-slot=* ]] && want=${a#label=aap-crrr-slot=}
        done
        ids=$'c1:1\nc12:12'
        while IFS=: read -r id slot; do
          [[ -z "${want}" || "${want}" == "${slot}" ]] && echo "${id}"
        done <<< "${ids}"
        return 0
        ;;
      inspect) [[ "$4" == c12 ]] && echo /aap-crrr-12-1-1 || echo /aap-crrr-1-1-1 ;;
      *) echo "docker $*" >> "${slog}" ;;
    esac
  }
  remove_slot_containers 12
  [[ "$(cat "${slog}")" == $'docker rm -f -v c12\ndocker network rm aap-crrr-12-1-1' ]] \
    || { echo "FAIL: remove_slot_containers 12: $(cat "${slog}")" >&2; exit 1; }
  : > "${slog}"
  remove_slot_containers 1
  [[ "$(cat "${slog}")" == $'docker rm -f -v c1\ndocker network rm aap-crrr-1-1-1' ]] \
    || { echo "FAIL: remove_slot_containers 1 touched another slot: $(cat "${slog}")" >&2; exit 1; }
  : > "${slog}"
  remove_job_containers
  grep -qx 'docker rm -f c12' "${slog}" && grep -qx 'docker rm -f c1' "${slog}" \
    || { echo "FAIL: remove_job_containers missed a container: $(cat "${slog}")" >&2; exit 1; }
  [[ "$(job_name 12)" =~ ^aap-crrr-12-[0-9]+-[0-9]+$ ]] \
    || { echo "FAIL: job_name 12: $(job_name 12)" >&2; exit 1; }
) || fail "slot 12 container matching"
echo "slot 12 containers matched and removed ok"

# --- --check-limits ------------------------------------------------------------
conf="${work}/manager.conf"
limits="${work}/limits.conf"
cat > "${conf}" <<'CONF'
AAP_GITHUB_ORG=example-org
AAP_GITHUB_APP_ID=12345
AAP_GITHUB_APP_INSTALLATION_ID=67890
AAP_GITHUB_APP_PRIVATE_KEY_PATH=/etc/aap-runner/app.pem
AAP_RUNNER_IMAGE=aap-crrr-runner:local
AAP_RUNNER_BASE_LABEL=fresh
AAP_RUNNER_EXTRA_LABELS=heavy
AAP_RUNNER_GROUP=aap-crrr
AAP_WORK_DISK_GIB=100
CONF
chmod 0400 "${conf}"
check_limits() {
  bash -c '
    source "$1"
    CONFIG_PATH=$2
    LIMITS_PATH=$3
    WORK_DISK_MBPS_FILE=$4
    id() { echo 0; }
    stat() {
      if [[ "$2" == "%u" ]]; then echo 0; else command stat "$@"; fi
    }
    main --check-limits
  ' _ "${here}/../distro/manager.sh" "${conf}" "${limits}" "${mbps_file}" 2>&1
}
write_limits() {
  printf '%s\n' "$@" > "${limits}"
  chmod 0644 "${limits}"
}
limits_refused() {
  local want="$1" out rc=0
  shift
  write_limits "$@"
  out=$(check_limits) || rc=$?
  [[ "${rc}" -eq 1 ]] || fail "check-limits exited ${rc}; want 1: ${out}"
  [[ "${out}" == *"${want}"* ]] || fail "refusal does not say '${want}': ${out}"
  if grep -q '^AAP_RUNNER_COUNT=' <<< "${out}"; then
    fail "a refused file still printed limits: ${out}"
  fi
}

write_limits 'AAP_LINUX_HEAVY_COUNT=1' 'AAP_LINUX_LIGHT_COUNT=2' 'AAP_JOB_CPUS=28' 'AAP_JOB_MEMORY=80g'
out=$(check_limits) || fail "a tiered limits.conf was refused: ${out}"
[[ "${out}" == $'AAP_RUNNER_COUNT=3\nAAP_LINUX_HEAVY_COUNT=1\nAAP_LINUX_LIGHT_COUNT=2\nAAP_JOB_CPUS=28\nAAP_JOB_MEMORY=80g\nAAP_JOB_IO_PERCENT=90\nAAP_JOB_IO_MBPS=300\nAAP_POOL_SHARING=slice' ]] \
  || fail "tiered --check-limits output: ${out}"
write_limits 'AAP_LINUX_HEAVY_COUNT=0' 'AAP_LINUX_LIGHT_COUNT=1' 'AAP_JOB_MEMORY=12g'
out=$(check_limits) || fail "0+1 was refused: ${out}"
[[ "${out}" == $'AAP_RUNNER_COUNT=1\nAAP_LINUX_HEAVY_COUNT=0\nAAP_LINUX_LIGHT_COUNT=1\n'* ]] || fail "0+1 output: ${out}"
limits_refused "key AAP_GITHUB_APP_ID is not AAP_RUNNER_COUNT, AAP_LINUX_HEAVY_COUNT, AAP_LINUX_LIGHT_COUNT, AAP_JOB_CPUS, AAP_JOB_MEMORY, AAP_JOB_IO_PERCENT, or AAP_POOL_SHARING" 'AAP_GITHUB_APP_ID=1'
limits_refused "has no value for AAP_LINUX_LIGHT_COUNT" 'AAP_LINUX_HEAVY_COUNT=1' 'AAP_LINUX_LIGHT_COUNT='
limits_refused "AAP_LINUX_HEAVY_COUNT=1.0 is not 0..2" 'AAP_LINUX_HEAVY_COUNT=1.0' 'AAP_LINUX_LIGHT_COUNT=1'
limits_refused "AAP_LINUX_HEAVY_COUNT and AAP_LINUX_LIGHT_COUNT must both be set" 'AAP_LINUX_HEAVY_COUNT=1'
limits_refused "cannot be combined with AAP_RUNNER_COUNT" 'AAP_RUNNER_COUNT=2' 'AAP_LINUX_HEAVY_COUNT=1' 'AAP_LINUX_LIGHT_COUNT=1'
limits_refused "cannot both be 0" 'AAP_LINUX_HEAVY_COUNT=0' 'AAP_LINUX_LIGHT_COUNT=0'
limits_refused "tier reservations 70g exceed AAP_JOB_MEMORY=64g" 'AAP_LINUX_HEAVY_COUNT=2' 'AAP_LINUX_LIGHT_COUNT=10' 'AAP_JOB_MEMORY=64g'
# The count/tier exclusion is per file, and limits.conf's form replaces
# manager.conf's: a manager.conf with AAP_RUNNER_COUNT does not stop limits.conf
# from asking for tiers, and a manager.conf with tiers does not stop it from
# asking for a count. Both forms in one file are refused, in either file.
check_slots() {
  bash -c '
    source "$1"
    CONFIG_PATH=$2
    LIMITS_PATH=$3
    WORK_DISK_MBPS_FILE=$4
    id() { echo 0; }
    stat() {
      if [[ "$2" == "%u" ]]; then echo 0; else command stat "$@"; fi
    }
    load_config
    echo "${AAP_RUNNER_COUNT}:${POOL_SLOTS[*]}:${AAP_LINUX_HEAVY_COUNT-unset}:${AAP_LINUX_LIGHT_COUNT-unset}"
  ' _ "${here}/../distro/manager.sh" "${conf}" "${limits}" "${mbps_file}" 2>&1
}
conf_base=$(cat "${conf}")
write_conf() {
  chmod 0600 "${conf}"
  { printf '%s\n' "${conf_base}"; printf '%s\n' "$@"; } > "${conf}"
  chmod 0400 "${conf}"
}
write_conf 'AAP_RUNNER_COUNT=1'
write_limits 'AAP_LINUX_HEAVY_COUNT=1' 'AAP_LINUX_LIGHT_COUNT=2' 'AAP_JOB_CPUS=28' 'AAP_JOB_MEMORY=80g'
out=$(check_limits) || fail "limits.conf tiers over a manager.conf count were refused: ${out}"
[[ "${out}" == $'AAP_RUNNER_COUNT=3\nAAP_LINUX_HEAVY_COUNT=1\nAAP_LINUX_LIGHT_COUNT=2\nAAP_JOB_CPUS=28\nAAP_JOB_MEMORY=80g\nAAP_JOB_IO_PERCENT=90\nAAP_JOB_IO_MBPS=300\nAAP_POOL_SHARING=slice' ]] \
  || fail "tiers over a manager.conf count, --check-limits: ${out}"
assert_eq "$(check_slots)" "3:1 3 4:1:2" "tiers over a manager.conf count"
write_conf 'AAP_LINUX_HEAVY_COUNT=1' 'AAP_LINUX_LIGHT_COUNT=2' 'AAP_JOB_CPUS=28' 'AAP_JOB_MEMORY=80g'
write_limits 'AAP_RUNNER_COUNT=2'
out=$(check_limits) || fail "limits.conf count over manager.conf tiers was refused: ${out}"
[[ "${out}" == $'AAP_RUNNER_COUNT=2\nAAP_JOB_CPUS=28\nAAP_JOB_MEMORY=80g\nAAP_JOB_IO_PERCENT=90\nAAP_JOB_IO_MBPS=450\nAAP_POOL_SHARING=slice' ]] \
  || fail "count over manager.conf tiers, --check-limits: ${out}"
assert_eq "$(check_slots)" "2:1 2:unset:unset" "count over manager.conf tiers"
# manager.conf tiers and no limits.conf: the pool is tiered.
rm -f "${limits}"
assert_eq "$(check_slots)" "3:1 3 4:1:2" "manager.conf tiers alone"
write_conf 'AAP_RUNNER_COUNT=1'
limits_refused "cannot be combined with AAP_RUNNER_COUNT in the same file" 'AAP_LINUX_HEAVY_COUNT=1' 'AAP_LINUX_LIGHT_COUNT=2' 'AAP_RUNNER_COUNT=3'
limits_refused "cannot be combined with AAP_RUNNER_COUNT in the same file" 'AAP_RUNNER_COUNT=3' 'AAP_LINUX_HEAVY_COUNT=1'
write_conf 'AAP_RUNNER_COUNT=2' 'AAP_LINUX_HEAVY_COUNT=1' 'AAP_LINUX_LIGHT_COUNT=2'
limits_refused "cannot be combined with AAP_RUNNER_COUNT in the same file" 'AAP_JOB_CPUS=28'
rm -f "${limits}"
out=$(check_limits) && fail "a manager.conf with both forms was accepted: ${out}"
[[ "${out}" == *"cannot be combined with AAP_RUNNER_COUNT in the same file"* ]] || fail "manager.conf both forms: ${out}"
write_conf
echo "per-file exclusion ok"

# An untiered limits.conf prints the six lines it always did.
write_limits 'AAP_RUNNER_COUNT=2'
out=$(check_limits) || fail "an untiered limits.conf was refused: ${out}"
[[ "${out}" == $'AAP_RUNNER_COUNT=2\nAAP_JOB_CPUS=6\nAAP_JOB_MEMORY=12g\nAAP_JOB_IO_PERCENT=90\nAAP_JOB_IO_MBPS=450\nAAP_POOL_SHARING=slice' ]] \
  || fail "untiered --check-limits output: ${out}"
# The tiered manager reports version 3.
out=$(bash "${here}/../distro/manager.sh" --version)
assert_eq "${out}" "aap-runner-manager 3" "version"
echo "check-limits ok"

echo "manager tiers tests ok"
