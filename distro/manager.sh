#!/bin/bash
# Root systemd loop: one fresh Sysbox runner container per job, in
# AAP_RUNNER_COUNT parallel slots.
# The GitHub App private key stays in this process. It is never passed into
# the container and never written to a second file.
set -euo pipefail

# shellcheck source=labels.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/labels.sh"
# Exact match for AAP_RUNNER_LABELS_VERSION in labels.sh.
require_labels_version 1 || exit 1

# `aap-runner-manager --version` prints this. The Windows supervisor reads it
# to tell this manager (drain, status, limits) from one that would treat an
# unknown argument as "start the pool".
MANAGER_VERSION="aap-runner-manager 2"
CONFIG_PATH=/etc/aap-runner/manager.conf
# Optional. The Windows supervisor writes the tray's settings here.
LIMITS_PATH=/etc/aap-runner/limits.conf
WORK_MOUNT=/var/lib/ghrunner
# df -BG of an ext4 is a few GiB under the VHDX. Accept configured size -10..+4.
# AAP_WORK_DISK_GIB is 20..512, so a ~1000G distro VHD is outside the window.
# The mount must also be work-disk.uuid and not the device behind /.
WORK_DISK_MIN_GB=""
WORK_DISK_MAX_GB=""
WORK_DISK_UUID_FILE=/etc/aap-runner/work-disk.uuid
# Default shares are 1024. This only weights containers inside the WSL VM.
CPU_SHARES=512
AAP_GITHUB_ORG=""
AAP_GITHUB_APP_ID=""
AAP_GITHUB_APP_INSTALLATION_ID=""
AAP_GITHUB_APP_PRIVATE_KEY_PATH=""
AAP_RUNNER_IMAGE=""
AAP_RUNNER_LABELS=""
AAP_RUNNER_BASE_LABEL=""
AAP_RUNNER_EXTRA_LABELS=""
AAP_RUNNER_GROUP=""
AAP_WORK_DISK_GIB=""
AAP_DISK_FLOOR_GB=""
AAP_JOB_MEMORY=""
AAP_JOB_CPUS=""
AAP_JOB_PIDS_LIMIT=""
AAP_JOB_TIMEOUT_MINUTES=""
AAP_JOB_IO_PERCENT=""
AAP_POOL_SHARING=""
# Unset means absent (one slot). A present but empty value is refused.
unset AAP_RUNNER_COUNT
# Per-slot docker create limits, set by finish_runner_count.
SLOT_CPUS=""
SLOT_MEMORY=""
# Per-slot disk IO cap in MiB/s on IO_DEVICE; 0 is no cap. Set by
# finish_io_limits from WORK_DISK_MBPS_FILE (written by --measure-io).
SLOT_IO_MBPS=0
# The whole pool's IO budget in MiB/s (the slice cap in slice mode).
POOL_IO_MBPS=0
IO_DEVICE=""
WORK_DISK_MBPS_FILE=/etc/aap-runner/work-disk.mbps
# IOPS cap per MiB/s of bandwidth cap: 8 IOPS per MiB/s is a 128 KiB average
# request, so the bandwidth cap binds for streaming IO and the IOPS cap only
# bites on a small-block storm (fsync-heavy linkers, cargo metadata).
IO_IOPS_PER_MB=8
# Slice mode: every job container sits in this runtime systemd slice, which
# holds the pool totals. Dashes nest it: aap.slice/aap-runner.slice/<this>.
POOL_SLICE=aap-runner-pool.slice
POOL_SLICE_CGROUP=/sys/fs/cgroup/aap.slice/aap-runner.slice/${POOL_SLICE}
# No --blkio-weight: runc writes io.bfq.weight, which exists only under the
# BFQ scheduler; on the VHDX (mq-deadline/none) the container fails at
# creation ("io.bfq.weight: no such file or directory", seen live 2026-10-14).
# The slice bandwidth cap is the IO limiter.
SLOT_PIDS=()
SLOT_STARTED=()
SLOT_FAILS=()
# Slots that stopped for a drain. They start again when the drain file goes.
SLOT_DRAINED=()
# Deregistrations in flight in this process, and their runner names.
DEREG_PIDS=()
DEREG_NAMES=()
# A slot that dies this many times in a row, each within SLOT_FAST_SECONDS of
# starting, is retired. When every slot is retired the manager exits 1 and
# systemd restarts the whole pool.
SLOT_MAX_FAILS=5
SLOT_FAST_SECONDS=120
# Shared rustc cache on the work disk, bind-mounted into every job. sccache's
# local disk cache is built for concurrent readers and writers (separate
# sccache servers, one per job), so parallel slots can share it. ci.yml sets
# SCCACHE_DIR to a per-repository subdirectory; "default" is for jobs that do not.
SCCACHE_HOST_DIR=${WORK_MOUNT}/sccache
SCCACHE_CONTAINER_DIR=/var/cache/aap-sccache
SCCACHE_CACHE_SIZE=10G
# SCCACHE_CACHE_SIZE bounds one directory, and any job can create another.
# Before each job the whole tree is measured; over this cap it is wiped.
SCCACHE_TREE_MAX_MB=20480
RUNNER_UID=""
# Interface for the Windows-side supervisor (wsl -d aap-runner -u root --).
# ${RUN_DIR}/drain stops new jobs; ${RUN_DIR}/status.json reports the pool.
# /run is a tmpfs. Not a systemd RuntimeDirectory, which is deleted when the
# unit stops and would take the drain file with it.
RUN_DIR=/run/aap-runner
# The pool loop wakes this often to rewrite status.json and act on a drain.
STATUS_TICK_SECONDS=5
TICK_PID=""
# A runner that is stopped while it has no job stays registered with GitHub
# until deregister_runner deletes it. One retry after this many seconds.
DEREGISTER_RETRY_SECONDS=5
# All deregistrations of one drain or stop together take at most this long,
# well inside the unit's TimeoutStopSec=90.
DEREGISTER_BUDGET_SECONDS=25
# ephemeral-entry.sh registers every runner as aap-crrr-${HOSTNAME}.
RUNNER_NAME_PREFIX=aap-crrr-
# The pool removes ghost runners (offline, idle, aap-crrr-*, no container
# here) at start and then this often, in the background. One pass in flight
# at a time, stopped after DEREGISTER_BUDGET_SECONDS.
REAP_INTERVAL_SECONDS=600
REAP_PID=""
# now_s + interval of the next pass. Empty means never reaped: due now.
REAP_NEXT=""
REAP_STARTED=0
# Per-container cpu and memory, from one docker stats call this often, in
# the background and bounded by SAMPLE_BUDGET_SECONDS. One call in flight.
# ${RUN_DIR}/usage is the last good sample; status_json merges it.
SAMPLE_INTERVAL_SECONDS=10
SAMPLE_BUDGET_SECONDS=20
USAGE_PID=""
# now_s + interval of the next sample. Empty means due now.
USAGE_NEXT=""
USAGE_FAILS=0

# Whole seconds since boot, from /proc/uptime (CLOCK_BOOTTIME). Every timer
# here uses it. SECONDS and date +%s follow the wall clock, and WSL steps
# that backwards after a resume.
now_s() {
  local up
  read -r up _ < /proc/uptime
  printf '%s\n' "${up%%.*}"
}

below_floor() {
  local avail="$1" floor="$2"
  [[ "${avail}" -lt "${floor}" ]]
}

parse_df_gb() {
  awk 'NR==2 { gsub(/G/, "", $1); print $1 }'
}

size_is_work_disk() {
  local size="$1"
  [[ "${size}" =~ ^[0-9]+$ ]] || return 1
  [[ "${WORK_DISK_MIN_GB}" =~ ^[0-9]+$ && "${WORK_DISK_MAX_GB}" =~ ^[0-9]+$ ]] || return 1
  [[ "${size}" -ge "${WORK_DISK_MIN_GB}" && "${size}" -le "${WORK_DISK_MAX_GB}" ]]
}

# Size is not enough. The mount's device must differ from / and its UUID
# must be the one written at install. A ~1000G system disk fails this.
work_mount_matches() {
  local dev="$1" root_dev="$2" mount_uuid="$3" expect_uuid="$4"
  [[ -n "${dev}" && -n "${root_dev}" && "${dev}" != "${root_dev}" ]] || return 1
  [[ "${expect_uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
  [[ "${mount_uuid}" == "${expect_uuid}" ]]
}

assert_work_mount_device() {
  local mount="$1" uuid dev root_dev mount_uuid
  if [[ ! -r "${WORK_DISK_UUID_FILE}" ]]; then
    echo "refusing: ${WORK_DISK_UUID_FILE} is unreadable" >&2
    return 1
  fi
  uuid=$(tr -d '[:space:]' < "${WORK_DISK_UUID_FILE}")
  dev=$(df -P "${mount}" | awk 'NR==2 { print $1 }')
  root_dev=$(df -P / | awk 'NR==2 { print $1 }')
  mount_uuid=$(findmnt -n -o UUID --target "${mount}" 2>/dev/null | tr -d '[:space:]' || true)
  if ! work_mount_matches "${dev}" "${root_dev}" "${mount_uuid}" "${uuid}"; then
    echo "refusing: ${mount} dev=${dev:-missing} uuid=${mount_uuid:-missing}; / is ${root_dev:-missing}; work-disk.uuid=${uuid:-missing}" >&2
    return 1
  fi
}

# At least 55% of the disk. ceil(60 * 55%) is 33, and the 60 GiB disk stays at 35.
disk_floor_gb() {
  local gib="$1" floor
  floor=$(( (gib * 55 + 99) / 100 ))
  if [[ "${gib}" -eq 60 && "${floor}" -lt 35 ]]; then
    floor=35
  fi
  printf '%s\n' "${floor}"
}

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

apply_config_line() {
  local line="$1" key val
  case "${line}" in
    '' | \#*) return 0 ;;
  esac
  if [[ "${line}" == *$'\r'* ]]; then
    echo "config line contains CR" >&2
    return 1
  fi
  key=${line%%=*}
  val=${line#*=}
  case "${key}" in
    AAP_GITHUB_ORG) AAP_GITHUB_ORG=${val} ;;
    AAP_GITHUB_APP_ID) AAP_GITHUB_APP_ID=${val} ;;
    AAP_GITHUB_APP_INSTALLATION_ID) AAP_GITHUB_APP_INSTALLATION_ID=${val} ;;
    AAP_GITHUB_APP_PRIVATE_KEY_PATH) AAP_GITHUB_APP_PRIVATE_KEY_PATH=${val} ;;
    AAP_RUNNER_IMAGE) AAP_RUNNER_IMAGE=${val} ;;
    AAP_RUNNER_LABELS) AAP_RUNNER_LABELS=${val} ;;
    AAP_RUNNER_BASE_LABEL) AAP_RUNNER_BASE_LABEL=${val} ;;
    AAP_RUNNER_EXTRA_LABELS) AAP_RUNNER_EXTRA_LABELS=${val} ;;
    AAP_RUNNER_GROUP) AAP_RUNNER_GROUP=${val} ;;
    AAP_WORK_DISK_GIB) AAP_WORK_DISK_GIB=${val} ;;
    AAP_DISK_FLOOR_GB) AAP_DISK_FLOOR_GB=${val} ;;
    AAP_JOB_MEMORY) AAP_JOB_MEMORY=${val} ;;
    AAP_JOB_CPUS) AAP_JOB_CPUS=${val} ;;
    AAP_JOB_PIDS_LIMIT) AAP_JOB_PIDS_LIMIT=${val} ;;
    AAP_JOB_TIMEOUT_MINUTES) AAP_JOB_TIMEOUT_MINUTES=${val} ;;
    AAP_JOB_IO_PERCENT) AAP_JOB_IO_PERCENT=${val} ;;
    AAP_POOL_SHARING) AAP_POOL_SHARING=${val} ;;
    AAP_RUNNER_COUNT) AAP_RUNNER_COUNT=${val} ;;
    *)
      echo "unknown config key: ${key}" >&2
      return 1
      ;;
  esac
}

