#!/bin/bash
# Parity oracle for crates/pool-core `limits`. Sources the real distro/manager.sh, runs its own
# finish_job_limits, finish_runner_count, finish_io_limits and finish_pool_sharing, then run_one
# with docker stubbed so the `lim=(...)` block, --cpu-shares and --pids-limit run unmodified. The
# arguments docker create would receive are the expected values. Output is
# crates/pool-core/tests/golden/limits.txt, which the Rust golden test replays.
#   bash tests/pool_core_limits_golden_test.sh          regenerate and diff against the file
#   bash tests/pool_core_limits_golden_test.sh --write  rewrite the file
# No docker, no systemd, no root, nothing outside a temp dir.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
golden="${here}/../crates/pool-core/tests/golden/limits.txt"
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# shellcheck source=SCRIPTDIR/../distro/manager.sh
source "${here}/../distro/manager.sh"

# Stubs for the side effects around the lim block in run_one, and for the mount lookup in
# resolve_io_device: findmnt reports the case's device, lsblk finds no parent disk (partition
# to disk resolution stays in bash; tests/manager_io_test.sh covers it).
bound_sccache_tree() { :; }
install() { :; }
fake_src=""
findmnt() { printf '%s\n' "${fake_src}"; }
lsblk() { :; }
docker() {
  [[ "$1" == create ]] || return 0
  shift
  local -a a=("$@")
  local i start=-1 end=${#a[@]}
  for ((i = 0; i < ${#a[@]}; i++)); do
    if [[ "${a[i]}" == --network && "${start}" -lt 0 ]]; then
      start=$((i + 2))
    fi
    if [[ "${a[i]}" == --label ]]; then
      end=${i}
      break
    fi
  done
  echo "${a[*]:start:end-start}"
  return 1
}

# The kind of the first "refusing:" line on stderr, matched by the Rust error variant.
refusal_kind() {
  local line
  line=$(grep -m 1 '^refusing:' "${work}/err" || true)
  case "${line}" in
    *"each slot needs 10"*) echo slot-io ;;
    *"each slot needs 1 cpu"*) echo slot ;;
    *"too large to split"*) echo memory-too-large ;;
    *AAP_RUNNER_COUNT=*) echo count ;;
    *AAP_JOB_MEMORY=*) echo memory ;;
    *AAP_JOB_CPUS=*) echo cpus ;;
    *AAP_JOB_PIDS_LIMIT=*) echo pids ;;
    *AAP_JOB_IO_PERCENT=*) echo io-percent ;;
    *AAP_POOL_SHARING=*) echo sharing ;;
    *) echo "unknown(${line})" ;;
  esac
}

# run_case count cpus memory pids sharing io_percent disk_mibps|none device|none
# disk_mibps is the measurement file's content; device is what findmnt reports.
# Prints one line: the inputs, then " => " and either the docker arguments or "refused:<kind>".
run_case() {
  local header="count=$1 cpus=$2 memory=$3 pids=$4 sharing=$5 io_percent=$6 disk_mibps=$7 device=$8"
  local out
  out=$(
    exec 2> "${work}/err"
    AAP_RUNNER_COUNT=$1
    AAP_JOB_CPUS=$2
    AAP_JOB_MEMORY=$3
    AAP_JOB_PIDS_LIMIT=$4
    AAP_POOL_SHARING=$5
    AAP_JOB_IO_PERCENT=$6
    if [[ "$7" == none ]]; then
      WORK_DISK_MBPS_FILE="${work}/absent"
    else
      printf '%s\n' "$7" > "${work}/mbps"
      WORK_DISK_MBPS_FILE="${work}/mbps"
    fi
    if finish_job_limits && finish_runner_count && finish_io_limits && finish_pool_sharing; then
      fake_src=$8
      [[ "${fake_src}" == none ]] && fake_src=""
      resolve_io_device
      run_one 1 || true
    else
      echo "refused:$(refusal_kind)"
    fi
  )
  echo "${header} => ${out}"
}

