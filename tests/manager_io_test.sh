#!/bin/bash
# Disk IO cap: AAP_JOB_IO_PERCENT of the measured work disk, split over the
# slots, reaches docker create as --device-{read,write}-{bps,iops} on the
# work mount's whole disk. --measure-io benchmarks with dd and writes the
# measurement. docker, findmnt, lsblk, dd, mountpoint, df, and id are
# stubbed as functions; no root, no disk is touched.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
manager="${here}/../manager.sh"
# shellcheck source=SCRIPTDIR/../manager.sh
source "${manager}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
WORK_DISK_MBPS_FILE="${work}/work-disk.mbps"
err="${work}/err"

# io COUNT PERCENT: finish_io_limits for COUNT slots. stderr goes to ${err}.
io() {
  AAP_RUNNER_COUNT=$1
  AAP_JOB_IO_PERCENT=$2
  finish_io_limits 2> "${err}"
}

echo 1000 > "${WORK_DISK_MBPS_FILE}"
for pair in 1:900 2:450 3:300 4:225; do
  io "${pair%%:*}" "" || fail "count ${pair%%:*} was refused: $(cat "${err}")"
  [[ "${AAP_JOB_IO_PERCENT}" == 90 ]] || fail "default percent is ${AAP_JOB_IO_PERCENT}"
  [[ "${SLOT_IO_MBPS}" == "${pair#*:}" ]] || fail "count ${pair%%:*}: ${SLOT_IO_MBPS} MiB/s per slot; want ${pair#*:}"
done
io 2 50 || fail "50% was refused"
[[ "${SLOT_IO_MBPS}" == 250 ]] || fail "50% of 1000 over 2 is ${SLOT_IO_MBPS}"
echo "budget split ok"

echo 20 > "${WORK_DISK_MBPS_FILE}"
io 1 90 || fail "18 MiB/s for one slot was refused"
[[ "${SLOT_IO_MBPS}" == 18 ]] || fail "90% of 20 is ${SLOT_IO_MBPS}"
if io 2 90; then
  fail "9 MiB/s per slot was accepted"
fi
[[ "$(cat "${err}")" == *"each slot needs 10"* ]] || fail "refusal says: $(cat "${err}")"
[[ "${SLOT_IO_MBPS}" == 0 ]] || fail "a refused split left ${SLOT_IO_MBPS}"
echo 1000 > "${WORK_DISK_MBPS_FILE}"
for bad in 101 -1 abc 1.5 " 90" 090 1000; do
  if io 1 "${bad}"; then
    fail "AAP_JOB_IO_PERCENT='${bad}' was accepted"
  fi
done
echo "refusals ok"

io 3 0 || fail "percent 0 was refused"
[[ "${SLOT_IO_MBPS}" == 0 && ! -s "${err}" ]] || fail "percent 0: ${SLOT_IO_MBPS}, '$(cat "${err}")'"
rm -f "${WORK_DISK_MBPS_FILE}"
io 3 90 || fail "a missing measurement failed the pool"
[[ "${SLOT_IO_MBPS}" == 0 ]] || fail "missing measurement gave ${SLOT_IO_MBPS}"
[[ "$(cat "${err}")" == "io cap disabled: run aap-runner-manager --measure-io" ]] || fail "missing file logged: $(cat "${err}")"
for junk in 0 fast "" -5 1.5; do
  printf '%s\n' "${junk}" > "${WORK_DISK_MBPS_FILE}"
  io 1 90 || fail "measurement '${junk}' failed the pool"
  [[ "${SLOT_IO_MBPS}" == 0 && "$(cat "${err}")" == "io cap disabled"* ]] || fail "measurement '${junk}' gave ${SLOT_IO_MBPS}"
done
echo "no cap without a measurement ok"

# shellcheck disable=SC2317
findmnt() { printf '%s\n' "${fake_src}"; }
# shellcheck disable=SC2317
lsblk() { [[ -z "${fake_parent}" ]] || printf '%s\n' "${fake_parent}"; }
dev() {
  fake_src=$1 fake_parent=$2
  SLOT_IO_MBPS=300
  resolve_io_device 2> "${err}"
}
dev /dev/sde ""
[[ "${IO_DEVICE}" == /dev/sde ]] || fail "bare disk resolved to ${IO_DEVICE}"
dev /dev/sdb1 sdb
[[ "${IO_DEVICE}" == /dev/sdb ]] || fail "partition resolved to ${IO_DEVICE}"
dev /dev/nvme0n1 ""
[[ "${IO_DEVICE}" == /dev/nvme0n1 ]] || fail "nvme disk resolved to ${IO_DEVICE}"
dev "" ""
[[ -z "${IO_DEVICE}" && "${SLOT_IO_MBPS}" == 0 ]] || fail "no source kept ${IO_DEVICE} ${SLOT_IO_MBPS}"
[[ "$(cat "${err}")" == "io cap disabled: no block device"* ]] || fail "no source logged: $(cat "${err}")"
echo "device resolution ok"

