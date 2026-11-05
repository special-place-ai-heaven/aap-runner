#!/bin/bash
# Wall-clock probe for the runner VM. Samples CLOCK_REALTIME and CLOCK_BOOTTIME
# (python3, straight from the kernel) every 100 ms and reports backward realtime
# steps and the largest change of realtime minus boottime. A clean clock has
# no backward step and a drift change well under 100 ms: an NTP slew moves both
# clocks together, a step moves only realtime.
#
#   clock-probe.sh [SECONDS]      sample for SECONDS (default 1800), then report
#   clock-probe.sh --analyse      read "realtime_ns boottime_ns" lines on stdin
#
# Exit 0 when the clock is clean, 1 when it is not, 2 for a bad argument.
set -euo pipefail

MAX_DRIFT_CHANGE_MS=${MAX_DRIFT_CHANGE_MS:-100}

# "realtime_ns boottime_ns" per line -> report on stdout, exit 0 clean / 1 not.
analyse() {
  awk -v limit="${MAX_DRIFT_CHANGE_MS}" '
    NF != 2 { next }
    {
      rt = $1; bt = $2; d = rt - bt; n++
      if (n == 1) { lo = d; hi = d; prev = rt; next }
      if (rt < prev) {
        back++
        step = (prev - rt) / 1e6
        if (step > worst) worst = step
      }
      if (d < lo) lo = d
      if (d > hi) hi = d
      prev = rt
    }
    END {
      if (n < 2) { print "clock: fewer than 2 samples"; exit 1 }
      change = (hi - lo) / 1e6
      printf "clock: samples=%d backward_steps=%d worst_backward_ms=%.3f drift_change_ms=%.3f limit_ms=%d\n", n, back + 0, worst + 0, change, limit
      exit (back > 0 || change >= limit) ? 1 : 0
    }'
}

sample() { # SECONDS
  # Both clocks from the kernel in one process, back to back. Not /proc/uptime:
  # inside a Sysbox runner container sysbox-fs serves that file itself.
  python3 -c '
import sys, time
end = time.monotonic() + int(sys.argv[1])
while True:
    print(time.clock_gettime_ns(time.CLOCK_REALTIME), time.clock_gettime_ns(time.CLOCK_BOOTTIME), flush=True)
    if time.monotonic() >= end:
        break
    time.sleep(0.1)
' "$1"
}

main() {
  case "${1:-1800}" in
    --analyse) analyse ;;
    *[!0-9]* | "") echo "usage: $0 [SECONDS] | --analyse" >&2; exit 2 ;;
    *) sample "${1:-1800}" | analyse ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