load_config() {
  local perms owner line
  perms=$(stat -c '%a' "${CONFIG_PATH}")
  owner=$(stat -c '%u' "${CONFIG_PATH}")
  if [[ "${owner}" != "0" || "${perms}" != "400" ]]; then
    echo "refusing: ${CONFIG_PATH} must be root mode 0400 (found mode ${perms} uid ${owner})" >&2
    exit 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    apply_config_line "${line}"
  done < "${CONFIG_PATH}"
  load_limits
  [[ "${AAP_GITHUB_ORG}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
  [[ "${AAP_GITHUB_APP_ID}" =~ ^[0-9]+$ ]]
  [[ "${AAP_GITHUB_APP_INSTALLATION_ID}" =~ ^[0-9]+$ ]]
  [[ "${AAP_GITHUB_APP_PRIVATE_KEY_PATH}" =~ ^/etc/aap-runner/[A-Za-z0-9._/-]+$ ]]
  if [[ "${AAP_GITHUB_APP_PRIVATE_KEY_PATH}" == *..* ]]; then
    echo "refusing key path that contains .." >&2
    exit 1
  fi
  [[ "${AAP_RUNNER_IMAGE}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:/@-]*$ ]]
  [[ "${AAP_RUNNER_GROUP}" == "aap-crrr" ]]
  finish_disk_bounds
  finish_job_limits
  finish_runner_count
  finish_io_limits
  finish_pool_sharing
  finish_runner_labels
}

# limits.conf overrides five manager.conf keys, then the same checks run on
# the result (count 1..4, the per-slot split, the memory and cpu grammar).
# It holds no App ids and no secrets. Any other key, an empty value, a file
# that is not root's, or a group or world writable mode is refused.
load_limits() {
  local perms owner line key
  [[ -e "${LIMITS_PATH}" ]] || return 0
  if [[ ! -f "${LIMITS_PATH}" ]]; then
    echo "refusing: ${LIMITS_PATH} is not a regular file" >&2
    exit 1
  fi
  perms=$(stat -c '%a' "${LIMITS_PATH}")
  owner=$(stat -c '%u' "${LIMITS_PATH}")
  if [[ "${owner}" != "0" || ! "${perms}" =~ ^[0-7]+$ ]] || ((8#${perms} & 8#022)); then
    echo "refusing: ${LIMITS_PATH} must be root-owned and not group or world writable (found mode ${perms} uid ${owner})" >&2
    exit 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      '' | \#*) continue ;;
    esac
    key=${line%%=*}
    case "${key}" in
      AAP_RUNNER_COUNT | AAP_JOB_CPUS | AAP_JOB_MEMORY | AAP_JOB_IO_PERCENT | AAP_POOL_SHARING) ;;
      *)
        echo "refusing: ${LIMITS_PATH} key ${key} is not AAP_RUNNER_COUNT, AAP_JOB_CPUS, AAP_JOB_MEMORY, AAP_JOB_IO_PERCENT, or AAP_POOL_SHARING" >&2
        exit 1
        ;;
    esac
    if [[ "${line}" != "${key}="?* ]]; then
      echo "refusing: ${LIMITS_PATH} has no value for ${key}" >&2
      exit 1
    fi
    if ! apply_config_line "${line}"; then
      echo "refusing: ${LIMITS_PATH} line for ${key}" >&2
      exit 1
    fi
  done < "${LIMITS_PATH}"
}

# AAP_WORK_DISK_GIB is this host's VHDX size. Absent means 60, which is CRRR.
# A floor below 55% of that size is raised. 60 GiB stays at 35 GB free.
finish_disk_bounds() {
  local min_floor
  [[ -z "${AAP_WORK_DISK_GIB}" ]] && AAP_WORK_DISK_GIB=60
  if [[ ! "${AAP_WORK_DISK_GIB}" =~ ^[1-9][0-9]*$ ]] || [[ "${AAP_WORK_DISK_GIB}" -lt 20 || "${AAP_WORK_DISK_GIB}" -gt 512 ]]; then
    echo "refusing: AAP_WORK_DISK_GIB=${AAP_WORK_DISK_GIB} is not 20..512" >&2
    return 1
  fi
  min_floor=$(disk_floor_gb "${AAP_WORK_DISK_GIB}")
  if [[ -z "${AAP_DISK_FLOOR_GB}" ]]; then
    AAP_DISK_FLOOR_GB=${min_floor}
  fi
  if [[ ! "${AAP_DISK_FLOOR_GB}" =~ ^[0-9]+$ ]]; then
    echo "refusing: AAP_DISK_FLOOR_GB=${AAP_DISK_FLOOR_GB}" >&2
    return 1
  fi
  if [[ "${AAP_DISK_FLOOR_GB}" -lt "${min_floor}" ]]; then
    echo "raising AAP_DISK_FLOOR_GB from ${AAP_DISK_FLOOR_GB} to ${min_floor} (55% of ${AAP_WORK_DISK_GIB} GiB; 60 GiB stays 35)" >&2
    AAP_DISK_FLOOR_GB=${min_floor}
  fi
  WORK_DISK_MIN_GB=$((AAP_WORK_DISK_GIB - 10))
  if [[ "${WORK_DISK_MIN_GB}" -lt 1 ]]; then
    WORK_DISK_MIN_GB=1
  fi
  WORK_DISK_MAX_GB=$((AAP_WORK_DISK_GIB + 4))
}

# Absent keys use the defaults. A present value that is not this grammar is refused.
# Memory is an integer plus one docker suffix. Timeout is 1..1440 minutes.
valid_memory() {
  [[ "$1" =~ ^[1-9][0-9]*[bBkKmMgG]?$ ]]
}

valid_cpus() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v n="$1" 'BEGIN { exit (n > 0 ? 0 : 1) }'
}

valid_pids() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

valid_timeout_minutes() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$1" -le 1440 ]]
}

# AAP_RUNNER_BASE_LABEL is required. crrr or fresh only. There is no default.
# labels.sh checks the lowercase charset before reserved labels and duplicates.
finish_runner_labels() {
  local extra="${AAP_RUNNER_EXTRA_LABELS}" part seen="" expect
  local -a parts=()
  validate_base_label "${AAP_RUNNER_BASE_LABEL}" || return 1
  expect="self-hosted,linux,${AAP_RUNNER_BASE_LABEL}"
  if [[ -z "${AAP_RUNNER_LABELS}" ]]; then
    AAP_RUNNER_LABELS="${expect}"
  elif [[ "${AAP_RUNNER_LABELS}" != "${expect}" ]]; then
    echo "refusing: AAP_RUNNER_LABELS must be ${expect}" >&2
    return 1
  fi
  if [[ -z "${extra}" ]]; then
    return 0
  fi
  IFS=',' read -ra parts <<< "${extra}"
  if [[ "${#parts[@]}" -eq 0 ]]; then
    echo "refusing: AAP_RUNNER_EXTRA_LABELS has no label" >&2
    return 1
  fi
  for part in "${parts[@]}"; do
    extra_label_ok "${part}" "${seen}" || return 1
    seen="${seen:+${seen},}${part}"
  done
  AAP_RUNNER_LABELS="${expect},${seen}"
}

log_runner_labels() {
  echo "runner labels: ${AAP_RUNNER_LABELS}"
}

finish_job_limits() {
  [[ -z "${AAP_JOB_MEMORY}" ]] && AAP_JOB_MEMORY=12g
  [[ -z "${AAP_JOB_CPUS}" ]] && AAP_JOB_CPUS=6
  [[ -z "${AAP_JOB_PIDS_LIMIT}" ]] && AAP_JOB_PIDS_LIMIT=4096
  [[ -z "${AAP_JOB_TIMEOUT_MINUTES}" ]] && AAP_JOB_TIMEOUT_MINUTES=120
  if ! valid_memory "${AAP_JOB_MEMORY}"; then
    echo "refusing: AAP_JOB_MEMORY=${AAP_JOB_MEMORY}" >&2
    return 1
  fi
  if ! valid_cpus "${AAP_JOB_CPUS}"; then
    echo "refusing: AAP_JOB_CPUS=${AAP_JOB_CPUS}" >&2
    return 1
  fi
  if ! valid_pids "${AAP_JOB_PIDS_LIMIT}"; then
    echo "refusing: AAP_JOB_PIDS_LIMIT=${AAP_JOB_PIDS_LIMIT}" >&2
    return 1
  fi
  if ! valid_timeout_minutes "${AAP_JOB_TIMEOUT_MINUTES}"; then
    echo "refusing: AAP_JOB_TIMEOUT_MINUTES=${AAP_JOB_TIMEOUT_MINUTES}" >&2
    return 1
  fi
}

# AAP_RUNNER_COUNT is 1..4 parallel job containers. AAP_JOB_CPUS and
# AAP_JOB_MEMORY are the pool total, split evenly and rounded down to whole
# cpus and whole MiB. A slot under 1 cpu or 1g is refused. One slot keeps the
# configured values verbatim. Runs after finish_job_limits validated them.
finish_runner_count() {
  local num unit mult mib cpus
  [[ -z "${AAP_RUNNER_COUNT+x}" ]] && AAP_RUNNER_COUNT=1
  if [[ ! "${AAP_RUNNER_COUNT}" =~ ^[1-4]$ ]]; then
    echo "refusing: AAP_RUNNER_COUNT=${AAP_RUNNER_COUNT} is not 1..4" >&2
    return 1
  fi
  if [[ "${AAP_RUNNER_COUNT}" -eq 1 ]]; then
    SLOT_CPUS=${AAP_JOB_CPUS}
    SLOT_MEMORY=${AAP_JOB_MEMORY}
    return 0
  fi
  cpus=$(awk -v n="${AAP_JOB_CPUS}" -v c="${AAP_RUNNER_COUNT}" 'BEGIN { print int(n / c) }')
  num=${AAP_JOB_MEMORY%[bBkKmMgG]}
  unit=${AAP_JOB_MEMORY#"${num}"}
  case "${unit}" in
    k | K) mult=1024 ;;
    m | M) mult=$((1024 * 1024)) ;;
    g | G) mult=$((1024 * 1024 * 1024)) ;;
    *) mult=1 ;;
  esac
  # Bash integers are 64-bit. Refuse before num * mult can wrap.
  if [[ "${#num}" -gt 18 ]] || ((num > (1 << 62) / mult)); then
    echo "refusing: AAP_JOB_MEMORY=${AAP_JOB_MEMORY} is too large to split" >&2
    return 1
  fi
  mib=$((num * mult / AAP_RUNNER_COUNT / (1024 * 1024)))
  if [[ "${cpus}" -lt 1 || "${mib}" -lt 1024 ]]; then
    echo "refusing: AAP_RUNNER_COUNT=${AAP_RUNNER_COUNT} splits ${AAP_JOB_CPUS} cpus and ${AAP_JOB_MEMORY} into ${cpus} cpus and ${mib}m per slot; each slot needs 1 cpu and 1g" >&2
    return 1
  fi
  SLOT_CPUS=${cpus}
  if ((mib % 1024 == 0)); then
    SLOT_MEMORY="$((mib / 1024))g"
  else
    SLOT_MEMORY="${mib}m"
  fi
}

