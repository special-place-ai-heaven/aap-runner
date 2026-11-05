#!/bin/bash
# run_one with docker, the token mint, and the wall clock stubbed: the
# docker create argv carries the runtime, per-slot limits, slot label and the
# zccache budget, with no bind mount and no sccache setting, and the token goes
# to stdin, never to argv.
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
calls="${work}/calls"
create_argv="${work}/create_argv"
stdin_seen="${work}/stdin"
: > "${calls}"

# shellcheck disable=SC2317
docker() {
  printf '%s\n' "$*" >> "${calls}"
  case "$1" in
    create) printf '%s\n' "$@" > "${create_argv}" ;;
    start) cat > "${stdin_seen}" ;;
  esac
  return 0
}
# shellcheck disable=SC2317
mint_registration_token() {
  echo test-registration-token
}
# kill -0 must succeed on the returned pid; this shell is alive.
# shellcheck disable=SC2317
arm_wall_clock() {
  echo "$$"
}
# shellcheck disable=SC2317
disarm_wall_clock() {
  :
}

AAP_JOB_CPUS=24
AAP_JOB_MEMORY=72g
AAP_JOB_PIDS_LIMIT=8192
AAP_JOB_TIMEOUT_MINUTES=120
finish_job_limits
AAP_RUNNER_COUNT=3
finish_runner_count
AAP_GITHUB_ORG=example-org
AAP_RUNNER_LABELS=self-hosted,linux,fresh,heavy
AAP_RUNNER_GROUP=aap-crrr
AAP_WORK_DISK_GIB=100
AAP_DISK_FLOOR_GB=55
AAP_RUNNER_IMAGE=aap-crrr-runner:local

run_one 2 >/dev/null || fail "run_one returned non-zero with every docker call stubbed to succeed"

[[ -s "${create_argv}" ]] || fail "docker create was not called"
mapfile -t argv < "${create_argv}"

has() {
  local a
  for a in "${argv[@]}"; do
    [[ "${a}" == "$1" ]] && return 0
  done
  fail "docker create argv has no '$1'"
}
pair() {
  local i
  for ((i = 0; i < ${#argv[@]} - 1; i++)); do
    [[ "${argv[i]}" == "$1" && "${argv[i + 1]}" == "$2" ]] && return 0
  done
  fail "docker create argv has no '$1 $2'"
}

has --runtime=sysbox-runc
pair --cpus 8
pair --memory 24g
pair --memory-swap 24g
pair --pids-limit 8192
pair --cpu-shares 512
pair --label aap-crrr-job=1
pair --label aap-crrr-slot=2
# 9216 MiB pool budget over AAP_RUNNER_COUNT=3 slots.
pair --env AAP_ZCCACHE_BUDGET_BYTES=3221225472
for a in "${argv[@]}"; do
  [[ "${a}" != --mount && "${a}" != --mount=* ]] || fail "docker create has a bind mount"
  [[ "${a}" != *SCCACHE* && "${a}" != *sccache* && "${a}" != RUSTC_WRAPPER* && "${a}" != *=RUSTC_WRAPPER* ]] || fail "docker create still carries sccache wiring: ${a}"
done
[[ "${argv[-1]}" == aap-crrr-runner:local ]] || fail "image is not the last argument: ${argv[-1]}"
name=""
for ((i = 0; i < ${#argv[@]} - 1; i++)); do
  [[ "${argv[i]}" == --name ]] && name=${argv[i + 1]}
done
[[ "${name}" =~ ^aap-crrr-2-[0-9]+-[0-9]+$ ]] || fail "container name ${name} does not carry slot 2"
for a in "${argv[@]}"; do
  [[ "${a}" != -v && "${a}" != --volume ]] || fail "docker create has a -v volume"
done
echo "docker create argv ok"

if grep -q test-registration-token "${calls}"; then
  fail "the registration token appeared in a docker argv"
fi
[[ "$(cat "${stdin_seen}")" == test-registration-token ]] || fail "the token was not on docker start's stdin"
if grep -q 'prune' "${calls}"; then
  fail "run_one ran a label-wide prune: $(grep prune "${calls}")"
fi
grep -qx "rm -f -v ${name}" "${calls}" || fail "run_one did not remove its own container"
grep -qx "network rm ${name}" "${calls}" || fail "run_one did not remove its own network"
echo "token and per-job cleanup ok"

: > "${calls}"
prune_job_docker
grep -qx 'image prune -f --filter dangling=true' "${calls}" || fail "image prune: $(cat "${calls}")"
grep -qx 'builder prune -f' "${calls}" || fail "builder prune missing"
grep -qx 'container prune -f --filter label=aap-crrr-job=1 --filter until=1h' "${calls}" || fail "container prune: $(cat "${calls}")"
grep -qx 'network prune -f --filter label=aap-crrr-job=1 --filter until=1h' "${calls}" || fail "network prune: $(cat "${calls}")"
if grep -qx 'network prune -f --filter label=aap-crrr-job=1' "${calls}"; then
  fail "network prune had no age bound"
fi
declare -f slot_loop | grep -q clean_after_job || fail "slot_loop does not clean after a job"
echo "after-job prune ok"

echo "manager run_one tests ok"
