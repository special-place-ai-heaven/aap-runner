#!/bin/bash
# accept-image.sh with docker, timeout, curl, systemctl and the manager
# stubbed. assemble copies only files that match their pins (bootstrap.sh
# included). verify refuses the live tag, a running manager and a held lock;
# removes leftovers; really executes the probe script against stub tools (so
# the zccache budget it passes is checked, not assumed); keeps its containers
# invisible to the pool (aap-accept-* names, no label, no env or mount, the
# preflight entrypoint only with --preflight); and always untags its own tag
# (never with -f), on success and on every failure path.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../distro/accept-image.sh
source "${here}/../distro/accept-image.sh"
set +e

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
log="${work}/docker.log"
ACCEPT_LOCK="${work}/accept.lock"
ACCEPT_TMP=${work}

# --- assemble -------------------------------------------------------------
src="${work}/src"
img="${work}/image"
mkdir -p "${src}" "${img}"
for f in "${ACCEPT_FILES[@]}"; do echo "content of ${f}" > "${src}/${f}"; done
echo "rootfs" > "${img}/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz"
echo "runner" > "${work}/runner.tgz"
ub_sha=$(sha256sum "${img}/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz" | cut -d' ' -f1)
rn_sha=$(sha256sum "${work}/runner.tgz" | cut -d' ' -f1)
cat > "${src}/bootstrap.sh" << EOF
UBUNTU_NAME=ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz
UBUNTU_SHA256=${ub_sha}
RUNNER_URL=https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz
RUNNER_SHA256=${rn_sha}
RUNNER_NAME=actions-runner-linux-x64-2.338.2.tar.gz
EOF
(cd "${src}" && sha256sum "${ACCEPT_FILES[@]}" bootstrap.sh) > "${src}/staging.sha256"
ACCEPT_INSTALL_IMAGE_DIR=${img}
# shellcheck disable=SC2317
curl() {
  local out=""
  while [[ $# -gt 0 ]]; do
    [[ "$1" == --output ]] && out=$2
    shift
  done
  cp "${work}/runner.tgz" "${out}"
}

out=$( (assemble "${src}" "${work}/ctx") 2>&1) || fail "assemble refused a good source: ${out}"
for f in "${ACCEPT_FILES[@]}" ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz actions-runner-linux-x64-2.338.2.tar.gz; do
  [[ -f "${work}/ctx/${f}" ]] || fail "assemble did not stage ${f}"
done
[[ ! -e "${work}/ctx/bootstrap.sh" ]] || fail "bootstrap.sh was put into the build context"
[[ ! -e "${work}/ctx/actions-runner-linux-x64-2.338.2.tar.gz.part" ]] || fail "a .part download was left behind"
echo "assemble downloads and stages ok"

(assemble "${src}" "${work}/ctx") > /dev/null 2>&1
[[ $? -eq 2 ]] || fail "assemble wrote into a non-empty context"

echo "tampered" >> "${src}/ephemeral-entry.sh"
(assemble "${src}" "${work}/ctx2") > /dev/null 2>&1 && fail "assemble accepted a file that does not match staging.sha256"
echo "content of ephemeral-entry.sh" > "${src}/ephemeral-entry.sh"

cp "${src}/bootstrap.sh" "${work}/bootstrap.good"
sed -i "s/^RUNNER_SHA256=.*/RUNNER_SHA256=$(printf 'f%.0s' {1..64})/" "${src}/bootstrap.sh"
(assemble "${src}" "${work}/ctx3") > /dev/null 2>&1 && fail "assemble read pins from a bootstrap.sh that does not match staging.sha256"
cp "${work}/bootstrap.good" "${src}/bootstrap.sh"

echo "evil" > "${work}/runner.tgz"
(assemble "${src}" "${work}/ctx4") > /dev/null 2>&1 && fail "assemble accepted a runner tarball that does not match its pin"
[[ ! -e "${work}/ctx4/actions-runner-linux-x64-2.338.2.tar.gz" ]] || fail "a runner tarball that failed its check was left in the context"
echo "assemble refusals ok"

# --- verify ---------------------------------------------------------------
ctx="${work}/vctx"
mkdir -p "${ctx}"
cp "${here}/../distro/Dockerfile" "${ctx}/Dockerfile"
want_runner=$(sed -nE 's/^COPY actions-runner-linux-x64-([0-9.]+)\.tar\.gz .*/\1/p' "${ctx}/Dockerfile")
want_node=$(sed -nE 's#.*nodejs\.org/dist/v([0-9.]+)/.*#\1#p' "${ctx}/Dockerfile" | head -n 1)
want_zc=$(sed -nE 's#.*releases/download/([0-9.]+)/\$\{archive\}.*#\1#p' "${ctx}/Dockerfile" | head -n 1)
[[ -n "${want_runner}" && -n "${want_node}" && -n "${want_zc}" ]] || fail "could not read the pins from distro/Dockerfile"

# The tools the probe script calls inside the image, as stubs on PATH.
bin="${work}/bin"
zc="${work}/zc"
mkdir -p "${bin}" "${zc}/bin"
export RUNNER_SEEN=${want_runner} NODE_SEEN=v${want_node}
printf '#!/bin/bash\n[[ "$1" == /proc/1/comm ]] && { echo docker-init; exit 0; }\nexec /bin/cat "$@"\n' > "${bin}/cat"
printf '#!/bin/bash\n[[ "$1" == -u ]] && shift 2\n[[ "$1" == -- ]] && shift\n[[ "$1" == */Runner.Listener ]] && { echo "${RUNNER_SEEN}"; exit 0; }\nexec "$@"\n' > "${bin}/runuser"
printf '#!/bin/bash\necho "${NODE_SEEN}"\n' > "${bin}/node"
printf '#!/bin/bash\necho 11.0.0\n' > "${bin}/npm"
printf '#!/bin/bash\necho jq-1.7.1\n' > "${bin}/jq"
printf '#!/bin/bash\necho runner\n' > "${bin}/id"
printf '#!/bin/bash\nexit 0\n' > "${bin}/install"
printf '#!/bin/bash\necho "zccache %s"\n' "${want_zc}" > "${zc}/bin/zccache"
# Mirrors aap-zccache.sh: a budget of 0 is "disabled", a positive one "direct".
cat > "${zc}/aap-zccache.sh" << EOF
#!/bin/bash
case "\$1" in
  init) echo "\$4" > "${zc}/budget" ;;
  state) if [[ "\$(cat "${zc}/budget")" =~ ^[1-9][0-9]*$ ]]; then echo '{"state":"direct","detail":"x","bytes":0}'; else echo '{"state":"disabled","detail":"no cache budget","bytes":null}'; fi ;;