# AAP_JOB_IO_PERCENT (0..100, default 90, 0 = no cap) of the measured work
# disk is the pool's IO budget, split evenly over the slots. A slot under 10
# MiB/s is refused. No measurement means no cap, never a failed pool.
# Runs after finish_runner_count.
finish_io_limits() {
  local mbps="" budget
  SLOT_IO_MBPS=0
  POOL_IO_MBPS=0
  [[ -z "${AAP_JOB_IO_PERCENT}" ]] && AAP_JOB_IO_PERCENT=90
  if [[ ! "${AAP_JOB_IO_PERCENT}" =~ ^(0|[1-9][0-9]?|100)$ ]]; then
    echo "refusing: AAP_JOB_IO_PERCENT=${AAP_JOB_IO_PERCENT} is not 0..100" >&2
    return 1
  fi
  [[ "${AAP_JOB_IO_PERCENT}" -eq 0 ]] && return 0
  { read -r mbps < "${WORK_DISK_MBPS_FILE}"; } 2>/dev/null || true
  if [[ ! "${mbps}" =~ ^[1-9][0-9]{0,8}$ ]]; then
    echo "io cap disabled: run aap-runner-manager --measure-io" >&2
    return 0
  fi
  budget=$((mbps * AAP_JOB_IO_PERCENT / 100))
  SLOT_IO_MBPS=$((budget / AAP_RUNNER_COUNT))
  if [[ "${SLOT_IO_MBPS}" -lt 10 ]]; then
    echo "refusing: ${AAP_JOB_IO_PERCENT}% of ${mbps} MiB/s over ${AAP_RUNNER_COUNT} slot(s) is ${SLOT_IO_MBPS} MiB/s per slot; each slot needs 10" >&2
    SLOT_IO_MBPS=0
    return 1
  fi
  POOL_IO_MBPS=${budget}
}

# AAP_POOL_SHARING: slice (default) puts every job in POOL_SLICE, which caps
# the pool total, and lets each job use what the others leave idle. fixed
# gives each slot a hard 1/count share (finish_runner_count, finish_io_limits).
finish_pool_sharing() {
  [[ -z "${AAP_POOL_SHARING}" ]] && AAP_POOL_SHARING=slice
  case "${AAP_POOL_SHARING}" in
    slice | fixed) ;;
    *)
      echo "refusing: AAP_POOL_SHARING=${AAP_POOL_SHARING} is not slice or fixed" >&2
      return 1
      ;;
  esac
}

# systemctl set-property arguments for POOL_SLICE, one per line: the pool
# cpu and memory totals, and the IO budget on IO_DEVICE when there is one.
# Bandwidth is in bytes: systemd's M suffix is 10^6, docker's mb is MiB.
slice_properties() {
  local mem=${AAP_JOB_MEMORY^^} bytes iops
  mem=${mem%B}
  printf 'CPUQuota=%s%%\n' "$(awk -v n="${AAP_JOB_CPUS}" 'BEGIN { printf "%d", n * 100 }')"
  printf 'MemoryMax=%s\n' "${mem}"
  # An empty assignment clears the list, so a cap from an earlier pool or
  # another device never survives. The values that follow are set fresh.
  printf '%s=\n' IOReadBandwidthMax IOWriteBandwidthMax IOReadIOPSMax IOWriteIOPSMax
  if ((POOL_IO_MBPS > 0)) && [[ -n "${IO_DEVICE}" ]]; then
    bytes=$((POOL_IO_MBPS * 1048576))
    iops=$((POOL_IO_MBPS * IO_IOPS_PER_MB))
    printf 'IOReadBandwidthMax=%s %s\n' "${IO_DEVICE}" "${bytes}"
    printf 'IOWriteBandwidthMax=%s %s\n' "${IO_DEVICE}" "${bytes}"
    printf 'IOReadIOPSMax=%s %s\n' "${IO_DEVICE}" "${iops}"
    printf 'IOWriteIOPSMax=%s %s\n' "${IO_DEVICE}" "${iops}"
  fi
}

# At pool start, slice mode only. docker must use the systemd cgroup driver
# for --cgroup-parent to name a slice. set-property overwrites every
# property it names, and slice_properties clears the IO lists first, so a
# smaller pool never keeps old limits. No systemctl revert: it drops the
# drop-ins and systemd re-realizes the slice, and job containers started in
# that window failed at docker start (io.bfq.weight, seen live 2026-10-14).
# The slice is never stopped: it is runtime-only and empties with its jobs.
# Any failure logs and falls back to fixed; it never fails the pool.
setup_pool_sharing() {
  local driver
  local -a props=()
  [[ "${AAP_POOL_SHARING}" == slice ]] || return 0
  driver=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null) || driver=""
  if [[ "${driver}" != systemd ]]; then
    echo "pool sharing: docker cgroup driver is '${driver}', not systemd; using fixed per-slot limits" >&2
    AAP_POOL_SHARING=fixed
    return 0
  fi
  mapfile -t props < <(slice_properties)
  if ! systemctl set-property --runtime "${POOL_SLICE}" "${props[@]}"; then
    echo "pool sharing: could not set ${POOL_SLICE}; using fixed per-slot limits" >&2
    AAP_POOL_SHARING=fixed
    return 0
  fi
  echo "pool sharing: ${POOL_SLICE} ${props[*]}"
  wait_pool_slice
}

# set-property does not start an empty slice, and the slice's cgroup dir can
# outlive an inactive slice, so a probe unit always starts it.
# Then up to 5 s for the slice cgroup to show cpu.max, and io.max with the
# cap when there is one, before any slot starts. A timeout only logs.
wait_pool_slice() {
  local i want=cpu.max
  ((POOL_IO_MBPS > 0)) && [[ -n "${IO_DEVICE}" ]] && want=io.max
  if ! systemd-run --quiet --collect --wait --slice="${POOL_SLICE}" --unit=aap-runner-pool-probe /bin/true; then
    echo "pool sharing: probe unit could not start ${POOL_SLICE}" >&2
  fi
  for ((i = 0; i < 50; i++)); do
    if [[ -f "${POOL_SLICE_CGROUP}/cpu.max" ]]; then
      [[ "${want}" == cpu.max ]] && return 0
      grep -qs 'rbps=' "${POOL_SLICE_CGROUP}/io.max" && return 0
    fi
    sleep 0.1
  done
  echo "pool sharing: ${POOL_SLICE} has no ${want} after 5 s; starting slots anyway" >&2
}

# The whole block device behind the work mount: docker's --device-*-bps
# take a disk, not a partition. Fresh mounts the bare disk (/dev/sde). Any
# failure logs and drops the cap for this pool.
resolve_io_device() {
  local src parent=""
  IO_DEVICE=""
  ((SLOT_IO_MBPS > 0)) || return 0
  src=$(findmnt -n -o SOURCE "${WORK_MOUNT}" 2>/dev/null) || src=""
  if [[ "${src}" =~ [0-9]$ ]]; then
    parent=$(lsblk -no PKNAME "${src}" 2>/dev/null | head -n 1 | tr -d '[:space:]') || parent=""
    [[ -n "${parent}" ]] && src=/dev/${parent}
  fi
  if [[ ! "${src}" =~ ^/dev/[A-Za-z0-9_-]+$ ]]; then
    echo "io cap disabled: no block device for ${WORK_MOUNT} (found '${src}')" >&2
    SLOT_IO_MBPS=0
    POOL_IO_MBPS=0
    return 0
  fi
  IO_DEVICE=${src}
}

# MiB/s from GNU dd's summary line ("N bytes (...) copied, S s, ..."), as an
# integer. docker reads "mb" in --device-*-bps as MiB, so this is MiB too.
dd_mibps() {
  awk '/ bytes .* copied, / { b = $1; for (i = 1; i < NF; i++) if ($i == "copied,") s = $(i + 1) }
    END { if (b > 0 && s > 0) printf "%d\n", b / s / 1048576 }'
}

# --measure-io: 2 GiB direct write, then direct read, of the work disk. The
# lower rate goes to WORK_DISK_MBPS_FILE (one integer, mode 0644).
measure_io() {
  local f="${WORK_MOUNT}/.aap-iobench" avail out w r mbps
  if ! mountpoint -q "${WORK_MOUNT}"; then
    echo "refusing: ${WORK_MOUNT} is not a mountpoint" >&2
    return 1
  fi
  avail=$(df -BM --output=avail "${WORK_MOUNT}" | awk 'NR==2 { gsub(/M/, "", $1); print $1 }')
  if [[ ! "${avail}" =~ ^[0-9]+$ ]] || ((avail < 3072)); then
    echo "refusing: ${WORK_MOUNT} has ${avail:-unknown} MiB free; --measure-io needs 3 GiB" >&2
    return 1
  fi
  if ! out=$(LC_ALL=C dd if=/dev/zero of="${f}" bs=4M count=512 oflag=direct conv=fsync 2>&1); then
    rm -f "${f}"
    echo "refusing: write benchmark failed: ${out}" >&2
    return 1
  fi
  w=$(dd_mibps <<< "${out}")
  if ! out=$(LC_ALL=C dd if="${f}" of=/dev/null bs=4M iflag=direct 2>&1); then
    rm -f "${f}"
    echo "refusing: read benchmark failed: ${out}" >&2
    return 1
  fi
  r=$(dd_mibps <<< "${out}")
  rm -f "${f}"
  if [[ ! "${w}" =~ ^[1-9][0-9]*$ || ! "${r}" =~ ^[1-9][0-9]*$ ]]; then
    echo "refusing: could not read a rate from dd (write '${w}', read '${r}')" >&2
    return 1
  fi
  mbps=$((w < r ? w : r))
  printf '%s\n' "${mbps}" > "${WORK_DISK_MBPS_FILE}.tmp"
  chmod 0644 "${WORK_DISK_MBPS_FILE}.tmp"
  mv -f "${WORK_DISK_MBPS_FILE}.tmp" "${WORK_DISK_MBPS_FILE}"
  echo "write ${w} MiB/s, read ${r} MiB/s" >&2
  echo "work-disk.mbps=${mbps}"
}

# Child is a new session with a clean command, so the registration token
# (an unexported local) is not in its environment. disarm kills the sleep
# before it can stop the container.
arm_wall_clock() {
  local seconds="$1" name="$2"
  if ! command -v setsid >/dev/null 2>&1; then
    echo "refusing: setsid is required for the job wall clock" >&2
    return 1
  fi
  # Single quotes on purpose: this shell must not expand the clock's $1/$2.
  # shellcheck disable=SC2016
  setsid bash -c '
    sleep "$1"
    echo "wall clock ${1}s elapsed; stopping $2" >&2
    docker stop -t 20 "$2" || true
    docker rm -f "$2" || true
  ' _ "${seconds}" "${name}" >/dev/null &
  echo $!
}

disarm_wall_clock() {
  local pid="$1"
  if [[ -z "${pid}" ]]; then
    return 0
  fi
  kill -- "-${pid}" 2>/dev/null || kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
}

check_key() {
  local perms owner
  perms=$(stat -c '%a' "${AAP_GITHUB_APP_PRIVATE_KEY_PATH}")
  owner=$(stat -c '%u' "${AAP_GITHUB_APP_PRIVATE_KEY_PATH}")
  if [[ "${owner}" != "0" || "${perms}" != "400" ]]; then
    echo "refusing: app private key must be root mode 0400" >&2
    exit 1
  fi
}

