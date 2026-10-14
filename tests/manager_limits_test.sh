#!/bin/bash
# /etc/aap-runner/limits.conf: five keys override manager.conf and then pass
# the normal checks; anything else is refused. Each case runs
# aap-runner-manager --check-limits in a new bash, so set -e acts as under
# systemd. id and stat's owner are stubbed so no root is needed. No docker.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
manager="${here}/../manager.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
conf="${work}/manager.conf"
limits="${work}/limits.conf"
# A measured 1000 MiB/s work disk: the default 90% is 900 for the pool.
mbps="${work}/work-disk.mbps"
echo 1000 > "${mbps}"
cat > "${conf}" <<'CONF'
AAP_GITHUB_ORG=example-org
AAP_GITHUB_APP_ID=12345
AAP_GITHUB_APP_INSTALLATION_ID=67890
AAP_GITHUB_APP_PRIVATE_KEY_PATH=/etc/aap-runner/app.pem
AAP_RUNNER_IMAGE=aap-crrr-runner:local
AAP_RUNNER_BASE_LABEL=fresh
AAP_RUNNER_GROUP=aap-crrr
AAP_WORK_DISK_GIB=100
AAP_JOB_MEMORY=12g
AAP_JOB_CPUS=6
AAP_RUNNER_COUNT=1
CONF
chmod 0400 "${conf}"

# check_limits [limits owner uid]: prints --check-limits output and stderr.
check_limits() {
  bash -c '
    source "$1"
    CONFIG_PATH=$2
    LIMITS_PATH=$3
    limits_owner=$4
    WORK_DISK_MBPS_FILE=$5
    id() { echo 0; }
    stat() {
      if [[ "$2" == "%u" ]]; then
        if [[ "$3" == "${LIMITS_PATH}" ]]; then echo "${limits_owner}"; else echo 0; fi
      else
        command stat "$@"
      fi
    }
    main --check-limits
  ' _ "${manager}" "${conf}" "${limits}" "${1:-0}" "${mbps}" 2>&1
}

# write_limits MODE LINE...
write_limits() {
  local mode="$1"
  shift
  printf '%s\n' "$@" > "${limits}"
  chmod "${mode}" "${limits}"
}

refused() {
  local want="$1" out rc=0
  shift
  out=$(check_limits "$@") || rc=$?
  [[ "${rc}" -eq 1 ]] || fail "check-limits exited ${rc}; want 1: ${out}"
  [[ "${out}" == *"${want}"* ]] || fail "refusal does not say '${want}': ${out}"
  if grep -q '^AAP_RUNNER_COUNT=' <<< "${out}"; then
    fail "a refused file still printed limits: ${out}"
  fi
}

rm -f "${limits}"
out=$(check_limits) || fail "no limits.conf was refused: ${out}"
[[ "${out}" == $'AAP_RUNNER_COUNT=1\nAAP_JOB_CPUS=6\nAAP_JOB_MEMORY=12g\nAAP_JOB_IO_PERCENT=90\nAAP_JOB_IO_MBPS=900\nAAP_POOL_SHARING=slice' ]] || fail "manager.conf limits: ${out}"
echo "no limits.conf keeps manager.conf ok"

write_limits 0644 '# from the tray' 'AAP_RUNNER_COUNT=3' 'AAP_JOB_CPUS=24' 'AAP_JOB_MEMORY=72g'
out=$(check_limits) || fail "a valid limits.conf was refused: ${out}"
[[ "${out}" == $'AAP_RUNNER_COUNT=3\nAAP_JOB_CPUS=24\nAAP_JOB_MEMORY=72g\nAAP_JOB_IO_PERCENT=90\nAAP_JOB_IO_MBPS=300\nAAP_POOL_SHARING=slice' ]] || fail "override output: ${out}"
write_limits 0600 'AAP_RUNNER_COUNT=2'
out=$(check_limits) || fail "a count-only limits.conf was refused: ${out}"
[[ "${out}" == $'AAP_RUNNER_COUNT=2\nAAP_JOB_CPUS=6\nAAP_JOB_MEMORY=12g\nAAP_JOB_IO_PERCENT=90\nAAP_JOB_IO_MBPS=450\nAAP_POOL_SHARING=slice' ]] || fail "partial override output: ${out}"
write_limits 0644 'AAP_RUNNER_COUNT=2' 'AAP_JOB_IO_PERCENT=50'
out=$(check_limits) || fail "AAP_JOB_IO_PERCENT in limits.conf was refused: ${out}"
[[ "${out}" == *$'AAP_JOB_IO_PERCENT=50\nAAP_JOB_IO_MBPS=250\nAAP_POOL_SHARING=slice' ]] || fail "io percent override output: ${out}"
write_limits 0644 'AAP_JOB_IO_PERCENT=0'
out=$(check_limits) || fail "AAP_JOB_IO_PERCENT=0 was refused: ${out}"
[[ "${out}" == *$'AAP_JOB_IO_PERCENT=0\nAAP_JOB_IO_MBPS=0\nAAP_POOL_SHARING=slice' ]] || fail "io percent 0 output: ${out}"
write_limits 0644 'AAP_POOL_SHARING=fixed'
out=$(check_limits) || fail "AAP_POOL_SHARING=fixed in limits.conf was refused: ${out}"
[[ "${out}" == *$'\nAAP_POOL_SHARING=fixed' ]] || fail "sharing override output: ${out}"
echo "limits.conf override ok"

write_limits 0644 'AAP_RUNNER_COUNT=2' 'AAP_GITHUB_APP_ID=999'
refused "key AAP_GITHUB_APP_ID is not"
write_limits 0644 'AAP_JOB_PIDS_LIMIT=100'
refused "key AAP_JOB_PIDS_LIMIT is not"
echo "unknown key refused ok"

write_limits 0664 'AAP_RUNNER_COUNT=2'
refused "not group or world writable (found mode 664"
write_limits 0646 'AAP_RUNNER_COUNT=2'
refused "not group or world writable (found mode 646"
write_limits 0644 'AAP_RUNNER_COUNT=2'
refused "uid 1000" 1000
echo "bad mode and owner refused ok"

write_limits 0644 'AAP_JOB_CPUS='
refused "has no value for AAP_JOB_CPUS"
write_limits 0644 'AAP_JOB_CPUS'
refused "has no value for AAP_JOB_CPUS"
write_limits 0644 'AAP_RUNNER_COUNT=5'
refused "AAP_RUNNER_COUNT=5 is not 1..4"
write_limits 0644 'AAP_JOB_MEMORY=12gb'
refused "AAP_JOB_MEMORY=12gb"
write_limits 0644 'AAP_JOB_IO_PERCENT=101'
refused "AAP_JOB_IO_PERCENT=101 is not 0..100"
write_limits 0644 'AAP_POOL_SHARING=dynamic'
refused "AAP_POOL_SHARING=dynamic is not slice or fixed"
write_limits 0644 'AAP_RUNNER_COUNT=4' 'AAP_JOB_CPUS=2'
refused "each slot needs 1 cpu and 1g"
write_limits 0644 $'AAP_RUNNER_COUNT=2\r'
refused "config line contains CR"
echo "malformed values refused ok"

echo "manager limits tests ok"