create_argv="${work}/create_argv"
# shellcheck disable=SC2317
docker() {
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
AAP_JOB_CPUS=24
AAP_JOB_MEMORY=72g
AAP_JOB_PIDS_LIMIT=4096
AAP_JOB_TIMEOUT_MINUTES=120
finish_job_limits
AAP_RUNNER_COUNT=3
finish_runner_count
AAP_RUNNER_IMAGE=aap-crrr-runner:local
RUNNER_UID=$(id -u)
SCCACHE_HOST_DIR="${work}/sccache"

# create_args COUNT PERCENT: run_one 1 after finish_io_limits on /dev/sde.
create_args() {
  io "$1" "$2" || fail "io $*: $(cat "${err}")"
  IO_DEVICE=/dev/sde
  rm -f "${create_argv}"
  run_one 1 >/dev/null 2>&1 || fail "run_one failed"
  mapfile -t argv < "${create_argv}"
}
pair() {
  local i
  for ((i = 0; i < ${#argv[@]} - 1; i++)); do
    [[ "${argv[i]}" == "$1" && "${argv[i + 1]}" == "$2" ]] && return 0
  done
  fail "docker create argv has no '$1 $2'"
}
no_device_flags() {
  if grep -q '^--device-' "${create_argv}"; then
    fail "$1: docker create has $(grep '^--device-' "${create_argv}" | tr '\n' ' ')"
  fi
}

echo 1000 > "${WORK_DISK_MBPS_FILE}"
create_args 3 90
pair --device-read-bps /dev/sde:300mb
pair --device-write-bps /dev/sde:300mb
pair --device-read-iops /dev/sde:2400
pair --device-write-iops /dev/sde:2400
[[ "$(grep -c '^--device-' "${create_argv}")" == 4 ]] || fail "not exactly four device flags"
[[ "${argv[-1]}" == aap-crrr-runner:local ]] || fail "image is not last: ${argv[-1]}"
create_args 3 0
no_device_flags "percent 0"
rm -f "${WORK_DISK_MBPS_FILE}"
create_args 3 90
no_device_flags "no measurement"
echo "docker create io flags ok"

# measure MOUNTED AVAIL_MIB: main --measure-io in a new bash as root.
measure() {
  bash -c '
    source "$1"
    WORK_MOUNT=$2
    WORK_DISK_MBPS_FILE=$3
    mounted=$4
    free_mib=$5
    log=$6
    id() { echo 0; }
    mountpoint() { [[ "${mounted}" == yes ]]; }
    df() { printf "Avail\n%sM\n" "${free_mib}"; }
    dd() {
      echo "dd $*" >> "${log}"
      case "$*" in
        *of=/dev/null*) echo "2147483648 bytes (2.1 GB, 2.0 GiB) copied, 1.6 s, 1.3 GB/s" >&2 ;;
        *)
          : > "${WORK_MOUNT}/.aap-iobench"
          printf "512+0 records in\n512+0 records out\n2147483648 bytes (2.1 GB, 2.0 GiB) copied, 2 s, 1.1 GB/s\n" >&2
          ;;
      esac
    }
    main --measure-io
  ' _ "${manager}" "${work}/mnt" "${work}/measured" "$1" "$2" "${work}/ddlog" 2>&1
}
mkdir -p "${work}/mnt"
rc=0
out=$(measure yes 40000) || rc=$?
[[ "${rc}" -eq 0 ]] || fail "--measure-io exited ${rc}: ${out}"
[[ "${out}" == *"work-disk.mbps=1024"* ]] || fail "--measure-io printed: ${out}"
[[ "$(cat "${work}/measured")" == 1024 ]] || fail "work-disk.mbps holds $(cat "${work}/measured"); want the lower rate 1024"
[[ "$(stat -c '%a' "${work}/measured")" == 644 ]] || fail "work-disk.mbps is not mode 0644"
[[ ! -e "${work}/mnt/.aap-iobench" ]] || fail "the benchmark file was left behind"
grep -q 'oflag=direct conv=fsync' "${work}/ddlog" || fail "write was not direct with fsync: $(cat "${work}/ddlog")"
grep -q 'iflag=direct' "${work}/ddlog" || fail "read was not direct"
echo "--measure-io ok"

rm -f "${work}/measured" "${work}/ddlog"
rc=0
out=$(measure no 40000) || rc=$?
[[ "${rc}" -eq 1 && "${out}" == *"is not a mountpoint"* ]] || fail "non-mountpoint exited ${rc}: ${out}"
[[ ! -e "${work}/ddlog" && ! -e "${work}/measured" ]] || fail "non-mountpoint ran dd or wrote the file"
rc=0
out=$(measure yes 3000) || rc=$?
[[ "${rc}" -eq 1 && "${out}" == *"needs 3 GiB"* ]] || fail "3000 MiB free exited ${rc}: ${out}"
[[ ! -e "${work}/ddlog" ]] || fail "low space ran dd"
echo "--measure-io refusals ok"

echo "manager io tests ok"
