#!/bin/bash
# accept-image.sh with docker, timeout, curl and the manager stubbed: assemble
# copies only files that match their pins; verify refuses the live tag and an
# existing tag, reports each check, keeps its containers invisible to the pool
# (aap-accept-* names, no aap-crrr-job label), never registers, and always
# untags its own tag (never with -f), on success and on every failure path.
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

# --- assemble -------------------------------------------------------------
src="${work}/src"
img="${work}/image"
mkdir -p "${src}" "${img}"
for f in "${ACCEPT_FILES[@]}"; do echo "content of ${f}" > "${src}/${f}"; done
(cd "${src}" && sha256sum "${ACCEPT_FILES[@]}") > "${src}/staging.sha256"
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
[[ ! -e "${work}/ctx/actions-runner-linux-x64-2.338.2.tar.gz.part" ]] || fail "a .part download was left behind"
echo "assemble downloads and stages ok"

(assemble "${src}" "${work}/ctx") > /dev/null 2>&1
[[ $? -eq 2 ]] || fail "assemble wrote into a non-empty context"

echo "tampered" >> "${src}/ephemeral-entry.sh"
(assemble "${src}" "${work}/ctx2") > /dev/null 2>&1 && fail "assemble accepted a file that does not match staging.sha256"
echo "content of ephemeral-entry.sh" > "${src}/ephemeral-entry.sh"

echo "evil" > "${work}/runner.tgz"
(assemble "${src}" "${work}/ctx3") > /dev/null 2>&1 && fail "assemble accepted a runner tarball that does not match its pin"
echo "assemble refusals ok"

# --- verify ---------------------------------------------------------------
ctx="${work}/vctx"
mkdir -p "${ctx}"
cp "${here}/../distro/Dockerfile" "${ctx}/Dockerfile"
want_runner=$(sed -nE 's/^COPY actions-runner-linux-x64-([0-9.]+)\.tar\.gz .*/\1/p' "${ctx}/Dockerfile")
want_node=$(sed -nE 's#.*nodejs\.org/dist/v([0-9.]+)/.*#\1#p' "${ctx}/Dockerfile" | head -n 1)
[[ -n "${want_runner}" && -n "${want_node}" ]] || fail "could not read the pins from distro/Dockerfile"

existing=""
build_rc=0
runner_seen=${want_runner}
cat > "${work}/manager" << 'EOF'
#!/bin/bash
echo "manager $*" >> "${ACCEPT_TEST_LOG}"
exit "${ACCEPT_TEST_MOUNTS_RC:-0}"
EOF
chmod +x "${work}/manager"
ACCEPT_MANAGER=${work}/manager
export ACCEPT_TEST_LOG=${log}

# shellcheck disable=SC2317
timeout() {
  shift
  "$@"
}
# shellcheck disable=SC2317
docker() {
  echo "docker $*" >> "${log}"
  case "$1" in
    images) echo "${existing}" ;;
    build) return "${build_rc}" ;;
    run)
      printf '%s\n' pid1=docker-init "runner=${runner_seen}" "node=v${want_node}" npm=present jq=jq-1.7.1 \
        "zccache=zccache 1.15.6" sccache=absent sudo=none 'zcstate={"state":"direct","detail":"x","bytes":0}'
      ;;
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
}

run_verify aap-crrr-runner:local
[[ "${rc}" -eq 2 ]] || fail "the live tag was accepted (rc ${rc})"
! grep -q '^docker build' "${log}" || fail "a build ran for a refused tag"
existing=deadbeef
run_verify aap-accept:t1
[[ "${rc}" -eq 2 ]] || fail "an existing tag was accepted (rc ${rc})"
! grep -q '^docker build' "${log}" || fail "a build ran over an existing tag"
! grep -q '^docker rmi' "${log}" || fail "an existing tag was untagged"
existing=""
echo "verify refusals ok"

run_verify aap-accept:t2
[[ "${rc}" -eq 0 && "${out}" == *"accept: PASS"* ]] || fail "a good image did not pass (rc ${rc}): ${out}"
for c in build mounts preflight init runner node npm jq zccache sccache sudo zccache-init; do
  [[ "${out}" == *"accept: ${c} ok"* ]] || fail "check ${c} was not reported ok: ${out}"
done
grep -q -- '^docker create --runtime=sysbox-runc --init --name aap-accept-preflight-' "${log}" || fail "the preflight is not Sysbox with --init"
grep -q '^manager --assert-mounts aap-accept-preflight-' "${log}" || fail "the preflight mounts were not asserted"
grep -q -- '^docker run --rm --runtime=sysbox-runc --init --name aap-accept-probe-' "${log}" || fail "the probe is not Sysbox with --init"
! grep -q 'aap-crrr-job' "${log}" || fail "an acceptance container carries the pool label"
! grep -qE 'docker (create|run).* (-e|--env) ' "${log}" || fail "an acceptance container was given an environment"
grep -q '^docker rm -f aap-accept-preflight-' "${log}" || fail "the preflight container was not removed"
assert_cleaned aap-accept:t2
echo "verify pass, pool invisibility and cleanup ok"

runner_seen=2.338.0
run_verify aap-accept:t3
[[ "${rc}" -eq 1 && "${out}" == *"accept: runner FAIL (want '${want_runner}', got '2.338.0')"* ]] || fail "a wrong runner passed (rc ${rc}): ${out}"
assert_cleaned aap-accept:t3
runner_seen=${want_runner}

build_rc=1
run_verify aap-accept:t4
[[ "${rc}" -eq 1 && "${out}" == *"accept: build FAIL"* ]] || fail "a failed build did not fail (rc ${rc}): ${out}"
! grep -qE '^docker (create|run)' "${log}" || fail "containers ran after a failed build"
assert_cleaned aap-accept:t4
build_rc=0

export ACCEPT_TEST_MOUNTS_RC=1
run_verify aap-accept:t5
[[ "${rc}" -eq 1 && "${out}" == *"accept: mounts FAIL"* ]] || fail "a mount under /mnt did not fail (rc ${rc}): ${out}"
! grep -q '^docker start' "${log}" || fail "the preflight started after a failed mount check"
assert_cleaned aap-accept:t5
unset ACCEPT_TEST_MOUNTS_RC
echo "verify failures still clean up ok"

echo "accept image tests ok"
