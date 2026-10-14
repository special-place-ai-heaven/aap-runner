#!/bin/bash
# run_pool supervision with docker and the job loop stubbed out: a dead slot
# restarts alone, a slot that keeps dying fast is retired while the others
# keep running, the manager exits only when every slot is retired, and
# SIGTERM cleans up.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../distro/manager.sh
source "${here}/../distro/manager.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

log=$(mktemp)
err=$(mktemp)
trap 'rm -f "${log}" "${err}"' EXIT

starts() {
  grep -c "^start $1\$" "${log}" || true
}

# Stubs. The real ones call docker or sleep up to 60s. run_pool calls them.
# shellcheck disable=SC2317
remove_job_containers() {
  echo removed >> "${log}"
}
# shellcheck disable=SC2317
remove_slot_containers() {
  echo "cleaned $1" >> "${log}"
}
slot_restart_delay() {
  echo 0
}

# Slot 1 dies at once every time. Slot 2 stays up.
# shellcheck disable=SC2317
slot_loop() {
  trap - EXIT TERM INT
  echo "start $1" >> "${log}"
  if [[ "$1" == 2 ]]; then
    exec sleep 30
  fi
  exit 3
}
AAP_RUNNER_COUNT=2
(run_pool) 2> "${err}" &
pool=$!
for _ in $(seq 1 50); do
  grep -q '^slot 1 retired' "${err}" && break
  sleep 0.1
done
grep -qx "slot 1 retired after ${SLOT_MAX_FAILS} fast deaths; other slots keep running" "${err}" \
  || fail "slot 1 was not retired: $(cat "${err}")"
sleep 0.5
[[ "$(starts 1)" -eq "${SLOT_MAX_FAILS}" ]] || fail "slot 1 started $(starts 1) times; want ${SLOT_MAX_FAILS}"
[[ "$(starts 2)" -eq 1 ]] || fail "slot 2 started $(starts 2) times; a dead slot 1 must not restart it"
cleaned1=$(grep -c '^cleaned 1$' "${log}" || true)
[[ "${cleaned1}" -eq "${SLOT_MAX_FAILS}" ]] || fail "slot 1's container was removed ${cleaned1} times; want once per death (${SLOT_MAX_FAILS})"
if grep -q '^cleaned 2$' "${log}"; then
  fail "slot 1's death removed slot 2's container"
fi
kill -0 "${pool}" 2>/dev/null || fail "the manager stopped while slot 2 was still running"
if grep -qx removed "${log}"; then
  fail "retiring slot 1 removed the other slots' job containers"
fi
if grep -q 'all .* slots retired' "${err}"; then
  fail "the manager reported every slot retired while slot 2 was running"
fi
kill -TERM "${pool}"
rc=0
wait "${pool}" || rc=$?
[[ "${rc}" -eq 143 ]] || fail "SIGTERM exit was ${rc}; want 143"
echo "slot retires while the others keep running ok"

: > "${log}"
: > "${err}"
# Every slot dies at once every time.
# shellcheck disable=SC2317
slot_loop() {
  trap - EXIT TERM INT
  echo "start $1" >> "${log}"
  exit 3
}
AAP_RUNNER_COUNT=2
rc=0
(run_pool) 2> "${err}" || rc=$?
[[ "${rc}" -eq 1 ]] || fail "run_pool exited ${rc} after every slot retired; want 1"
[[ "$(starts 1)" -eq "${SLOT_MAX_FAILS}" ]] || fail "slot 1 started $(starts 1) times; want ${SLOT_MAX_FAILS}"
[[ "$(starts 2)" -eq "${SLOT_MAX_FAILS}" ]] || fail "slot 2 started $(starts 2) times; want ${SLOT_MAX_FAILS}"
grep -q '^slot 1 retired' "${err}" || fail "slot 1 was not retired"
grep -q '^slot 2 retired' "${err}" || fail "slot 2 was not retired"
grep -qx 'all 2 slots retired; stopping the manager' "${err}" || fail "no all-retired line: $(cat "${err}")"
grep -qx removed "${log}" || fail "the pool was not cleaned up when the manager stopped"
echo "manager exits 1 only when every slot retired ok"

: > "${log}"
# shellcheck disable=SC2317
slot_loop() {
  trap - EXIT TERM INT
  echo "start $1" >> "${log}"
  echo "pid ${BASHPID}" >> "${log}"
  exec sleep 30
}
AAP_RUNNER_COUNT=3
(run_pool) 2>/dev/null &
pool=$!
for _ in $(seq 1 50); do
  [[ "$(grep -c '^start' "${log}" || true)" -eq 3 ]] && break
  sleep 0.1
done
[[ "$(grep -c '^start' "${log}" || true)" -eq 3 ]] || fail "three slots did not start"
kill -TERM "${pool}"
rc=0
wait "${pool}" || rc=$?
[[ "${rc}" -eq 143 ]] || fail "SIGTERM exit was ${rc}; want 143"
grep -qx removed "${log}" || fail "SIGTERM did not remove job containers"
# exec makes each logged slot PID the sleep itself.
while read -r _ pid; do
  if kill -0 "${pid}" 2>/dev/null; then
    fail "slot pid ${pid} was still running after SIGTERM"
  fi
done < <(grep '^pid ' "${log}")
[[ "$(grep -c '^pid ' "${log}")" -eq 3 ]] || fail "expected three slot pids"
echo "sigterm cleanup ok"

echo "manager supervisor tests ok"
