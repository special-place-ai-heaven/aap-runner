#!/bin/bash
# The runner clock: distro/clock-probe.sh --analyse passes a clean series and
# fails a backward step or a drift jump; bootstrap's configure_time_sync masks
# the distro's own time daemons (WSL keeps the VM clock) and refuses while any
# NTP daemon is still active.
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
grep -qE '^    chrony \\$' "${here}/../distro/bootstrap.sh" && fail "bootstrap installs chrony, a second clock authority"
grep -qx '  configure_time_sync' "${here}/../distro/bootstrap.sh" || fail "bootstrap never calls configure_time_sync"

calls="${work}/calls"
active=""
# shellcheck disable=SC2317
systemctl() {
  echo "systemctl $*" >> "${calls}"
  if [[ "${1-} ${2-}" == "is-active --quiet" ]]; then
    [[ " ${active} " == *" $3 "* ]]
    return
  fi
  return 0
}
eval "${fn}"

: > "${calls}"
(configure_time_sync) || fail "configure_time_sync failed with no time daemon active"
grep -qx 'systemctl mask systemd-timesyncd.service chrony.service' "${calls}" || fail "timesyncd and chrony were not masked"
grep -q '^systemctl stop systemd-timesyncd.service chrony.service' "${calls}" || fail "timesyncd and chrony were not stopped"
echo "no time daemon in the distro ok"

for unit in systemd-timesyncd chrony ntp ntpsec openntpd; do
  active="${unit}"
  (configure_time_sync) > /dev/null 2>&1 && fail "an active ${unit} was accepted"
done
active=""
echo "time daemon refusals ok"

echo "clock tests ok"
