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

# shellcheck source=../distro/manager.sh
source "${here}/../distro/manager.sh"

# Stubs for the side effects around the lim block in run_one.
bound_sccache_tree() { :; }
install() { :; }
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

# run_case count cpus memory pids sharing io_percent disk_mibps|none device|none
# Prints one line: the inputs, then " => " and either the docker arguments or "refused".
run_case() {
  local header="count=$1 cpus=$2 memory=$3 pids=$4 sharing=$5 io_percent=$6 disk_mibps=$7 device=$8"
  local out
  out=$(
    exec 2> /dev/null
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
      # resolve_io_device: no device behind the mount drops the cap.
      IO_DEVICE=""
      if ((SLOT_IO_MBPS > 0)); then
        if [[ "$8" == none ]]; then
          SLOT_IO_MBPS=0
          POOL_IO_MBPS=0
        else
          IO_DEVICE=$8
        fi
      fi
      run_one 1 || true
    else
      echo refused
    fi
  )
  echo "${header} => ${out}"
}

generate() {
  local n sharing cpus mem pct
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
  for cpus in 0 0.0 0.000001 000006 999999999 999999999.999999; do
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
