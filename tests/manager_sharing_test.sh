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
starts="${work}/starts"
sysrun_log="${work}/systemd-run"
# docker start fails with this text and rc 126 while the start_errs count
# is above 0.
start_errs="${work}/start_errs"
echo 0 > "${start_errs}"
start_err_text=""
POOL_SLICE_CGROUP="${work}/slice"

# shellcheck disable=SC2317
docker() {
  case "$1" in
    info) echo "${fake_driver}" ;;
    create) printf '%s\n' "$@" > "${create_argv}" ;;
    start)
      cat > /dev/null
      echo start >> "${starts}"
      # run_one starts docker in a subshell: the count lives in a file.
      n=$(cat "${start_errs}")
      if ((n > 0)); then
        echo $((n - 1)) > "${start_errs}"
        echo "${start_err_text}" >&2
        return 126
      fi
      ;;
  esac
  return 0
}
# The probe unit makes the slice cgroup, as systemd does.
# shellcheck disable=SC2317
systemd-run() {
  printf '%s\n' "$*" >> "${sysrun_log}"
  mkdir -p "${POOL_SLICE_CGROUP}"
  echo "2400000 100000" > "${POOL_SLICE_CGROUP}/cpu.max"
}
# shellcheck disable=SC2317
sleep() { :; }
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

want_props="set-property --runtime aap-runner-pool.slice CPUQuota=2400% MemoryMax=72G MemoryHigh=49152M"
want_props+=" IOReadBandwidthMax= IOWriteBandwidthMax= IOReadIOPSMax= IOWriteIOPSMax="
want_props+=" IOReadBandwidthMax=/dev/sde 943718400 IOWriteBandwidthMax=/dev/sde 943718400"
want_props+=" IOReadIOPSMax=/dev/sde 7200 IOWriteIOPSMax=/dev/sde 7200"
for n in 1 2 3; do
  pool "${n}" ""
  [[ "${AAP_POOL_SHARING}" == slice ]] || fail "default sharing is ${AAP_POOL_SHARING}"
  [[ "$(cat "${sysctl_log}")" == "${want_props}" ]] || fail "${n} slots: want only set-property: $(cat "${sysctl_log}")"
done
echo "slice properties for 1, 2, 3 slots ok, no revert"

# Unmeasured disk: the IO lists are cleared, so an earlier pool's cap goes.
AAP_JOB_MEMORY=12g AAP_JOB_CPUS=2.5 POOL_IO_MBPS=0
want="CPUQuota=250% MemoryMax=12G MemoryHigh=8192M IOReadBandwidthMax= IOWriteBandwidthMax= IOReadIOPSMax= IOWriteIOPSMax= "
[[ "$(slice_properties | tr '\n' ' ')" == "${want}" ]] || fail "fractional cpus, no io: $(slice_properties)"
AAP_JOB_MEMORY=4096m
[[ "$(slice_properties | sed -n 2,3p | tr '\n' ' ')" == "MemoryMax=4096M MemoryHigh=2730M " ]] || fail "m suffix: $(slice_properties)"
AAP_JOB_MEMORY=4294967296b
[[ "$(slice_properties | sed -n 2,3p | tr '\n' ' ')" == "MemoryMax=4294967296 MemoryHigh=2730M " ]] || fail "b suffix: $(slice_properties)"
AAP_JOB_MEMORY=3145728k
[[ "$(slice_properties | sed -n 3p)" == "MemoryHigh=2048M" ]] || fail "k suffix: $(slice_properties)"
echo "slice property units ok"

# Slice readiness: the probe unit always starts the slice. With an IO cap
# it waits for rbps= in io.max, and only logs on timeout.
rm -rf "${POOL_SLICE_CGROUP}" "${sysrun_log}"
POOL_IO_MBPS=0
wait_pool_slice 2> "${err}" || fail "wait_pool_slice failed"
[[ "$(cat "${sysrun_log}")" == "--quiet --collect --wait --slice=aap-runner-pool.slice --unit=aap-runner-pool-probe /bin/true" ]] \
  || fail "probe unit: $(cat "${sysrun_log}" 2>&1)"