mount_source_forbidden() {
  case "$1" in
    /mnt | /mnt/ | /mnt/*) return 0 ;;
    *) return 1 ;;
  esac
}

assert_no_mnt_mounts() {
  local name="$1" source bind
  while IFS= read -r source; do
    if [[ -n "${source}" ]] && mount_source_forbidden "${source}"; then
      echo "refusing: mount source ${source} is /mnt or under /mnt" >&2
      return 1
    fi
  done < <(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}{{range .HostConfig.Mounts}}{{println .Source}}{{end}}' "${name}")
  while IFS= read -r bind; do
    [[ -z "${bind}" ]] && continue
    source=${bind%%:*}
    if mount_source_forbidden "${source}"; then
      echo "refusing: bind ${bind} is /mnt or under /mnt" >&2
      return 1
    fi
  done < <(docker inspect --format '{{range .HostConfig.Binds}}{{println .}}{{end}}' "${name}")
}

disk_ok() {
  local avail size
  if ! mountpoint -q "${WORK_MOUNT}"; then
    echo "refusing to start a job: ${WORK_MOUNT} is not a mountpoint" >&2
    return 1
  fi
  if ! assert_work_mount_device "${WORK_MOUNT}"; then
    return 1
  fi
  avail=$(df -BG --output=avail "${WORK_MOUNT}" | parse_df_gb)
  size=$(df -BG --output=size "${WORK_MOUNT}" | parse_df_gb)
  if [[ ! "${avail}" =~ ^[0-9]+$ ]]; then
    echo "refusing to start a job: df avail of ${WORK_MOUNT} was not numeric" >&2
    return 1
  fi
  if ! size_is_work_disk "${size}"; then
    echo "refusing to start a job: ${WORK_MOUNT} is ${size:-unknown}G; the work disk is ${AAP_WORK_DISK_GIB}G (${WORK_DISK_MIN_GB}-${WORK_DISK_MAX_GB})" >&2
    return 1
  fi
  if below_floor "${avail}" "${AAP_DISK_FLOOR_GB}"; then
    echo "refusing to start a job: ${avail}G free on ${WORK_MOUNT}; floor is ${AAP_DISK_FLOOR_GB}G" >&2
    return 1
  fi
  echo "disk floor ok: ${avail}G free on ${WORK_MOUNT} (${size}G filesystem)"
}

# App JWT, then an installation token. The App's
# organization_self_hosted_runners permission covers the registration token,
# the runner list, and runner delete.
mint_installation_token() {
  local now iat exp header payload sig jwt
  now=$(date +%s)
  iat=$((now - 30))
  exp=$((now + 480))
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "${iat}" "${exp}" "${AAP_GITHUB_APP_ID}" | b64url)
  sig=$(printf '%s' "${header}.${payload}" | openssl dgst -binary -sha256 -sign "${AAP_GITHUB_APP_PRIVATE_KEY_PATH}" | b64url)
  jwt="${header}.${payload}.${sig}"
  auth_header "${jwt}" | curl --silent --show-error --fail \
    --connect-timeout 5 --max-time 15 \
    -X POST \
    -H @- \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${AAP_GITHUB_APP_INSTALLATION_ID}/access_tokens" \
    | jq -er '.token'
}

# Every bearer token reaches curl on stdin (-H @-), never in its argv, so it
# is not in /proc/<pid>/cmdline. printf is a builtin: no process carries it.
auth_header() {
  printf 'Authorization: Bearer %s\n' "$1"
}

mint_registration_token() {
  local installation_token
  installation_token=$(mint_installation_token) || return 1
  auth_header "${installation_token}" | curl --silent --show-error --fail \
    --connect-timeout 5 --max-time 15 \
    -X POST \
    -H @- \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${AAP_GITHUB_ORG}/actions/runners/registration-token" \
    | jq -er '.token'
}

# ephemeral-entry.sh registers the runner as aap-crrr-${HOSTNAME}. docker
# create sets no --hostname, so that is docker's default, the first 12 hex
# of the container id: the runner name is not the container name. Read it
# before the container is removed.
runner_name_of() {
  local host
  [[ -n "${1:-}" ]] || return 1
  host=$(docker inspect --format '{{.Config.Hostname}}' "$1" 2>/dev/null) || return 1
  [[ "${host}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || return 1
  printf '%s%s\n' "${RUNNER_NAME_PREFIX}" "${host}"
}

# One attempt. A runner that is not listed, or a DELETE that returns 404, is
# already gone. The token goes to curl on stdin (auth_header).
deregister_runner_once() {
  local name="$1" token id
  token=$(mint_installation_token) || return 1
  id=$(auth_header "${token}" | curl --silent --show-error --fail \
    --connect-timeout 5 --max-time 10 -G \
    -H @- \
    -H "Accept: application/vnd.github+json" \
    --data-urlencode "name=${name}" \
    "https://api.github.com/orgs/${AAP_GITHUB_ORG}/actions/runners" \
    | jq -r --arg n "${name}" '[.runners[]? | select(.name == $n) | .id][0] // empty') || return 1
  if [[ -z "${id}" ]]; then
    echo "runner ${name} is not registered"
    return 0
  fi
  [[ "${id}" =~ ^[0-9]+$ ]] || return 1
  delete_runner_id "${token}" "${name}" "${id}"
}

# DELETE TOKEN NAME ID. 204 and 404 mean the runner is gone.
delete_runner_id() {
  local token="$1" name="$2" id="$3" code
  code=$(auth_header "${token}" | curl --silent --show-error \
    --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' \
    -X DELETE \
    -H @- \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${AAP_GITHUB_ORG}/actions/runners/${id}") || code=""
  case "${code}" in
    204 | 404)
      echo "deregistered runner ${name} (id ${id}, HTTP ${code})"
      return 0
      ;;
  esac
  echo "warning: DELETE of runner ${name} (id ${id}) returned HTTP ${code:-none}" >&2
  return 1
}

# Ghost runners: offline, not busy, named aap-crrr-*, labelled with this
# host's AAP_RUNNER_BASE_LABEL (another host in the org shares the prefix,
# not the base label), and no container here
# (docker ps -a, plus the slot files) has that hostname. A listener killed
# without deregistering leaves one: older managers, or a SIGTERM mid-job.
# The list is read before the containers, so a runner that registered after
# the docker snapshot is not in it. docker failing means no snapshot, and
# nothing is deleted. Never fails the caller.
reap_ghost_runners() {
  local token body n page=1 line id name reaped=0 f
  local -a cands=()
  local -A live=()
  if [[ -z "${AAP_RUNNER_BASE_LABEL}" ]]; then
    echo "warning: ghost reap: no base label; reaping nothing" >&2
    return 0
  fi
  if ! token=$(mint_installation_token); then
    echo "warning: ghost reap: no installation token; reaping nothing" >&2
    return 0
  fi
  while ((page <= 10)); do
    if ! body=$(auth_header "${token}" | curl --silent --show-error --fail \
      --connect-timeout 5 --max-time 15 -G \
      -H @- \
      -H "Accept: application/vnd.github+json" \
      --data-urlencode "per_page=100" \
      --data-urlencode "page=${page}" \
      "https://api.github.com/orgs/${AAP_GITHUB_ORG}/actions/runners") \
      || ! n=$(jq -er '.runners | length' <<< "${body}"); then
      echo "warning: ghost reap: could not list runners (page ${page}); reaping nothing" >&2
      return 0
    fi
    mapfile -t -O "${#cands[@]}" cands < <(jq -r --arg p "${RUNNER_NAME_PREFIX}" --arg l "${AAP_RUNNER_BASE_LABEL}" \
      '.runners[] | select((.name | startswith($p)) and .status == "offline" and .busy == false
        and any((.labels // [])[]; .name == $l))
        | "\(.id) \(.name)"' <<< "${body}")
    ((n >= 100)) || break
    page=$((page + 1))
  done
  if ! body=$(docker ps -aq); then
    echo "warning: ghost reap: docker ps failed; reaping nothing" >&2
    return 0
  fi
  for f in "${RUN_DIR}"/slot-[1-9]; do
    [[ -f "${f}" ]] && body+=$'\n'$(slot_container "${f##*slot-}")
  done
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    name=$(runner_name_of "${id}") && live["${name}"]=1
  done <<< "${body}"
  for line in "${cands[@]}"; do
    id=${line%% *}
    name=${line#* }
    [[ "${id}" =~ ^[0-9]+$ && "${name}" =~ ^${RUNNER_NAME_PREFIX}[A-Za-z0-9.-]+$ ]] || continue
    [[ -z "${live[${name}]:-}" ]] || continue
    delete_runner_id "${token}" "${name}" "${id}" && reaped=$((reaped + 1))
  done
  echo "reaped ${reaped} ghost runners"
}

# From the pool loop: starts a reap pass every REAP_INTERVAL_SECONDS, in the
# background so a slow API never holds the tick. A pass still running after
# DEREGISTER_BUDGET_SECONDS, or when a drain starts, is stopped. Skipped
# without an installation id (tests that source this file make no API call).
tick_reap() {
  if [[ -n "${REAP_PID}" ]]; then
    if kill -0 "${REAP_PID}" 2>/dev/null; then
      if ! draining && (($(now_s) - REAP_STARTED < DEREGISTER_BUDGET_SECONDS)); then
        return 0
      fi
      echo "warning: ghost reap stopped (drain, or over ${DEREGISTER_BUDGET_SECONDS}s)" >&2
      kill "${REAP_PID}" 2>/dev/null || true
    fi
    wait "${REAP_PID}" 2>/dev/null || true
    REAP_PID=""
  fi
  [[ "${AAP_GITHUB_APP_INSTALLATION_ID}" =~ ^[0-9]+$ ]] || return 0
  if draining || { [[ -n "${REAP_NEXT}" ]] && (($(now_s) < REAP_NEXT)); }; then
    return 0
  fi
  REAP_STARTED=$(now_s)
  REAP_NEXT=$((REAP_STARTED + REAP_INTERVAL_SECONDS))
  {
    trap - EXIT TERM INT
    reap_ghost_runners
  } &
  REAP_PID=$!
}

# docker stats lines "NAME<tab>CPUPerc<tab>MemUsage" on stdin. Prints
# "SLOT NAME CORES GIB" for each container a slot file names: CORES is
# CPUPerc / 100 and GIB the used memory, both to 1 decimal, or - when
# docker gave no number. Other containers are skipped.
usage_lines() {
  local f name cpu mem
  local -A slot_of=()
  for f in "${RUN_DIR}"/slot-[1-9]; do
    name=""
    { read -r _ _ name _ < "${f}"; } 2>/dev/null || true
    [[ -n "${name}" && "${name}" != - ]] && slot_of[${name}]=${f##*-}
  done
  while IFS=$'\t' read -r name cpu mem; do
    [[ -n "${name}" && -n "${slot_of[${name}]:-}" ]] || continue
    printf '%s\t%s\t%s\t%s\n' "${slot_of[${name}]}" "${name}" "${cpu}" "${mem%% / *}"
  done | awk -F'\t' '
    function gib(s,  n, u) {
      if (s !~ /^[0-9.]+(B|KiB|MiB|GiB|TiB)$/) return "-"
      n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
      if (u == "B") n /= 1073741824
      else if (u == "KiB") n /= 1048576
      else if (u == "MiB") n /= 1024
      else if (u == "TiB") n *= 1024
      return sprintf("%.1f", n)
    }
    { c = ($3 ~ /^[0-9.]+%$/) ? sprintf("%.1f", $3 / 100) : "-"; print $1, $2, c, gib($4) }'
}

# One usage sample into ${RUN_DIR}/usage: the sample time in Unix seconds,
# then usage_lines. A failed docker stats leaves the previous file.
sample_usage() {
  local out tmp="${RUN_DIR}/usage.tmp.${BASHPID}"
  out=$(timeout "${SAMPLE_BUDGET_SECONDS}" docker stats --no-stream \
    --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null) || return 1
  if { date +%s && usage_lines <<< "${out}"; } > "${tmp}" 2>/dev/null; then
    mv -f "${tmp}" "${RUN_DIR}/usage" 2>/dev/null || true
  fi
  rm -f "${tmp}" 2>/dev/null || true
  write_status
}

# From the pool loop: starts sample_usage every SAMPLE_INTERVAL_SECONDS in
# the background, like tick_reap. A failure is logged once per 10.
tick_usage() {
  local rc=0
  [[ -d "${RUN_DIR}" ]] || return 0
  if [[ -n "${USAGE_PID}" ]]; then
    kill -0 "${USAGE_PID}" 2>/dev/null && return 0
    wait "${USAGE_PID}" 2>/dev/null || rc=$?
    USAGE_PID=""
    if ((rc != 0)); then
      USAGE_FAILS=$((USAGE_FAILS + 1))
      if ((USAGE_FAILS % 10 == 1)); then
        echo "warning: docker stats failed (${USAGE_FAILS} so far); keeping the previous usage sample" >&2
      fi
    fi
  fi
  if [[ -n "${USAGE_NEXT}" ]] && (($(now_s) < USAGE_NEXT)); then
    return 0
  fi
  USAGE_NEXT=$(($(now_s) + SAMPLE_INTERVAL_SECONDS))
  {
    trap - EXIT TERM INT
    sample_usage
  } &
  USAGE_PID=$!
}

# Deletes a runner registration by name. Never fails the caller: a failure
# after one retry is logged and the runner stays registered, offline.
deregister_runner() {
  if deregister_runner_once "$1"; then
    return 0
  fi
  sleep "${DEREGISTER_RETRY_SECONDS}"
  if deregister_runner_once "$1"; then
    return 0
  fi
  echo "warning: could not deregister runner $1; it stays registered, offline" >&2
  return 0
}

# Every name in parallel. Whatever is still running after
# DEREGISTER_BUDGET_SECONDS is killed and logged. The pids are kept in
# DEREG_PIDS so a SIGTERM that lands mid-batch (stop_pool) can take them over.
deregister_runners() {
  local pid alive deadline name
  [[ "$#" -gt 0 ]] || return 0
  for name in "$@"; do
    deregister_runner "${name}" &
    DEREG_PIDS+=("$!")
    DEREG_NAMES+=("${name}")
  done
  deadline=$(($(now_s) + DEREGISTER_BUDGET_SECONDS))
  while (($(now_s) < deadline)); do
    alive=0
    for pid in "${DEREG_PIDS[@]}"; do
      if kill -0 "${pid}" 2>/dev/null; then
        alive=1
      fi
    done
    ((alive)) || break
    sleep 0.2
  done
  for pid in "${DEREG_PIDS[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      echo "warning: deregistration took over ${DEREGISTER_BUDGET_SECONDS}s; stopped it" >&2
      kill "${pid}" 2>/dev/null || true
    fi
  done
  wait "${DEREG_PIDS[@]}" 2>/dev/null || true
  DEREG_PIDS=()
  DEREG_NAMES=()
}

# Removes only this job's container, its anonymous volumes, and its network.
# No label-wide prune here: another slot's network has no endpoints between
# docker create and docker start, and a prune would delete it.
# remove_job_containers prunes at startup and stop, when no slot is running.
cleanup_job() {
  local name="$1" net="$2"
  docker rm -f -v "${name}" || true
  docker network rm "${net}" || true
}

# du rounds up to whole MiB. rm keeps the top directory and its owner.
bound_sccache_tree() {
  local used
  [[ -d "${SCCACHE_HOST_DIR}" ]] || return 0
  used=$(du -sm "${SCCACHE_HOST_DIR}" 2>/dev/null | awk '{ print $1 }')
  if [[ "${used}" =~ ^[0-9]+$ && "${used}" -gt "${SCCACHE_TREE_MAX_MB}" ]]; then
    echo "sccache tree ${SCCACHE_HOST_DIR} is ${used} MiB, over ${SCCACHE_TREE_MAX_MB}; wiping it" >&2
    rm -rf "${SCCACHE_HOST_DIR:?}"/*
  fi
}

# Slots start in the same second under one manager PID, so the slot index
# keeps container and network names unique.
job_name() {
  printf 'aap-crrr-%s-%s-%s\n' "$1" "$(date +%s)" "$$"
}

run_one() {
  local slot="$1" token="" name net rc=1 killer="" seconds=0 runner="" errf="" try
  local -a lim=()
  name=$(job_name "${slot}")
  net="${name}"
  # set -e does not apply inside this function: the loop calls it from `if`.
  # disk_ok passed just before this, so the cache dir is on the work disk.
  bound_sccache_tree
  if ! install -d -o "${RUNNER_UID}" -m 0700 "${SCCACHE_HOST_DIR}"; then
    echo "refusing to start a job: could not create ${SCCACHE_HOST_DIR}" >&2
    return 1
  fi
  if ! docker network create --label aap-crrr-job=1 "${net}"; then
    return 1
  fi
  # slice: the pool totals are the slice's caps; each container may use up to
  # all of them, with an equal soft memory share. fixed: hard 1/count shares.
  if [[ "${AAP_POOL_SHARING}" == slice ]]; then
    lim=(--cgroup-parent "${POOL_SLICE}"
      --memory "${AAP_JOB_MEMORY}"
      --memory-swap "${AAP_JOB_MEMORY}"
      --memory-reservation "${SLOT_MEMORY}"
      --cpus "${AAP_JOB_CPUS}")
  else
    lim=(--memory "${SLOT_MEMORY}" --memory-swap "${SLOT_MEMORY}" --cpus "${SLOT_CPUS}")
    if ((SLOT_IO_MBPS > 0)) && [[ -n "${IO_DEVICE}" ]]; then
      lim+=(--device-read-bps "${IO_DEVICE}:${SLOT_IO_MBPS}mb"
        --device-write-bps "${IO_DEVICE}:${SLOT_IO_MBPS}mb"
        --device-read-iops "${IO_DEVICE}:$((SLOT_IO_MBPS * IO_IOPS_PER_MB))"
        --device-write-iops "${IO_DEVICE}:$((SLOT_IO_MBPS * IO_IOPS_PER_MB))")
    fi
  fi
  # One bind mount, the sccache dir on the work disk. No -v, no /mnt.
  # assert_no_mnt_mounts rejects a source under /mnt even if the daemon adds
  # one. /mnt/wsl is the shared docker-desktop tmpfs.
  if ! docker create \
    --runtime=sysbox-runc \
    --interactive \
    --name "${name}" \
    --network "${net}" \
    "${lim[@]}" \
    --cpu-shares "${CPU_SHARES}" \
    --pids-limit "${AAP_JOB_PIDS_LIMIT}" \
    --label aap-crrr-job=1 \
    --label "aap-crrr-slot=${slot}" \
    --env "AAP_GITHUB_ORG=${AAP_GITHUB_ORG}" \
    --env "AAP_RUNNER_LABELS=${AAP_RUNNER_LABELS}" \
    --env "AAP_RUNNER_GROUP=${AAP_RUNNER_GROUP}" \
    --env "AAP_WORK_DISK_GIB=${AAP_WORK_DISK_GIB}" \
    --env "AAP_DISK_FLOOR_GB=${AAP_DISK_FLOOR_GB}" \
    --mount "type=bind,source=${SCCACHE_HOST_DIR},target=${SCCACHE_CONTAINER_DIR}" \
    --env "RUSTC_WRAPPER=sccache" \
    --env "SCCACHE_DIR=${SCCACHE_CONTAINER_DIR}/default" \
    --env "SCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE}" \
    "${AAP_RUNNER_IMAGE}"; then
    docker network rm "${net}" || true
    return 1
  fi
  if ! assert_no_mnt_mounts "${name}"; then
    cleanup_job "${name}" "${net}"
    return 1
  fi
  log_runner_labels
  # Drain: the container is created but not started, so nothing registered.
  if draining; then
    cleanup_job "${name}" "${net}"
    return 0
  fi
  if ! token="$(mint_registration_token)"; then
    cleanup_job "${name}" "${net}"
    return 1
  fi
  seconds=$((AAP_JOB_TIMEOUT_MINUTES * 60))
  if ! killer=$(arm_wall_clock "${seconds}" "${name}") || ! kill -0 "${killer}" 2>/dev/null; then
    token=""
    unset token
    cleanup_job "${name}" "${net}"
    return 1
  fi
  set_slot_state "${slot}" starting "${name}"
  # docker start's stderr is also kept in errf; the subshell waits for tee, so
  # errf is complete when the pipeline returns. One retry, only for the slice
  # start race: runc found the new scope's io files missing and nothing ran.
  errf=$(mktemp)
  for try in 1 2; do
    set +e
    printf '%s\n' "${token}" | (
      docker start --attach --interactive "${name}" 2> >(tee "${errf}" >&2)
      r=$?
      wait "$!"
      exit "${r}"
    ) | watch_runner_output "${slot}" "${name}"
    rc=${PIPESTATUS[1]}
    set -e
    if ((rc == 0 || try == 2)) || ! grep -q 'io.bfq.weight' "${errf}"; then
      break
    fi
    echo "slot ${slot}: slice start race, retrying" >&2
    sleep 2
  done
  rm -f "${errf}"
  token=""
  unset token
  disarm_wall_clock "${killer}"
  # A runner that ended without a job (the wall clock, or a listener that
  # exited) is still registered. GitHub removes it only after a job.
  runner=""
  case "$(slot_state "${slot}")" in
    starting | listening) runner=$(runner_name_of "${name}") || runner="" ;;
  esac
  cleanup_job "${name}" "${net}"
  if [[ -n "${runner}" ]]; then
    deregister_runner "${runner}"
  fi
  # A container that died mid-job never printed its completed line.
  case "$(slot_state "${slot}")" in
    running | listening) set_slot_state "${slot}" idle ;;
  esac
  return "${rc}"
}

# The listener's own terminal lines, from actions/runner v2.338.0 (the
# version the Dockerfile installs), each after a "{DateTime.UtcNow:u}: "
# prefix. No GitHub API call and no token:
#   src/Runner.Listener/Runner.cs:491         Listening for Jobs
#   src/Runner.Listener/JobDispatcher.cs:378  Running job: {JobDisplayName}
#   src/Runner.Listener/JobDispatcher.cs:591  Job {JobDisplayName} completed with result: {result}
# Every line is passed through, so the journal keeps the runner output.
watch_runner_output() {
  local slot="$1" container="${2:-}" line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '%s\n' "${line}"
    case "${line}" in
      *': Running job: '*)
        set_slot_state "${slot}" running "${container}" "${line#*: Running job: }"
        if [[ -n "${container}" ]]; then
          discover_job_run "${slot}" "${container}" "$(slot_ns "${slot}")" > /dev/null 2>&1 &
        fi
        ;;
      *': Listening for Jobs'*) set_slot_state "${slot}" listening "${container}" ;;
      *' completed with result: '*) set_slot_state "${slot}" idle ;;
    esac
  done
}

draining() {
  [[ -e "${RUN_DIR}/drain" ]]
}

# ${RUN_DIR}/slot-N is one line: state, the time it was set in ns, the
# container name (- for none), and the job name. state is starting (no
# runner listening yet), listening (registered, no job), running, or idle
# (between containers). Written to a temp file and renamed. Status is
# observability: no write here may fail a job. Without ${RUN_DIR} (tests
# that do not set it) nothing is written.
# set_slot_state SLOT STATE [CONTAINER] [JOB]
set_slot_state() {
  local f="${RUN_DIR}/slot-$1"
  [[ -d "${RUN_DIR}" ]] || return 0
  [[ "$2" == running ]] || rm -f "${f}.run" 2>/dev/null || true
  if ! { printf '%s %s %s %s\n' "$2" "$(date +%s%N)" "${3:--}" "${4:-}" > "${f}.tmp.${BASHPID}" \
    && mv -f "${f}.tmp.${BASHPID}" "${f}"; } 2>/dev/null; then
    rm -f "${f}.tmp.${BASHPID}" 2>/dev/null || true
  fi
  write_status
}

slot_state() {
  local st=""
  { read -r st _ < "${RUN_DIR}/slot-$1"; } 2>/dev/null || true
  printf '%s\n' "${st}"
}

slot_container() {
  local c=""
  { read -r _ _ c _ < "${RUN_DIR}/slot-$1"; } 2>/dev/null || true
  [[ "${c}" == - ]] && c=""
  printf '%s\n' "${c}"
}

# The ns stamp of the slot's current state: one job start has one stamp.
slot_ns() {
  local ns=""
  { read -r _ ns _ < "${RUN_DIR}/slot-$1"; } 2>/dev/null || true
  printf '%s\n' "${ns}"
}

# KEY=value lines (the job processes' environment) on stdin. Exit 1 when
# there is no GITHUB_RUN_ID yet. Otherwise exit 0 and print "REPO RUN_URL"
# only when the server is https://github.com, the repo is owner/name, the
# run id is digits, and no key has two different values; else print nothing.
job_run_from_env() {
  local line key val server="" repo="" run="" bad=0 seen=0
  while IFS= read -r line; do
    key=${line%%=*}
    val=${line#*=}
    case "${key}" in
      GITHUB_SERVER_URL)
        [[ -z "${server}" || "${server}" == "${val}" ]] || bad=1
        server=${val}
        ;;
      GITHUB_REPOSITORY)
        [[ -z "${repo}" || "${repo}" == "${val}" ]] || bad=1
        repo=${val}
        ;;
      GITHUB_RUN_ID)
        [[ -z "${run}" || "${run}" == "${val}" ]] || bad=1
        run=${val}
        seen=1
        ;;
    esac
  done
  ((seen)) || return 1
  if ((bad == 0)) && [[ "${server}" == https://github.com \
    && "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
    && "/${repo}/" != *"/./"* && "/${repo}/" != *"/../"* \
    && "${run}" =~ ^[0-9]+$ ]]; then
    printf '%s https://github.com/%s/actions/runs/%s\n' "${repo}" "${repo}" "${run}"
  fi
  return 0
}

# The job's repository and run URL, from the Runner.Worker and step
# processes' environment inside the container (the Listener has none). No
# GitHub token. Retries every 5 s while the slot still runs this job (service
# containers delay the step processes by a minute or more), at most 120 tries
# (10 min), each bounded by timeout 10. Written
# to slot-N.run as "NS REPO RUN_URL"; NS ties it to this job start, so a
# result that lands after the job ended is never published. Never fails.
discover_job_run() {
  local slot="$1" container="$2" ns="$3" env out i
  [[ -n "${ns}" ]] || return 0
  for ((i = 1; i <= 120; i++)); do
    [[ "$(slot_ns "${slot}")" == "${ns}" ]] || return 0
    # The container's sh expands $p, not this shell.
    # shellcheck disable=SC2016
    env=$(timeout 10 docker exec "${container}" sh -c 'for p in /proc/[0-9]*; do tr "\0" "\n" < "$p/environ" 2>/dev/null | grep -E "^(GITHUB_REPOSITORY|GITHUB_RUN_ID|GITHUB_SERVER_URL|GITHUB_JOB)=" ; done | sort -u' 2>/dev/null) || env=""
    if out=$(job_run_from_env <<< "${env}"); then
      [[ "$(slot_ns "${slot}")" == "${ns}" ]] || return 0
      if printf '%s %s\n' "${ns}" "${out}" > "${RUN_DIR}/slot-${slot}.run.tmp.${BASHPID}" 2>/dev/null; then
        mv -f "${RUN_DIR}/slot-${slot}.run.tmp.${BASHPID}" "${RUN_DIR}/slot-${slot}.run" 2>/dev/null || true
      fi
      write_status
      return 0
    fi
    ((i < 120)) && sleep 5
  done
  return 0
}

# state: draining while the drain file exists, else running while a slot has
# a job, else idle once a slot listens, else starting. job: the most
# recently started running job, or "". repo and run_url: that job's, once
# discover_job_run found them, else "". runner_count: AAP_RUNNER_COUNT. job_cpus and job_memory: the pool totals as configured,
# after limits.conf. job_io_mbps: the per-slot IO share in MiB/s, 0 for none.
# sharing: slice or fixed, as the pool runs (fixed after a fallback).
# job_cpus is a JSON number and may be fractional (2.5)
# when manager.conf says so; the supervisor treats a non-integer as unknown.
# Paused is a Windows-side state and never appears here.
# Schema 3 adds sampled_at (the usage sample's time, null before one),
# pool (usage summed over the slots, and the IO cap applied to the pool,
# null for none), and slots, one entry per configured slot (schema 2's
# slots was the count; runner_count still carries it). A slot is
# retired, else draining while the drain file exists, else running or
# starting, else idle. Its cpu_cores and mem_gib come from the sample only
# while the sample names the slot's current container. job_url is null.
status_json() {
  local slot f st ns cname name sst sjob srepo srun started cpu mem pio=""
  local busy=0 idle=0 best=-1 job="" state=starting sampled="" u n c g
  local rns rrepo rurl repo="" run_url=""
  local -a args=()
  local -A uname_of=() ucpu_of=() umem_of=()
  {
    read -r sampled
    while read -r u n c g; do
      uname_of[${u}]=${n}
      ucpu_of[${u}]=${c}
      umem_of[${u}]=${g}
    done
  } 2>/dev/null < "${RUN_DIR}/usage" || true
  [[ "${sampled}" =~ ^[0-9]+$ ]] || sampled=""
  for ((slot = 1; slot <= ${AAP_RUNNER_COUNT:-1}; slot++)); do
    f="${RUN_DIR}/slot-${slot}"
    st="" ns="" cname="" name="" sjob="" srepo="" srun="" started="" cpu="" mem=""
    { read -r st ns cname name < "${f}"; } 2>/dev/null || true
    [[ "${ns}" =~ ^[0-9]+$ ]] || ns=0
    case "${st}" in
      running)
        busy=$((busy + 1))
        sjob=${name}
        started=$((ns / 1000000000))
        rns="" rrepo="" rurl=""
        { read -r rns rrepo rurl _ < "${f}.run"; } 2>/dev/null || true
        if [[ "${rns}" == "${ns}" ]]; then
          srepo=${rrepo}
          srun=${rurl}
        fi
        if ((ns > best)); then
          best=${ns}
          job=${sjob}
          repo=${srepo}
          run_url=${srun}
        fi
        sst=running
        ;;
      listening | idle)
        idle=$((idle + 1))
        sst=idle
        ;;
      starting | retired) sst=${st} ;;
      *) sst=idle ;;
    esac
    if [[ "${sst}" != retired ]] && draining; then
      sst=draining
    fi
    if [[ -n "${cname}" && "${cname}" != - && "${uname_of[${slot}]:-}" == "${cname}" ]]; then
      [[ "${ucpu_of[${slot}]}" =~ ^[0-9]+\.[0-9]$ ]] && cpu=${ucpu_of[${slot}]}
      [[ "${umem_of[${slot}]}" =~ ^[0-9]+\.[0-9]$ ]] && mem=${umem_of[${slot}]}
    fi
    args+=("${slot}" "${sst}" "${sjob}" "${srepo}" "${srun}" "${started}" "${cpu}" "${mem}")
  done
  if draining; then
    state=draining
  elif ((busy > 0)); then
    state=running
  elif ((idle > 0)); then
    state=idle
  fi
  # The IO cap in force: the slice's budget, or each slot's share times the
  # slots. None without a device.
  if [[ -n "${IO_DEVICE}" ]]; then
    if [[ "${AAP_POOL_SHARING}" == slice ]]; then
      ((POOL_IO_MBPS > 0)) && pio=${POOL_IO_MBPS}
    elif ((SLOT_IO_MBPS > 0)); then
      pio=$((SLOT_IO_MBPS * ${AAP_RUNNER_COUNT:-1}))
    fi
  fi
  jq -cn --arg state "${state}" --arg job "${job}" --arg repo "${repo}" --arg run_url "${run_url}" --argjson slots "${AAP_RUNNER_COUNT:-1}" \
    --argjson busy "${busy}" --argjson updated "$(date +%s)" \
    --arg cpus "${AAP_JOB_CPUS}" --arg memory "${AAP_JOB_MEMORY}" --argjson io "${SLOT_IO_MBPS:-0}" \
    --arg sharing "$([[ "${AAP_POOL_SHARING}" == slice ]] && echo slice || echo fixed)" \
    --arg sampled "${sampled}" --arg pio "${pio}" \
    'def num: if . == "" then null else tonumber end;
     def total(f): [.[] | f // 0] | add // 0 | . * 10 | round / 10;
     $ARGS.positional as $p
     | [range(0; $p | length; 8) as $i | $p[$i:$i + 8]
        | {slot: (.[0] | tonumber), state: .[1], job: .[2], repo: .[3], run_url: .[4], job_url: null,
           started_at: (.[5] | num), cpu_cores: (.[6] | num), mem_gib: (.[7] | num)}] as $s
     | {state: $state, job: $job, repo: $repo, run_url: $run_url, busy: $busy, updated: $updated,
        runner_count: $slots, job_cpus: ($cpus | tonumber? // null), job_memory: $memory, job_io_mbps: $io, sharing: $sharing,
        schema: 3, sampled_at: ($sampled | num),
        pool: {cpu_cores: ($s | total(.cpu_cores)), mem_gib: ($s | total(.mem_gib)), io_mbps: ($pio | num)},
        slots: $s}' --args "${args[@]}"
}

# status.json, mode 0644, replaced by rename so a reader never sees half a
# file. Slots and the pool loop all write it; the flock orders them so the
# last rename carries the newest slot states.
write_status() {
  local tmp="${RUN_DIR}/status.json.tmp.${BASHPID}"
  [[ -d "${RUN_DIR}" ]] || return 0
  if ! (
    flock -w 5 9 || exit 1
    status_json > "${tmp}" && chmod 0644 "${tmp}" && mv -f "${tmp}" "${RUN_DIR}/status.json"
  ) 2>/dev/null 9> "${RUN_DIR}/status.lock"; then
    rm -f "${tmp}" 2>/dev/null || true
    echo "warning: could not write ${RUN_DIR}/status.json" >&2
  fi
  return 0
}

self_check() {
  local got killer="" sample
  labels_self_check
  if ! below_floor 34 35; then
    echo "34G should be under a 35G floor" >&2
    return 1
  fi
  if below_floor 35 35 || below_floor 36 35; then
    echo "floor comparison accepted a value that is not under the floor" >&2
    return 1
  fi
  got=$(printf 'Avail\n  35G\n' | parse_df_gb)
  [[ "${got}" == "35" ]]
  got=$(printf '1G-blocks\n     60G\n' | parse_df_gb)
  [[ "${got}" == "60" ]]
  [[ "$(disk_floor_gb 60)" == "35" ]]
  [[ "$(disk_floor_gb 100)" == "55" ]]
  AAP_WORK_DISK_GIB=""
  AAP_DISK_FLOOR_GB=""
  finish_disk_bounds
  [[ "${AAP_WORK_DISK_GIB}" == "60" && "${AAP_DISK_FLOOR_GB}" == "35" ]]
  [[ "${WORK_DISK_MIN_GB}" == "50" && "${WORK_DISK_MAX_GB}" == "64" ]]
  if ! size_is_work_disk 60 || ! size_is_work_disk 50 || ! size_is_work_disk 64; then
    echo "60G work disk was rejected" >&2
    return 1
  fi
  if size_is_work_disk 49 || size_is_work_disk 65 || size_is_work_disk 1000; then
    echo "a filesystem that is not the 60G work disk was accepted" >&2
    return 1
  fi
  AAP_WORK_DISK_GIB=100
  AAP_DISK_FLOOR_GB=""
  finish_disk_bounds
  [[ "${AAP_DISK_FLOOR_GB}" == "55" ]]
  [[ "${WORK_DISK_MIN_GB}" == "90" && "${WORK_DISK_MAX_GB}" == "104" ]]
  if ! size_is_work_disk 100 || ! size_is_work_disk 90 || ! size_is_work_disk 104; then
    echo "100G work disk was rejected" >&2
    return 1
  fi
  if size_is_work_disk 89 || size_is_work_disk 105 || size_is_work_disk 1000; then
    echo "a filesystem that is not the 100G work disk was accepted" >&2
    return 1
  fi
  AAP_WORK_DISK_GIB=100
  AAP_DISK_FLOOR_GB=35
  finish_disk_bounds
  [[ "${AAP_DISK_FLOOR_GB}" == "55" ]]
  AAP_WORK_DISK_GIB=100
  AAP_DISK_FLOOR_GB=60
  finish_disk_bounds
  [[ "${AAP_DISK_FLOOR_GB}" == "60" ]]
  AAP_WORK_DISK_GIB=9
  if finish_disk_bounds; then
    echo "a 9 GiB work disk was accepted" >&2
    return 1
  fi
  AAP_WORK_DISK_GIB=513
  if finish_disk_bounds; then
    echo "a 513 GiB work disk was accepted" >&2
    return 1
  fi
  AAP_WORK_DISK_GIB=512
  AAP_DISK_FLOOR_GB=""
  finish_disk_bounds
  [[ "${WORK_DISK_MIN_GB}" == "502" && "${WORK_DISK_MAX_GB}" == "516" ]]
  [[ "${AAP_DISK_FLOOR_GB}" == "282" ]]
  sample=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
  if ! work_mount_matches /dev/sdb1 /dev/sda "${sample}" "${sample}"; then
    echo "a distinct work-disk device was rejected" >&2
    return 1
  fi
  if work_mount_matches /dev/sda /dev/sda "${sample}" "${sample}"; then
    echo "the distro root device was accepted as the work disk" >&2
    return 1
  fi
  if work_mount_matches /dev/sdb1 /dev/sda "${sample}" bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee; then
    echo "a different filesystem UUID was accepted" >&2
    return 1
  fi
  AAP_WORK_DISK_GIB=60
  AAP_DISK_FLOOR_GB=35
  finish_disk_bounds
  if ! mount_source_forbidden /mnt || ! mount_source_forbidden /mnt/ || ! mount_source_forbidden /mnt/wsl; then
    echo "mounts under /mnt were allowed" >&2
    return 1
  fi
  if mount_source_forbidden /var/lib/docker || mount_source_forbidden /mntfoo; then
    echo "a non-/mnt source was forbidden" >&2
    return 1
  fi
  AAP_GITHUB_ORG=""
  apply_config_line "AAP_GITHUB_ORG=special-place-ai-heaven"
  [[ "${AAP_GITHUB_ORG}" == "special-place-ai-heaven" ]]
  if apply_config_line "NOT_A_KEY=1"; then
    echo "unknown config key was accepted" >&2
    return 1
  fi
  AAP_JOB_MEMORY=""
  AAP_JOB_CPUS=""
  AAP_JOB_PIDS_LIMIT=""
  AAP_JOB_TIMEOUT_MINUTES=""
  finish_job_limits
  [[ "${AAP_JOB_MEMORY}" == "12g" ]]
  [[ "${AAP_JOB_CPUS}" == "6" ]]
  [[ "${AAP_JOB_PIDS_LIMIT}" == "4096" ]]
  [[ "${AAP_JOB_TIMEOUT_MINUTES}" == "120" ]]
  [[ $((AAP_JOB_TIMEOUT_MINUTES * 60)) -eq 7200 ]]
  AAP_JOB_MEMORY="12gb"
  if finish_job_limits; then
    echo "bad memory limit was accepted" >&2
    return 1
  fi
  AAP_JOB_MEMORY="12g"
  AAP_JOB_CPUS="0"
  if finish_job_limits; then
    echo "zero cpus was accepted" >&2
    return 1
  fi
  AAP_JOB_CPUS="6"
  AAP_JOB_PIDS_LIMIT="4096"
  AAP_JOB_TIMEOUT_MINUTES="1441"
  if finish_job_limits; then
    echo "timeout above 1440 minutes was accepted" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL=""
  AAP_RUNNER_LABELS="self-hosted,linux,crrr"
  AAP_RUNNER_EXTRA_LABELS=""
  if finish_runner_labels; then
    echo "an empty base label was accepted" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="crrr"
  AAP_RUNNER_LABELS="self-hosted,linux,crrr"
  AAP_RUNNER_EXTRA_LABELS=""
  finish_runner_labels
  [[ "${AAP_RUNNER_LABELS}" == "self-hosted,linux,crrr" ]]
  got=$(log_runner_labels)
  [[ "${got}" == "runner labels: self-hosted,linux,crrr" ]]
  AAP_RUNNER_BASE_LABEL="fresh"
  AAP_RUNNER_LABELS="self-hosted,linux,fresh"
  AAP_RUNNER_EXTRA_LABELS="heavy"
  finish_runner_labels
  [[ "${AAP_RUNNER_LABELS}" == "self-hosted,linux,fresh,heavy" ]]
  got=$(log_runner_labels)
  [[ "${got}" == "runner labels: self-hosted,linux,fresh,heavy" ]]
  AAP_RUNNER_BASE_LABEL="fresh"
  AAP_RUNNER_LABELS="self-hosted,linux,fresh"
  AAP_RUNNER_EXTRA_LABELS="heavy,crrr"
  if finish_runner_labels; then
    echo "extra label crrr was accepted on base fresh" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="fresh"
  AAP_RUNNER_LABELS=""
  AAP_RUNNER_EXTRA_LABELS="heavy"
  finish_runner_labels
  [[ "${AAP_RUNNER_LABELS}" == "self-hosted,linux,fresh,heavy" ]]
  AAP_RUNNER_BASE_LABEL="fresh"
  AAP_RUNNER_LABELS="self-hosted,linux,crrr"
  AAP_RUNNER_EXTRA_LABELS="heavy"
  if finish_runner_labels; then
    echo "crrr labels were accepted for base fresh" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="fresh"
  AAP_RUNNER_LABELS="self-hosted,linux,fresh"
  AAP_RUNNER_EXTRA_LABELS="fresh"
  if finish_runner_labels; then
    echo "the base label was accepted again as an extra" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="self-hosted"
  AAP_RUNNER_LABELS=""
  AAP_RUNNER_EXTRA_LABELS=""
  if finish_runner_labels; then
    echo "base label self-hosted was accepted" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="crrr"
  AAP_RUNNER_LABELS="self-hosted,linux,crrr"
  AAP_RUNNER_EXTRA_LABELS="self-hosted"
  if finish_runner_labels; then
    echo "baseline label was accepted as an extra label" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="crrr"
  AAP_RUNNER_LABELS="self-hosted,linux,crrr"
  AAP_RUNNER_EXTRA_LABELS="fresh fresh"
  if finish_runner_labels; then
    echo "a label with a space was accepted" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="not a label"
  AAP_RUNNER_LABELS=""
  AAP_RUNNER_EXTRA_LABELS=""
  if finish_runner_labels; then
    echo "a base label with a space was accepted" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="crrr"
  AAP_RUNNER_LABELS="linux,crrr"
  AAP_RUNNER_EXTRA_LABELS=""
  if finish_runner_labels; then
    echo "a label line other than self-hosted,linux,crrr was accepted" >&2
    return 1
  fi
  killer=$(arm_wall_clock 30 "aap-self-check-no-such-container")
  if ! kill -0 "${killer}" 2>/dev/null; then
    disarm_wall_clock "${killer}"
    echo "wall clock did not stay up" >&2
    return 1
  fi
  disarm_wall_clock "${killer}"
  # The signal is asynchronous, and the sleeper is not this shell's child
  # (arm runs inside a command substitution), so wait cannot reap it.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "${killer}" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "${killer}" 2>/dev/null; then
    echo "wall clock was still running after disarm" >&2
    return 1
  fi
  echo "disk floor self-check ok"
}

runner_uid_ok() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# The cache dir is owned by the image's runner uid, mode 0700. Sysbox mounts
# host binds ID-mapped, so that host uid is the same uid inside the job.
# Mode 1777 would let any distro account, ghrunner included, plant cache
# objects, and so would a runner uid that a distro account also has.
# Read once at startup with the default runtime and no network.
resolve_runner_uid() {
  local out="" account
  out=$(docker run --rm --pull never --network none --entrypoint id "${AAP_RUNNER_IMAGE}" -u runner 2>/dev/null) || out=""
  if ! runner_uid_ok "${out}"; then
    echo "refusing: runner uid in ${AAP_RUNNER_IMAGE} is '${out}', not a plain non-zero integer" >&2
    return 1
  fi
  account=$(getent passwd "${out}" | cut -d: -f1 || true)
  if [[ -n "${account}" ]]; then
    echo "refusing: runner uid ${out} is distro account ${account}; the cache would be writable from the distro" >&2
    return 1
  fi
  RUNNER_UID=${out}
}

# A dead slot's job container keeps running and holds its cpus and memory.
# Remove it, and its network (named after the container), before the slot
# restarts or retires.
remove_slot_containers() {
  local id name
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    name=$(docker inspect --format '{{.Name}}' "${id}" 2>/dev/null || true)
    name=${name#/}
    docker rm -f -v "${id}" >/dev/null || true
    if [[ -n "${name}" ]]; then
      docker network rm "${name}" >/dev/null 2>&1 || true
    fi
  done < <(docker ps -aq --filter label=aap-crrr-job=1 --filter "label=aap-crrr-slot=$1")
}

remove_job_containers() {
  local stale
  while IFS= read -r stale; do
    if [[ -n "${stale}" ]]; then
      docker rm -f "${stale}" || true
    fi
  done < <(docker ps -aq --filter label=aap-crrr-job=1)
  docker network prune -f --filter label=aap-crrr-job=1 >/dev/null || true
}

# One slot runs one job at a time, forever. A job that exits non-zero is the
# normal path: the slot logs it and takes the next job. The slot drops the
# parent's traps so only the parent cleans up the pool.
slot_loop() {
  local slot="$1"
  trap - EXIT TERM INT
  set_slot_state "${slot}" starting
  while true; do
    # Drain: exit 0 before another runner starts. run_pool does not restart
    # it. A listening runner is removed by drain_listening_slots instead.
    if draining; then
      echo "slot ${slot}: drain requested; not starting another job" >&2
      exit 0
    fi
    if ! disk_ok; then
      sleep 60
      continue
    fi
    if ! run_one "${slot}"; then
      echo "slot ${slot}: runner container exited non-zero; workspace was removed with the container" >&2
      sleep 5
    fi
  done
}

# Seconds to wait before restarting a slot that has died $1 times in a row.
slot_restart_delay() {
  local delay=$((10 * $1))
  if [[ "${delay}" -gt 60 ]]; then
    delay=60
  fi
  printf '%s\n' "${delay}"
}

start_slot() {
  local slot="$1" delay="$2"
  SLOT_STARTED[slot]=$(($(now_s) + delay))
  {
    sleep "${delay}"
    slot_loop "${slot}"
  } &
  SLOT_PIDS[slot]=$!
}

# Ends the pool loop's wait every STATUS_TICK_SECONDS.
start_tick() {
  sleep "${STATUS_TICK_SECONDS}" &
  TICK_PID=$!
}

# docker rm -f does not deregister a runner. On SIGTERM the actions/runner
# v2.338.0 listener only deletes its session (Runner.cs, DeleteSessionAsync),
# and GitHub removes an ephemeral runner only after its job. So a runner
# stopped without a job is deregistered here, after its container is gone.

# Draining: a slot whose runner is listening (no job) is stopped now and its
# registration deleted. A busy slot finishes its job, GitHub removes that
# ephemeral runner, and the slot exits 0 in slot_loop.
drain_listening_slots() {
  local slot runner
  local -a runners=()
  for slot in "${!SLOT_PIDS[@]}"; do
    if [[ "$(slot_state "${slot}")" != listening ]]; then
      continue
    fi
    runner=$(runner_name_of "$(slot_container "${slot}")") || runner=""
    echo "slot ${slot}: draining; removing runner ${runner:-unknown}, which has no job" >&2
    kill "${SLOT_PIDS[slot]}" 2>/dev/null || true
    wait "${SLOT_PIDS[slot]}" 2>/dev/null || true
    remove_slot_containers "${slot}"
    unset "SLOT_PIDS[${slot}]"
    SLOT_DRAINED[slot]=1
    rm -f "${RUN_DIR}/slot-${slot}"
    if [[ -n "${runner}" ]]; then
      runners+=("${runner}")
    else
      echo "warning: slot ${slot}: no runner name; it may stay registered, offline" >&2
    fi
  done
  deregister_runners "${runners[@]}"
}

# SIGTERM, SIGINT, or exit: stop every slot, remove every job container by
# label, prune job networks, reap the slots, then deregister the runners
# that had no job (bounded by DEREGISTER_BUDGET_SECONDS). A runner killed
# mid-job is left to GitHub, then to the next ghost reap. A reap in flight
# is stopped; none starts here. The drain file stays; the status files go, so
# a missing status.json means no manager.
stop_pool() {
  local pid slot runner
  local -a runners=()
  trap - EXIT TERM INT
  # Names first: they come from the containers, which are removed below.
  for slot in "${!SLOT_PIDS[@]}"; do
    case "$(slot_state "${slot}")" in
      starting | listening)
        if runner=$(runner_name_of "$(slot_container "${slot}")"); then
          runners+=("${runner}")
        fi
        ;;
    esac
  done
  # A drain batch this SIGTERM interrupted: systemd's SIGTERM reaches those
  # processes too, so stop them and run their names again in this batch. A
  # repeat is harmless: a runner that is gone is not listed, or is a 404.
  runners+=("${DEREG_NAMES[@]}")
  for pid in "${SLOT_PIDS[@]}" "${TICK_PID}" "${REAP_PID}" "${USAGE_PID}" "${DEREG_PIDS[@]}"; do
    if [[ -n "${pid}" ]]; then
      kill "${pid}" 2>/dev/null || true
    fi
  done
  remove_job_containers
  # Only these children. A bare wait would also wait on anything else this
  # shell started, without a bound.
  wait "${SLOT_PIDS[@]}" "${TICK_PID}" ${REAP_PID:+"${REAP_PID}"} ${USAGE_PID:+"${USAGE_PID}"} "${DEREG_PIDS[@]}" 2>/dev/null || true
  DEREG_PIDS=()
  DEREG_NAMES=()
  deregister_runners "${runners[@]}"
  rm -f "${RUN_DIR}/status.json" "${RUN_DIR}"/slot-[1-9] "${RUN_DIR}"/slot-[1-9].run "${RUN_DIR}/usage"
}

# A dead slot is restarted alone; the other slots' jobs keep running. A
# retired slot leaves SLOT_PIDS, so wait only sees live slots and never
# matches a retired PID again. wait -n -p needs bash 5.1. Ubuntu 24.04 ships 5.2.
run_pool() {
  local slot i died now rc
  trap 'stop_pool; exit 143' TERM INT
  trap stop_pool EXIT
  rm -f "${RUN_DIR}"/slot-[1-9] "${RUN_DIR}"/slot-[1-9].run "${RUN_DIR}/usage"
  write_status
  for ((slot = 1; slot <= AAP_RUNNER_COUNT; slot++)); do
    SLOT_FAILS[slot]=0
    start_slot "${slot}" 0
  done
  start_tick
  # After the slots start, so the first runner is not held up by the API.
  tick_reap
  tick_usage
  while true; do
    # Undrain: the drain file is gone, so drained slots (not retired ones)
    # start again and the pool is back to AAP_RUNNER_COUNT.
    if ! draining; then
      for slot in "${!SLOT_DRAINED[@]}"; do
        echo "slot ${slot}: drain file removed; starting it again" >&2
        unset "SLOT_DRAINED[${slot}]"
        SLOT_FAILS[slot]=0
        start_slot "${slot}" 0
      done
    fi
    if [[ "${#SLOT_PIDS[@]}" -eq 0 ]]; then
      # Exit 0 so Restart=on-failure leaves a drained manager stopped.
      if draining; then
        echo "drained: no slot has a job; stopping the manager" >&2
        exit 0
      fi
      echo "all ${AAP_RUNNER_COUNT} slots retired; stopping the manager" >&2
      exit 1
    fi
    died=""
    rc=0
    wait -n -p died "${SLOT_PIDS[@]}" "${TICK_PID}" || rc=$?
    if [[ -n "${died}" && "${died}" == "${TICK_PID}" ]]; then
      if draining; then
        drain_listening_slots
      fi
      tick_reap
      tick_usage
      write_status
      start_tick
      continue
    fi
    slot=""
    for i in "${!SLOT_PIDS[@]}"; do
      if [[ "${SLOT_PIDS[i]}" == "${died}" ]]; then
        slot=${i}
      fi
    done
    if [[ -z "${slot}" ]]; then
      sleep 1
      continue
    fi
    rm -f "${RUN_DIR}/slot-${slot}"
    if [[ "${rc}" -eq 0 ]] && draining; then
      echo "slot ${slot} drained" >&2
      unset "SLOT_PIDS[${slot}]"
      SLOT_DRAINED[slot]=1
      write_status
      continue
    fi
    now=$(now_s)
    if [[ $((now - SLOT_STARTED[slot])) -lt "${SLOT_FAST_SECONDS}" ]]; then
      SLOT_FAILS[slot]=$((SLOT_FAILS[slot] + 1))
    else
      SLOT_FAILS[slot]=1
    fi
    remove_slot_containers "${slot}"
    if [[ "${SLOT_FAILS[slot]}" -ge "${SLOT_MAX_FAILS}" ]]; then
      echo "slot ${slot} retired after ${SLOT_FAILS[slot]} fast deaths; other slots keep running" >&2
      unset "SLOT_PIDS[${slot}]"
      set_slot_state "${slot}" retired
      continue
    fi
    echo "slot ${slot} exited; restarting it" >&2
    start_slot "${slot}" "$(slot_restart_delay "${SLOT_FAILS[slot]}")"
  done
}

main() {
  # Only no argument starts the pool, which first removes every job
  # container. Anything unknown stops here, before any docker call.
  case "${1-}" in
    '' | --self-check | --assert-mounts | --check-limits | --drain | --undrain | --reap | --measure-io) ;;
    --version)
      echo "${MANAGER_VERSION}"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac

  if [[ "${BASH_VERSINFO[0]}" -lt 5 || ("${BASH_VERSINFO[0]}" -eq 5 && "${BASH_VERSINFO[1]}" -lt 1) ]]; then
    echo "refusing: bash ${BASH_VERSION} is older than 5.1; the slot supervisor needs wait -n -p" >&2
    exit 1
  fi

  if [[ "${1:-}" == "--self-check" ]]; then
    self_check
    exit 0
  fi

  if [[ "${1:-}" == "--assert-mounts" ]]; then
    assert_no_mnt_mounts "${2:?container name}"
    exit 0
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    echo "aap-runner-manager must run as root" >&2
    exit 1
  fi

  # For the supervisor before a restart: both files parsed and checked, the
  # effective limits printed, nothing started and no docker call.
  if [[ "${1:-}" == "--check-limits" ]]; then
    load_config
    printf 'AAP_RUNNER_COUNT=%s\nAAP_JOB_CPUS=%s\nAAP_JOB_MEMORY=%s\nAAP_JOB_IO_PERCENT=%s\nAAP_JOB_IO_MBPS=%s\nAAP_POOL_SHARING=%s\n' \
      "${AAP_RUNNER_COUNT}" "${AAP_JOB_CPUS}" "${AAP_JOB_MEMORY}" "${AAP_JOB_IO_PERCENT}" "${SLOT_IO_MBPS}" "${AAP_POOL_SHARING}"
    exit 0
  fi

  # Benchmarks the work disk and writes WORK_DISK_MBPS_FILE. No config, no
  # pool start, no docker call. The pool reads the file at its next start.
  if [[ "${1:-}" == "--measure-io" ]]; then
    measure_io || exit 1
    exit 0
  fi

  # One ghost reap in the foreground, beside a running pool or none. No pool
  # start, no container removed. Always exit 0.
  if [[ "${1:-}" == "--reap" ]]; then
    load_config
    check_key
    reap_ghost_runners
    exit 0
  fi

  install -d -m 0755 -o root -g root "${RUN_DIR}"
  case "${1:-}" in
    --drain)
      : > "${RUN_DIR}/drain"
      echo "drain requested: running jobs finish, no new job starts, and the manager exits 0 when no slot has a job"
      exit 0
      ;;
    --undrain)
      rm -f "${RUN_DIR}/drain"
      exit 0
      ;;
  esac

  load_config
  check_key
  resolve_runner_uid
  remove_job_containers
  resolve_io_device
  setup_pool_sharing
  echo "runner pool: ${AAP_RUNNER_COUNT} slot(s), sharing ${AAP_POOL_SHARING}, share --cpus ${SLOT_CPUS} --memory ${SLOT_MEMORY} --pids-limit ${AAP_JOB_PIDS_LIMIT} io ${SLOT_IO_MBPS:-0} MiB/s on ${IO_DEVICE:-none}"
  run_pool
}

# Runs only when executed. tests/ source this file for its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
