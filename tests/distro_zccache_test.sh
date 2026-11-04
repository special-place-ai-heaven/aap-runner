#!/bin/bash
# The image installs zccache from copies of the guest integration that are
# staged flat into the docker build context (staging.sha256 resolves names in
# distro/ only). The copies must equal the originals in guests/cache, the
# Dockerfile must pin the same archive as wrappers.json, and no sccache wiring
# may remain in the distro. Refresh the copies with:
#   cp guests/cache/linux/aap-zccache.sh distro/aap-zccache.sh
#   cp guests/cache/wrappers.json distro/zccache-wrappers.json
# and regenerate distro/staging.sha256.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root="${here}/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cmp -s "${root}/guests/cache/linux/aap-zccache.sh" "${root}/distro/aap-zccache.sh" || fail "distro/aap-zccache.sh differs from guests/cache/linux/aap-zccache.sh"
cmp -s "${root}/guests/cache/wrappers.json" "${root}/distro/zccache-wrappers.json" || fail "distro/zccache-wrappers.json differs from guests/cache/wrappers.json"
echo "staged copies equal the originals"

plat=$(jq -c '.platforms["linux-x86_64"]' "${root}/distro/zccache-wrappers.json")
version=$(jq -r '.zccache.version' "${root}/distro/zccache-wrappers.json")
archive=$(jq -r '.archive' <<< "${plat}")
sha=$(jq -r '.archive_sha256' <<< "${plat}")
dockerfile="${root}/distro/Dockerfile"
grep -qF "archive=${archive}" "${dockerfile}" || fail "Dockerfile does not install ${archive}"
grep -qF "sha=${sha}" "${dockerfile}" || fail "Dockerfile does not pin sha256 ${sha}"
grep -qF "releases/download/${version}/" "${dockerfile}" || fail "Dockerfile does not download release ${version}"
grep -qF 'sha256sum -c -' "${dockerfile}" || fail "Dockerfile does not check the archive with sha256sum -c"
grep -qF 'COPY aap-zccache.sh ' "${dockerfile}" || fail "Dockerfile does not COPY aap-zccache.sh"
grep -qF 'COPY zccache-wrappers.json ' "${dockerfile}" || fail "Dockerfile does not COPY zccache-wrappers.json"
echo "dockerfile pin ok"

for f in aap-zccache.sh zccache-wrappers.json; do
  grep -qE "^[0-9a-f]{64}  ${f}\$" "${root}/distro/staging.sha256" || fail "staging.sha256 does not list ${f}"
  grep -qF "copy_staged ${f} " "${root}/distro/bootstrap.sh" || fail "bootstrap.sh does not stage ${f} into the image context"
  grep -qF "\${SCRIPT_DIR}/${f}\"" "${root}/distro/bootstrap.sh" || fail "bootstrap.sh does not copy ${f} into the install stage"
done
echo "staging ok"

# No maintained sccache wiring: the image, the manager and the entrypoint.
if grep -niE 'sccache' "${dockerfile}" "${root}/distro/manager.sh" "${root}/distro/ephemeral-entry.sh" "${root}/distro/manager.conf.example" | grep -viE 'is not installed|the old'; then
  fail "sccache is still mentioned in the distro runtime files"
fi
echo "no sccache wiring ok"

# A compiler version the cache has no evidence for never fails a build and
# never reaches zccache: init reports `direct`, wires nothing, and the shim
# runs the compiler as it is. The qualification evidence names rustc 1.99.0;
# the toolchain here is 1.99.1, and a second case has no recorded toolchain
# at all (a rustc that jobs install themselves).
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
script="${root}/distro/aap-zccache.sh"
mkdir -p "${work}/bin"
printf '#!/bin/bash\n: > "$(dirname "$0")/../zccache-was-called"\nexit 99\n' > "${work}/fake-zccache"
printf '#!/bin/bash\nexit 99\n' > "${work}/fake-zccache-fp"
printf '#!/bin/bash\necho "fake rustc ran: $*"\nexit 3\n' > "${work}/bin/rustc"
chmod +x "${work}/fake-zccache" "${work}/fake-zccache-fp" "${work}/bin/rustc"

make_install() { # DIR [TOOLCHAIN_VERSION]
  local dir=$1 real
  mkdir -p "${dir}/bin"
  cp "${work}/fake-zccache" "${dir}/bin/zccache"
  cp "${work}/fake-zccache-fp" "${dir}/bin/zccache-fp"
  jq --arg a "$(sha256sum "${dir}/bin/zccache" | cut -d' ' -f1)" --arg b "$(sha256sum "${dir}/bin/zccache-fp" | cut -d' ' -f1)" '
    .platforms["linux-x86_64"].members |= map(.sha256 = (if .name == "zccache" then $a else $b end))
    | .platforms["linux-x86_64"].qualified = [{compiler: "rustc", compiler_version: "1.99.0", invocation: "rustc-wrapper", evidence_ref: "x"}]' \
    "${root}/distro/zccache-wrappers.json" > "${dir}/wrappers.json"
  install -m 0755 "${script}" "${dir}/aap-zccache.sh"
  install -m 0755 "${script}" "${dir}/zcshim"
  if [[ -n "${2:-}" ]]; then
    real=$(readlink -f "${work}/bin/rustc")
    jq -n --arg v "$2" --arg p "${work}/bin/rustc" --arg r "${real}" --arg s "$(sha256sum "${real}" | cut -d' ' -f1)" \
      '{schema: 1, toolchains: [{compiler: "rustc", compiler_version: $v, path: $p, real: $r, sha256: $s, bytes: 1, mtime: 1}]}' > "${dir}/toolchains.json"
  fi
}

for version in 1.99.1 none; do
  inst="${work}/install-${version}"
  job="${work}/job-${version}"
  if [[ "${version}" == none ]]; then make_install "${inst}"; else make_install "${inst}" "${version}"; fi
  bash "${inst}/aap-zccache.sh" init "${inst}" "${job}" 1073741824 > /dev/null || fail "init failed for rustc ${version}"
  [[ "$(jq -r .state "${job}/state/config.json")" == direct ]] || fail "rustc ${version}: init did not report direct: $(jq -c '[.state,.detail]' "${job}/state/config.json")"
  [[ ! -s "${job}/state/runner.env" ]] || fail "rustc ${version}: init wired something: $(cat "${job}/state/runner.env")"
  bash "${inst}/aap-zccache.sh" state "${job}" | grep -q '"state":"direct"' || fail "rustc ${version}: state is not direct"
  rc=0
  out=$(PATH="${work}/bin:${PATH}" AAP_ZC_STATE="${job}/state/config.json" "${inst}/zcshim" rustc --crate-type lib x.rs 2>&1) || rc=$?
  [[ "${rc}" == 3 && "${out}" == "fake rustc ran: --crate-type lib x.rs" ]] || fail "rustc ${version}: the shim did not run the compiler as it is (exit ${rc}): ${out}"
  [[ ! -e "${inst}/zccache-was-called" ]] || fail "rustc ${version}: zccache was called"
  grep -q 'direct rustc state-direct' "${job}/shim/shim.log" || fail "rustc ${version}: the shim did not log that it ran uncached: $(cat "${job}/shim/shim.log" 2>&1)"
done
echo "unqualified compiler version runs uncached ok"

echo "distro zccache tests ok"