[[ ! -s "${err}" ]] || fail "ready slice logged: $(cat "${err}")"
rm -f "${sysrun_log}"
POOL_IO_MBPS=900 IO_DEVICE=/dev/sde
wait_pool_slice 2> "${err}"
[[ -s "${sysrun_log}" ]] || fail "probe skipped with the slice cgroup present"
[[ "$(cat "${err}")" == *"has no io.max after 5 s; starting slots anyway"* ]] || fail "io.max timeout: $(cat "${err}")"
echo "8:64 rbps=943718400 wbps=943718400 riops=7200 wiops=7200" > "${POOL_SLICE_CGROUP}/io.max"
wait_pool_slice 2> "${err}"
[[ ! -s "${err}" ]] || fail "io.max with the cap logged: $(cat "${err}")"
pool 2 slice
[[ -e "${POOL_SLICE_CGROUP}/cpu.max" && ! -s "${err}" ]] || fail "setup_pool_sharing did not wait cleanly: $(cat "${err}")"
echo "slice readiness wait ok"

# The slice start race: one retry after the io.bfq.weight error, none for
# any other error, and never a second retry.
race="OCI runtime create failed: openat2 ${POOL_SLICE_CGROUP}/docker-1.scope/io.bfq.weight: no such file or directory"
try_start() {
  rm -f "${starts}"
  echo "$1" > "${start_errs}"
  start_err_text=$2
  rc=0
  run_one 1 > /dev/null 2> "${err}" || rc=$?
}
try_start 1 "${race}"
[[ "${rc}" -eq 0 && "$(wc -l < "${starts}")" -eq 2 ]] || fail "race: rc ${rc}, starts $(cat "${starts}")"
[[ "$(cat "${err}")" == *"slot 1: slice start race, retrying"* ]] || fail "race not logged: $(cat "${err}")"
try_start 2 "${race}"
[[ "${rc}" -eq 126 && "$(wc -l < "${starts}")" -eq 2 ]] || fail "race twice: rc ${rc}, starts $(cat "${starts}")"
try_start 1 "OCI runtime create failed: unable to start container process"
[[ "${rc}" -eq 126 && "$(wc -l < "${starts}")" -eq 1 ]] || fail "other error: rc ${rc}, starts $(cat "${starts}")"
[[ "$(cat "${err}")" != *"retrying"* ]] || fail "other error retried: $(cat "${err}")"
echo "docker start retry ok"

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

# Post-job cache reclaim: the slice's inactive_file bytes go to
# memory.reclaim; under 256 MiB, or with no slice cgroup, nothing is written.
cg="${work}/pool.slice"
mkdir -p "${cg}"
POOL_SLICE_CGROUP="${cg}"
printf 'anon 1024\ninactive_file 1073741824\nactive_file 5\n' > "${cg}/memory.stat"
out=$(reclaim_pool_cache)
[[ "$(cat "${cg}/memory.reclaim")" == 1073741824 ]] || fail "reclaim wrote: $(cat "${cg}/memory.reclaim")"
[[ "${out}" == "cache: reclaimed 1024 MiB of cold page cache from aap-runner-pool.slice" ]] || fail "reclaim log: ${out}"
rm -f "${cg}/memory.reclaim"
printf 'inactive_file 268435455\n' > "${cg}/memory.stat"
[[ -z "$(reclaim_pool_cache)" ]] || fail "small cache was reclaimed"
[[ ! -e "${cg}/memory.reclaim" ]] || fail "small cache wrote memory.reclaim"
POOL_SLICE_CGROUP="${work}/missing"
reclaim_pool_cache || fail "missing cgroup is not a no-op"
echo "post-job cache reclaim ok"

echo "manager sharing tests ok"
