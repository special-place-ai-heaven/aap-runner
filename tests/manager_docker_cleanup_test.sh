#!/bin/bash
# A docker removal that fails is logged with the container's name, a failed
# docker ps in remove_slot_containers is logged rather than read as "no
# containers", and the job wall clock ends with docker kill when docker stop
# and docker rm -f both fail, so the attached docker start returns.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../distro/manager.sh
source "${here}/../distro/manager.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
err="${work}/err"

# shellcheck disable=SC2317
docker() { return 1; }
cleanup_job aap-crrr-1-111-222 aap-crrr-1-111-222 2> "${err}" || fail "cleanup_job failed the caller"
grep -q 'could not remove job container aap-crrr-1-111-222' "${err}" || fail "a failed docker rm was not logged: $(cat "${err}")"
grep -q 'could not remove job network aap-crrr-1-111-222' "${err}" || fail "a failed network rm was not logged: $(cat "${err}")"
echo "cleanup_job logs failed removals ok"

remove_slot_containers 3 2> "${err}" || fail "remove_slot_containers failed the caller"
grep -q 'slot 3: could not list its job containers' "${err}" || fail "a failed docker ps was not logged: $(cat "${err}")"
# shellcheck disable=SC2317
docker() {
  case "$1" in
    ps) echo abc123 ;;
    inspect) echo /aap-crrr-3-1-2 ;;
    rm) return 1 ;;
  esac
  return 0
}
remove_slot_containers 3 2> "${err}" || fail "remove_slot_containers failed the caller"
grep -q 'slot 3: could not remove job container aap-crrr-3-1-2' "${err}" || fail "a failed docker rm was not logged: $(cat "${err}")"
echo "remove_slot_containers logs docker failures ok"
unset -f docker

# The wall clock runs in its own session, so docker is a PATH shim here.
mkdir -p "${work}/bin"
cat > "${work}/bin/docker" <<EOF
#!/bin/bash
echo "\$1" >> "${work}/clock_calls"
[[ "\$1" == kill ]]
EOF
chmod +x "${work}/bin/docker"
pid=$(PATH="${work}/bin:${PATH}" arm_wall_clock 0 aap-crrr-1-333-444 2> "${err}")
for _ in $(seq 1 50); do
  kill -0 "${pid}" 2>/dev/null || break
  sleep 0.1
done
kill -0 "${pid}" 2>/dev/null && fail "the wall clock did not finish"
grep -qx kill "${work}/clock_calls" || fail "the wall clock never ran docker kill after stop and rm failed: $(tr '\n' ' ' < "${work}/clock_calls")"
[[ "$(tail -n 1 "${work}/clock_calls")" == kill ]] || fail "docker kill is not the last wall-clock step"
echo "wall clock kills the container when stop and rm fail ok"

echo "manager docker cleanup tests ok"
