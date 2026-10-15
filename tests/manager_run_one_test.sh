#!/bin/bash
# run_one with docker, the token mint, and the wall clock stubbed: the
# docker create argv carries the runtime, per-slot limits, slot label, cache
# mount and cache env, and the token goes to stdin, never to argv. Also the
# cache tree cap.
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
RUNNER_UID=$(id -u)
SCCACHE_HOST_DIR="${work}/sccache"

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
pair --mount "type=bind,source=${SCCACHE_HOST_DIR},target=/var/cache/aap-sccache"
pair --env RUSTC_WRAPPER=sccache
pair --env SCCACHE_DIR=/var/cache/aap-sccache/default
pair --env SCCACHE_CACHE_SIZE=10G
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
[[ -d "${SCCACHE_HOST_DIR}" ]] || fail "run_one did not create the cache dir"
[[ "$(stat -c '%a %u' "${SCCACHE_HOST_DIR}")" == "700 ${RUNNER_UID}" ]] || fail "cache dir is not mode 700 owned by the runner uid"
if grep -q 'prune' "${calls}"; then
  fail "run_one ran a label-wide prune: $(grep prune "${calls}")"
fi
grep -qx "rm -f -v ${name}" "${calls}" || fail "run_one did not remove its own container"
grep -qx "network rm ${name}" "${calls}" || fail "run_one did not remove its own network"
echo "token, cache dir, and per-job cleanup ok"

mkdir -p "${SCCACHE_HOST_DIR}/repo"
head -c 2097152 /dev/zero > "${SCCACHE_HOST_DIR}/repo/new"
touch -d '2024-01-01 00:00:00' "${SCCACHE_HOST_DIR}/repo/new"
SCCACHE_TREE_MAX_MB=8
bound_sccache_tree 2>/dev/null
[[ -f "${SCCACHE_HOST_DIR}/repo/new" ]] || fail "a tree under the cap was trimmed"
head -c 2097152 /dev/zero > "${SCCACHE_HOST_DIR}/repo/old"
touch -d '2020-01-01 00:00:00' "${SCCACHE_HOST_DIR}/repo/old"
SCCACHE_TREE_MAX_MB=3
bound_sccache_tree 2>/dev/null
[[ -d "${SCCACHE_HOST_DIR}" ]] || fail "the trim removed the top cache dir"
[[ -f "${SCCACHE_HOST_DIR}/repo/new" ]] || fail "the newest cache file was trimmed"
[[ ! -e "${SCCACHE_HOST_DIR}/repo/old" ]] || fail "the oldest cache file was kept"
echo "cache tree cap ok"

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
