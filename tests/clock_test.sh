#!/bin/bash
# The runner clock: distro/clock-probe.sh --analyse passes a clean series and
# fails a backward step or a drift jump; bootstrap's configure_time_sync lets
# chrony set the clock (SYNC_IN_CONTAINER=yes), refuses a defaults file it
# cannot fix, and refuses when systemd-timesyncd is still active beside it.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
probe="${here}/../distro/clock-probe.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# series START_NS COUNT [STEP_AT STEP_NS] [JUMP_AT JUMP_NS]: 100 ms samples.
# A step moves realtime back; a jump moves realtime against boottime forward.
series() {
  local i rt bt off=0
  for ((i = 0; i < $2; i++)); do
    rt=$(($1 + i * 100000000 + off))
    bt=$((5000000000 + i * 100000000))
    [[ "${3:-}" == "${i}" ]] && off=$((off - $4)) && rt=$((rt - $4))
    [[ "${5:-}" == "${i}" ]] && off=$((off + $6)) && rt=$((rt + $6))
    printf '%s %s\n' "${rt}" "${bt}"
  done
}

out=$(series 1700000000000000000 300 | bash "${probe}" --analyse) || fail "a clean series failed: ${out}"
[[ "${out}" == *"backward_steps=0"* && "${out}" == *"drift_change_ms=0.000"* ]] || fail "clean report: ${out}"
echo "clean series ok"

if out=$(series 1700000000000000000 300 150 1300000000 | bash "${probe}" --analyse); then
  fail "a 1.3 s backward step passed: ${out}"
fi
[[ "${out}" == *"backward_steps=1"* && "${out}" == *"worst_backward_ms=1200.000"* ]] || fail "step report: ${out}"
# The backward-step check on its own: a 1 s drift limit lets only it fail the series.
if out=$(series 1700000000000000000 300 150 300000000 | MAX_DRIFT_CHANGE_MS=1000 bash "${probe}" --analyse); then
  fail "a 0.3 s backward step passed under a 1 s drift limit: ${out}"
fi
[[ "${out}" == *"backward_steps=1"* && "${out}" == *"drift_change_ms=300.000"* ]] || fail "isolated step report: ${out}"
echo "backward step fails ok"

if out=$(series 1700000000000000000 300 "" 0 100 150000000 | bash "${probe}" --analyse); then
  fail "a 150 ms forward jump passed: ${out}"
fi
[[ "${out}" == *"backward_steps=0"* && "${out}" == *"drift_change_ms=150.000"* ]] || fail "jump report: ${out}"
out=$(series 1700000000000000000 300 "" 0 100 50000000 | bash "${probe}" --analyse) || fail "a 50 ms jump failed: ${out}"
echo "drift limit ok"

if printf '1 2\n' | bash "${probe}" --analyse > /dev/null; then fail "one sample passed"; fi
rc=0
bash "${probe}" 12x > /dev/null 2>&1 || rc=$?
[[ "${rc}" -eq 2 ]] || fail "a bad argument exited ${rc}, not 2"
echo "probe arguments ok"

# --- configure_time_sync ----------------------------------------------------
fn=$(sed -n '/^configure_time_sync() {/,/^}/p' "${here}/../distro/bootstrap.sh")
[[ -n "${fn}" ]] || fail "bootstrap.sh has no configure_time_sync"
grep -qE '^    chrony \\$' "${here}/../distro/bootstrap.sh" || fail "chrony is not in bootstrap's package list"
grep -qx '  configure_time_sync' "${here}/../distro/bootstrap.sh" || fail "bootstrap never calls configure_time_sync"

calls="${work}/calls"
timesyncd_active=1
# shellcheck disable=SC2317
systemctl() {
  echo "systemctl $*" >> "${calls}"
  [[ "$*" == "is-active --quiet systemd-timesyncd" ]] && return "${timesyncd_active}"
  return 0
}
eval "${fn}"

CHRONY_DEFAULTS="${work}/chrony"
printf 'DAEMON_OPTS="-F 1"\nSYNC_IN_CONTAINER="no"\n' > "${CHRONY_DEFAULTS}"
: > "${calls}"
(configure_time_sync) || fail "configure_time_sync failed on a stock defaults file"
grep -qx 'SYNC_IN_CONTAINER="yes"' "${CHRONY_DEFAULTS}" || fail "SYNC_IN_CONTAINER was not set to yes"
grep -qx 'DAEMON_OPTS="-F 1"' "${CHRONY_DEFAULTS}" || fail "the other defaults lines were changed"
grep -qx 'systemctl restart chrony' "${calls}" || fail "chrony was not restarted"
echo "chrony may set the clock ok"

printf 'DAEMON_OPTS="-F 1"\n' > "${CHRONY_DEFAULTS}"
(configure_time_sync) > /dev/null 2>&1 && fail "a defaults file without SYNC_IN_CONTAINER was accepted"

printf 'SYNC_IN_CONTAINER="no"\n' > "${CHRONY_DEFAULTS}"
timesyncd_active=0
(configure_time_sync) > /dev/null 2>&1 && fail "chrony beside an active systemd-timesyncd was accepted"
echo "time sync refusals ok"

echo "clock tests ok"
