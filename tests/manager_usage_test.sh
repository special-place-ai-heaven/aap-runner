#!/bin/bash
# Usage sampling: docker stats lines parsed into per-slot cores and GiB
# (mixed units, over 100%, a container in no slot), a failed docker stats
# keeps the previous sample and is logged once per 10, and samples start
# only every SAMPLE_INTERVAL_SECONDS. docker, timeout, and now_s are stubbed.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../distro/manager.sh
source "${here}/../distro/manager.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

RUN_DIR=$(mktemp -d)
trap 'rm -rf "${RUN_DIR}"' EXIT
calls="${RUN_DIR}/calls"
err="${RUN_DIR}/err"
AAP_RUNNER_COUNT=3
AAP_JOB_CPUS=24
AAP_JOB_MEMORY=72g
STATS_RC=0
NOW=1000

# shellcheck disable=SC2317
now_s() {
  echo "${NOW}"
}
# shellcheck disable=SC2317
timeout() {
  echo "timeout $1" >> "${calls}"
  shift
  "$@"
}
# shellcheck disable=SC2317
docker() {
  echo "docker $*" >> "${calls}"
  [[ "${STATS_RC}" -eq 0 ]] || return "${STATS_RC}"
  printf '%s\t%s\t%s\n' \
    aap-crrr-1-1-1 '123.45%' '11.3GiB / 24GiB' \
    aap-crrr-2-1-1 '0.50%' '512MiB / 24GiB' \
    aap-crrr-9-9-9 '50.00%' '1GiB / 24GiB' \
    aap-crrr-3-1-1 '--' '800KiB / 24GiB'
}
# Waits for the background sample, then lets tick_usage collect it.
settle() {
  while [[ -n "${USAGE_PID}" ]] && kill -0 "${USAGE_PID}" 2>/dev/null; do
    sleep 0.05
  done
}
samples() {
  grep -c '^docker stats' "${calls}" || true
}

printf 'running 1 aap-crrr-1-1-1 build\n' > "${RUN_DIR}/slot-1"
printf 'running 2 aap-crrr-2-1-1 lint\n' > "${RUN_DIR}/slot-2"
printf 'starting 3 aap-crrr-3-1-1 \n' > "${RUN_DIR}/slot-3"

got=$(docker stats | usage_lines)
want=$'1 aap-crrr-1-1-1 1.2 11.3\n2 aap-crrr-2-1-1 0.0 0.5\n3 aap-crrr-3-1-1 - 0.0'
[[ "${got}" == "${want}" ]] || fail "usage_lines gave:
${got}"
got=$(printf 'aap-crrr-1-1-1\t250.00%%\t1.5TiB / 2TiB\naap-crrr-2-1-1\t7%%\t2048B / 1GiB\n' | usage_lines)
[[ "${got}" == $'1 aap-crrr-1-1-1 2.5 1536.0\n2 aap-crrr-2-1-1 0.1 0.0' ]] || fail "TiB, B, or 250% gave:
${got}"
echo "parse ok"
: > "${calls}"

tick_usage 2> "${err}"
settle
[[ "$(samples)" == 1 ]] || fail "first tick did not sample"
grep -qx "timeout ${SAMPLE_BUDGET_SECONDS}" "${calls}" || fail "docker stats was not bounded: $(cat "${calls}")"
grep -qxF 'docker stats --no-stream --format {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' "${calls}" \
  || fail "docker stats argv: $(cat "${calls}")"
jq -e '.sampled_at != null and [.slots[] | [.cpu_cores, .mem_gib]] == [[1.2, 11.3], [0, 0.5], [null, 0]]
  and .pool.cpu_cores == 1.2 and .pool.mem_gib == 11.8' "${RUN_DIR}/status.json" >/dev/null \
  || fail "status after a sample: $(cat "${RUN_DIR}/status.json")"
echo "sample into status ok"

# Within the interval: no new sample. At the interval: one.
NOW=$((1000 + SAMPLE_INTERVAL_SECONDS - 1))
tick_usage 2>> "${err}"
settle
[[ "$(samples)" == 1 ]] || fail "sampled before the interval"
NOW=$((1000 + SAMPLE_INTERVAL_SECONDS))
tick_usage 2>> "${err}"
settle
[[ "$(samples)" == 2 ]] || fail "did not sample at the interval"
echo "interval ok"

# docker stats fails 11 times: the previous sample stays; 2 warnings.
before=$(cat "${RUN_DIR}/usage")
STATS_RC=1
for ((i = 2; i <= 12; i++)); do
  NOW=$((1000 + i * SAMPLE_INTERVAL_SECONDS))
  tick_usage 2>> "${err}"
  settle
done
NOW=$((NOW + 1))
tick_usage 2>> "${err}"
[[ "$(samples)" == 13 ]] || fail "$(samples) samples; want 13"
[[ "$(cat "${RUN_DIR}/usage")" == "${before}" ]] || fail "a failed docker stats changed the sample"
[[ "$(grep -c 'docker stats failed' "${err}")" == 2 ]] || fail "warnings: $(cat "${err}")"
grep -q 'docker stats failed (11 so far)' "${err}" || fail "no warning at the 11th failure: $(cat "${err}")"
jq -e '.slots[0].cpu_cores == 1.2' "${RUN_DIR}/status.json" >/dev/null || fail "status lost the previous sample"
if compgen -G "${RUN_DIR}/usage.tmp.*" >/dev/null; then
  fail "a temp usage file was left behind"
fi
echo "failure keeps the previous sample ok"

echo "manager usage tests ok"