generate() {
  local n sharing cpus mem pct mbps dev
  # IO matrix on the default 6 cpu / 12g pool: unmeasured, off, the tray default, the largest
  # disk, a disk that refuses from 5 slots (budget 40: 8 per slot) and from 1 (budget 0).
  for n in 1 2 3 4 5; do
    for sharing in slice fixed; do
      run_case "${n}" 6 12g 4096 "${sharing}" 90 none /dev/sde
      run_case "${n}" 6 12g 4096 "${sharing}" 0 1000 /dev/sde
      run_case "${n}" 6 12g 4096 "${sharing}" 90 1000 /dev/sde
      run_case "${n}" 6 12g 4096 "${sharing}" 90 1000 none
      run_case "${n}" 6 12g 4096 "${sharing}" 100 999999999 /dev/nvme0n1
      run_case "${n}" 6 12g 4096 "${sharing}" 1 999999999 /dev/sde
      run_case "${n}" 6 12g 4096 "${sharing}" 100 40 /dev/sde
      run_case "${n}" 6 12g 4096 "${sharing}" 50 1 /dev/sde
      run_case "${n}" 6 12g 4096 "${sharing}" 100 59 /dev/sde
      run_case "${n}" 6 12g 4096 "${sharing}" 100 50 /dev/sde
      run_case "${n}" 6 12g 4096 "${sharing}" 100 49 /dev/sde
    done
  done
  # A bad measurement or a mount without a block device drops the cap, never the pool.
  for sharing in slice fixed; do
    for mbps in abc 0 0100 1234567890 -5; do
      run_case 2 6 12g 4096 "${sharing}" 100 "${mbps}" /dev/sde
    done
    for dev in tmpfs overlay /dev/ /dev/sde1 /dev/mapper/x C:; do
      run_case 2 6 12g 4096 "${sharing}" 100 1000 "${dev}"
    done
  done
  # Cpu and memory grammar, rounding and boundaries, every count, both modes.
  for cpus in 1 2 5 6 7 2.5 6.5 0.5 24; do
    for mem in 1g 1G 5g 12g 12G 72g 5000m 5119m 5120m 7168m 1m 1073741824b 2097152 0g \
      4294967296g 4294967297g 999999999999999999 1000000000000000000 4398046511104m 4398046511105m; do
      for n in 1 2 3 4 5; do
        for sharing in slice fixed; do
          run_case "${n}" "${cpus}" "${mem}" 4096 "${sharing}" 90 none none
        done
      done
    done
  done
  # Cpu extremes and invalid cpu values.
  for cpus in 0 0.0 0.000001 000006 0000000006 6.0000000 0000999999999.9999990 999999999 \
    999999999.999999; do
    for n in 1 2 3 5; do
      for sharing in slice fixed; do
        run_case "${n}" "${cpus}" 1024g 4096 "${sharing}" 90 none none
      done
    done
  done
  # Pids limit passes through verbatim; invalid values refuse.
  for mem in 4096 1 99999999999999999999 0 abc 01; do
    run_case 3 6 12g "${mem}" fixed 90 none none
  done
  # Other sharing values refuse.
  run_case 2 6 12g 4096 both 90 none none
  # Counts outside 1..5.
  for n in 0 6 01 10; do
    run_case "${n}" 6 12g 4096 fixed 90 none none
  done
  # IO percent grammar.
  for pct in 0 1 99 100 101 abc 010; do
    run_case 2 6 12g 4096 fixed "${pct}" 1000 /dev/sde
  done
}

if [[ "${1:-}" == --write ]]; then
  generate > "${golden}"
  echo "wrote ${golden}"
  exit 0
fi

generate > "${work}/limits.txt"
if ! diff -u "${golden}" "${work}/limits.txt"; then
  echo "FAIL: crates/pool-core/tests/golden/limits.txt is stale; run bash tests/pool_core_limits_golden_test.sh --write" >&2
  exit 1
fi
echo "pool-core limits golden ok ($(wc -l < "${golden}") cases)"