esac
EOF
chmod +x "${bin}"/* "${zc}/bin/zccache" "${zc}/aap-zccache.sh"
ZC_DIR=${zc}

existing=""
build_rc=0
rmi_rc=0
manager_running=0
cat > "${work}/manager" << 'EOF'
#!/bin/bash
echo "manager $*" >> "${ACCEPT_TEST_LOG}"
exit "${ACCEPT_TEST_MOUNTS_RC:-0}"
EOF
chmod +x "${work}/manager"
ACCEPT_MANAGER=${work}/manager
export ACCEPT_TEST_LOG=${log}

# shellcheck disable=SC2317
systemctl() {
  if [[ "${manager_running}" == 1 ]]; then echo active; else echo "${manager_state-inactive}"; return 3; fi
}
# shellcheck disable=SC2317
timeout() {
  [[ "$1 $2" == "--foreground -k" ]] || fail "timeout without --foreground -k: $*"
  shift 4
  "$@"
}
# shellcheck disable=SC2317
docker() {
  echo "docker $*" >> "${log}"
  case "$1" in
    ps) [[ "$*" == *"name=^aap-accept-"* ]] && echo "stale-container" ;;
    images)
      if [[ "$2" == --format ]]; then printf '%s\n' "${existing}" aap-crrr-runner:local; else echo "${existing:+deadbeef}"; fi
      ;;
    rmi)
      [[ "$2" == "${existing}" && "${rmi_rc}" == 0 ]] && existing=""
      return "${rmi_rc}"
      ;;
    build) return "${build_rc}" ;;
    run) PATH="${bin}:/usr/bin:/bin" bash -c "${@: -1}" ;;
  esac
  return 0
}

run_verify() { # TAG -> sets rc, out
  : > "${log}"
  out=$( (verify "${ctx}" "$1") 2>&1)
  rc=$?
}

assert_cleaned() { # TAG
  grep -qx "docker rmi $1" "${log}" || fail "the tag $1 was not untagged: $(cat "${log}")"
  ! grep -q '^docker rmi .*-f' "${log}" || fail "rmi used -f"
  ! grep -q '^docker rmi aap-crrr-runner' "${log}" || fail "the live tag was touched"
}

manager_running=1
run_verify aap-accept:t0
[[ "${rc}" -eq 2 && "${out}" == *"aap-runner-manager is 'active'"* ]] || fail "verify ran beside an active manager (rc ${rc}): ${out}"
! grep -q '^docker build' "${log}" || fail "a build ran beside an active manager"
manager_running=0
for manager_state in deactivating activating unknown ""; do
  run_verify aap-accept:tm
  [[ "${rc}" -eq 2 ]] || fail "verify ran beside a manager that is '${manager_state}' (rc ${rc}): ${out}"
done
manager_state=failed
run_verify aap-accept:tf
[[ "${rc}" -eq 0 ]] || fail "verify refused a failed (stopped) manager (rc ${rc}): ${out}"
manager_state=inactive manager_running=1 ACCEPT_ALLOW_LIVE_POOL=1
run_verify aap-accept:to
[[ "${rc}" -eq 0 ]] || fail "ACCEPT_ALLOW_LIVE_POOL=1 did not override (rc ${rc}): ${out}"
manager_running=0 ACCEPT_ALLOW_LIVE_POOL=0

run_verify aap-crrr-runner:local
[[ "${rc}" -eq 2 ]] || fail "the live tag was accepted (rc ${rc})"
! grep -q '^docker build' "${log}" || fail "a build ran for a refused tag"

exec 8> "${ACCEPT_LOCK}"
flock 8
run_verify aap-accept:tl
[[ "${rc}" -eq 2 && "${out}" == *"holds"* ]] || fail "verify ran while another run held the lock (rc ${rc}): ${out}"
exec 8>&-
echo "verify refusals ok"

existing=aap-accept:old rmi_rc=1
run_verify aap-accept:old
[[ "${rc}" -eq 2 && "${out}" == *"already exists"* ]] || fail "a leftover that could not be untagged was built over (rc ${rc}): ${out}"
existing=aap-accept:old rmi_rc=0
run_verify aap-accept:t1
[[ "${rc}" -eq 0 ]] || fail "a run after a leftover failed (rc ${rc}): ${out}"
grep -qx 'docker rm -f stale-container' "${log}" || fail "a leftover container was not removed"
grep -qx 'docker rmi aap-accept:old' "${log}" || fail "a leftover tag was not untagged"
[[ "${out}" == *"untagged leftover aap-accept:old"* ]] || fail "a removed leftover tag was not announced: ${out}"
echo "leftovers ok"

run_verify aap-accept:t2
[[ "${rc}" -eq 0 && "${out}" == *"accept: PASS"* ]] || fail "a good image did not pass (rc ${rc}): ${out}"
for c in build mounts preflight init runner node npm jq zccache sccache sudo zccache-init; do
  [[ "${out}" == *"accept: ${c} ok"* ]] || fail "check ${c} was not reported ok: ${out}"
done
[[ "$(cat "${zc}/budget")" =~ ^[1-9][0-9]*$ ]] || fail "the probe gave zccache init a budget of '$(cat "${zc}/budget")'"
grep -qE -- '^docker create --pull=never --runtime=sysbox-runc --init --name aap-accept-preflight-[0-9]+ --entrypoint /opt/aap-runner/ephemeral-entry.sh aap-accept:t2 --preflight$' "${log}" \
  || fail "the preflight is not the bootstrap sequence with --init and --preflight"
grep -q '^manager --assert-mounts aap-accept-preflight-' "${log}" || fail "the preflight mounts were not asserted"
grep -q -- '^docker run --rm --pull=never --runtime=sysbox-runc --init --name aap-accept-probe-' "${log}" || fail "the probe is not Sysbox with --init"
! grep -q 'aap-crrr-job' "${log}" || fail "an acceptance container carries the pool label"
! grep -qE 'docker (create|run).* (-e|--env|--env-file|-v|--volume|--mount|--tmpfs|--device|--privileged|--cap-add)([ =]|$)' "${log}" || fail "an acceptance container was given an environment or a mount"
grep -q '^docker rm -f aap-accept-preflight-' "${log}" || fail "the preflight container was not removed"
assert_cleaned aap-accept:t2
echo "verify pass, pool invisibility and cleanup ok"

ZC_PROBE_BUDGET=0
run_verify aap-accept:tz
[[ "${rc}" -eq 1 && "${out}" == *'accept: zccache-init FAIL'* ]] || fail "a zero budget passed zccache-init (rc ${rc}): ${out}"
ZC_PROBE_BUDGET=1073741824

RUNNER_SEEN=2.338.0
run_verify aap-accept:t3
[[ "${rc}" -eq 1 && "${out}" == *"accept: runner FAIL (want '${want_runner}', got '2.338.0')"* ]] || fail "a wrong runner passed (rc ${rc}): ${out}"
[[ "${out}" == *"log ${work}/aap-accept."* ]] || fail "a failed run did not name its kept log"
assert_cleaned aap-accept:t3
RUNNER_SEEN=${want_runner}

build_rc=1
run_verify aap-accept:t4
[[ "${rc}" -eq 1 && "${out}" == *"accept: build FAIL"* ]] || fail "a failed build did not fail (rc ${rc}): ${out}"
! grep -qE '^docker (create|run)' "${log}" || fail "containers ran after a failed build"
assert_cleaned aap-accept:t4
build_rc=0

export ACCEPT_TEST_MOUNTS_RC=1
run_verify aap-accept:t5
[[ "${rc}" -eq 1 && "${out}" == *"accept: mounts FAIL"* ]] || fail "a refused mount check did not fail (rc ${rc}): ${out}"
! grep -q '^docker start' "${log}" || fail "the preflight started after a failed mount check"
assert_cleaned aap-accept:t5
unset ACCEPT_TEST_MOUNTS_RC
echo "verify failures still clean up ok"

echo "accept image tests ok"
