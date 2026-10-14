#!/bin/bash
# Pool sharing. slice: the runtime slice aap-runner-pool.slice carries the
# pool totals (CPUQuota, MemoryMax, IO budget) and every job container is
# created under it with the pool as its own safety cap and an equal soft
# memory share. fixed: hard 1/count shares, as before. docker and systemctl
# are stubbed as functions and record their argv; nothing is started.
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
WORK_DISK_MBPS_FILE="${work}/work-disk.mbps"
echo 1000 > "${WORK_DISK_MBPS_FILE}"
create_argv="${work}/create_argv"
sysctl_log="${work}/systemctl"
err="${work}/err"
fake_driver=systemd
fake_sysctl_rc=0

# shellcheck disable=SC2317
docker() {
  case "$1" in
    info) echo "${fake_driver}" ;;
    create) printf '%s\n' "$@" > "${create_argv}" ;;
    start) cat > /dev/null ;;
  esac
  return 0
}
# shellcheck disable=SC2317
systemctl() {
  printf '%s\n' "$*" >> "${sysctl_log}"
  if [[ "$1" == set-property ]]; then
    return "${fake_sysctl_rc}"
  fi
  return 0
}
# shellcheck disable=SC2317
mint_registration_token() { echo test-registration-token; }
# shellcheck disable=SC2317
arm_wall_clock() { echo "$$"; }
# shellcheck disable=SC2317
disarm_wall_clock() { :; }
AAP_RUNNER_IMAGE=aap-crrr-runner:local
RUNNER_UID=$(id -u)
SCCACHE_HOST_DIR="${work}/sccache"

# pool COUNT SHARING: the load_config limit steps for 24 cpus, 72g, 90% of a
# 1000 MiB/s disk on /dev/sde, then setup_pool_sharing.
pool() {
  AAP_JOB_CPUS=24
  AAP_JOB_MEMORY=72g
  AAP_JOB_PIDS_LIMIT=4096
  AAP_JOB_TIMEOUT_MINUTES=120
  AAP_JOB_IO_PERCENT=90
  AAP_RUNNER_COUNT=$1
  AAP_POOL_SHARING=$2
  finish_job_limits
  finish_runner_count
  finish_io_limits
  finish_pool_sharing
  IO_DEVICE=/dev/sde
  rm -f "${sysctl_log}"
  setup_pool_sharing > /dev/null 2> "${err}"
}
create() {
  rm -f "${create_argv}"
  run_one 1 >/dev/null 2>&1 || fail "run_one failed"
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
    [[ "${a}" != "$1"* ]] || fail "docker create argv has '${a}'"
  done
}

want_props="set-property --runtime aap-runner-pool.slice CPUQuota=2400% MemoryMax=72G"
want_props+=" IOReadBandwidthMax=/dev/sde 943718400 IOWriteBandwidthMax=/dev/sde 943718400"
want_props+=" IOReadIOPSMax=/dev/sde 7200 IOWriteIOPSMax=/dev/sde 7200"
for n in 1 2 3; do
  pool "${n}" ""
  [[ "${AAP_POOL_SHARING}" == slice ]] || fail "default sharing is ${AAP_POOL_SHARING}"
  [[ "$(sed -n 1p "${sysctl_log}")" == "revert aap-runner-pool.slice" ]] || fail "${n} slots: no revert first: $(cat "${sysctl_log}")"
  [[ "$(sed -n 2p "${sysctl_log}")" == "${want_props}" ]] || fail "${n} slots: slice properties: $(sed -n 2p "${sysctl_log}")"
done
echo "slice properties for 1, 2, 3 slots ok"

AAP_JOB_MEMORY=12g AAP_JOB_CPUS=2.5 POOL_IO_MBPS=0
[[ "$(slice_properties | tr '\n' ' ')" == "CPUQuota=250% MemoryMax=12G " ]] || fail "fractional cpus, no io: $(slice_properties)"
AAP_JOB_MEMORY=4096m
[[ "$(slice_properties | sed -n 2p)" == "MemoryMax=4096M" ]] || fail "m suffix: $(slice_properties)"
AAP_JOB_MEMORY=4294967296b
[[ "$(slice_properties | sed -n 2p)" == "MemoryMax=4294967296" ]] || fail "b suffix: $(slice_properties)"
echo "slice property units ok"

for pair_ in 1:72g 2:36g 3:24g; do
  pool "${pair_%%:*}" slice
  create
  pair --cgroup-parent aap-runner-pool.slice
  pair --cpus 24
  pair --memory 72g
  pair --memory-swap 72g
  pair --memory-reservation "${pair_#*:}"
  lacks --blkio-weight
  pair --cpu-shares 512
  pair --pids-limit 4096
  lacks --device-
  [[ "${argv[-1]}" == aap-crrr-runner:local ]] || fail "image is not last"
done
echo "slice container argv ok"

pool 3 fixed
[[ ! -s "${sysctl_log}" ]] || fail "fixed mode called systemctl: $(cat "${sysctl_log}")"
create
pair --cpus 8
pair --memory 24g
pair --memory-swap 24g
pair --device-read-bps /dev/sde:300mb
pair --device-write-iops /dev/sde:2400
lacks --cgroup-parent
lacks --memory-reservation
lacks --blkio-weight
echo "fixed argv ok"

fake_driver=cgroupfs
pool 3 slice
[[ "${AAP_POOL_SHARING}" == fixed ]] || fail "cgroupfs driver kept ${AAP_POOL_SHARING}"
[[ "$(cat "${err}")" == *"cgroup driver is 'cgroupfs', not systemd"* ]] || fail "fallback logged: $(cat "${err}")"
[[ ! -s "${sysctl_log}" ]] || fail "cgroupfs fallback touched the slice"
create
pair --cpus 8
lacks --cgroup-parent
fake_driver=systemd
fake_sysctl_rc=1
pool 3 slice
[[ "${AAP_POOL_SHARING}" == fixed ]] || fail "a failed set-property kept slice"
[[ "$(cat "${err}")" == *"could not set aap-runner-pool.slice"* ]] || fail "set-property fallback logged: $(cat "${err}")"
fake_sysctl_rc=0
echo "fallback to fixed ok"

AAP_POOL_SHARING=dynamic
if finish_pool_sharing 2> "${err}"; then
  fail "AAP_POOL_SHARING=dynamic was accepted"
fi
[[ "$(cat "${err}")" == *"is not slice or fixed"* ]] || fail "refusal: $(cat "${err}")"
AAP_POOL_SHARING=fixed
RUN_DIR="${work}"
[[ "$(status_json | jq -r .sharing)" == fixed ]] || fail "status sharing for fixed"
AAP_POOL_SHARING=slice
[[ "$(status_json | jq -r .sharing)" == slice ]] || fail "status sharing for slice"
echo "config and status ok"

echo "manager sharing tests ok"
