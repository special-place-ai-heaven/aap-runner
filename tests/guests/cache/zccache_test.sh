#!/usr/bin/env bash
# P13 zccache guest integration, Linux side: packaging, the per-job root, shim decisions with real processes against a
# fake zccache, shared-root binding, state, invocation classes and the toolchain digest. No network, no real zccache,
# no compiler: the doubles are in fakes/. Needs bash 4+, coreutils, tar and jq. Hosted ubuntu-latest is the reference;
# Git Bash on Windows runs it too (cases needing symbolic links are skipped there).
#   bash tests/guests/cache/zccache_test.sh
# AAP_ZC_SRC points at another copy of guests/cache; AAP_ZC_TAGS runs only the cases tagged with one of the given
# SAFETY ids (both used by mutate.py).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "${HERE}/../../.." && pwd)
SRC=${AAP_ZC_SRC:-${REPO}/guests/cache}
SCRIPT="${SRC}/linux/aap-zccache.sh"
FAKES="${HERE}/fakes"
MSYS=0
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    MSYS=1
    # A native Windows jq needs Windows paths for its file operands (never for --arg values, which are data) and
    # writes CRLF unless told otherwise.
    jq() {
      local a=() skip=0 x
      for x in "$@"; do
        if ((skip > 0)); then a+=("${x}"); skip=$((skip - 1)); continue; fi
        case "${x}" in --arg | --argjson) a+=("${x}"); skip=2; continue ;; --slurpfile | --rawfile) a+=("${x}"); skip=1; continue ;; esac
        if [[ "${x}" == /* && -e "${x}" ]]; then a+=("$(cygpath -m "${x}")"); else a+=("${x}"); fi
      done
      MSYS_NO_PATHCONV=1 command jq -b "${a[@]}"
    }
    export -f jq ;;
esac
# shellcheck source=../../../guests/cache/linux/aap-zccache.sh
source "${SCRIPT}"
fails=0 passes=0
ok() { passes=$((passes + 1)); echo "ok   $1"; }
no() { fails=$((fails + 1)); echo "FAIL $1"; }
check() { local name=$1; shift; if "$@"; then ok "${name}"; else no "${name}"; fi; }
# Everything this run writes, its children's temp files included, lives under one run root.
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/p13-bash.XXXXXX") || exit 1
export TMPDIR=${TMPROOT}
run_pids() { # the processes started from TMPROOT: the fakes run from a package tree's install/bin
  local n f
  n=$(basename "${TMPROOT}")
  if [[ ${MSYS} == 1 ]]; then
    ps -e | awk -v n="${n}" 'index($0, n) { print ($1 ~ /^[0-9]+$/) ? $1 : $2 }'
  else
    for f in /proc/[0-9]*/cmdline; do
      [[ "$(tr '\0' ' ' < "${f}" 2> /dev/null)" == *"${n}"* ]] && f=${f#/proc/} && echo "${f%%/*}"
    done
  fi
}
cleanup() { # stops every process started from TMPROOT and removes it; fails when either survives
  local f p left
  while IFS= read -r f; do kill "$(cat "${f}")" 2> /dev/null; done < <(find "${TMPROOT}" -name 'fake-*.pid' 2> /dev/null)
  for _ in $(seq 50); do
    left=$(run_pids)
    [[ -z "${left}" ]] && break
    while IFS= read -r p; do kill -9 "${p}" 2> /dev/null; done <<< "${left}"
    sleep 0.2
  done
  rm -rf -- "${TMPROOT}"
  [[ -z "$(run_pids)" && ! -e "${TMPROOT}" ]]
}
trap cleanup EXIT
# Strip the secrets of whatever CI shell runs this suite; the cases add synthetic ones on purpose.
for n in $(compgen -e); do grep -Eiq -- "${ZC_SECRET_NAME_RE}" <<< "${n}" && unset "${n}"; done
unset AAP_ZC_STATE

run() { # FUNCTION TAG...: runs it unless AAP_ZC_TAGS is set and names none of the tags
  local f=$1 t hit=0
  shift
  if [[ -n "${AAP_ZC_TAGS:-}" ]]; then
    for t in "$@"; do [[ " ${AAP_ZC_TAGS} " == *" ${t} "* ]] && hit=1; done
    [[ ${hit} == 1 ]] || return 0
  fi
  "${f}"
}

QUALIFIED='[{"compiler":"clang","compiler_version":"18.1.3","invocation":"compile-object","evidence_ref":"parity/cache/qualification/evidence/x.json"},
            {"compiler":"clang","compiler_version":"18.1.3","invocation":"depfile","evidence_ref":"parity/cache/qualification/evidence/y.json"}]'

new_pkg() { # [QUALIFIED_JSON] [EXTRA_STAGE_SETUP_FUNCTION] -> P, the package tree
  local q=${1:-${QUALIFIED}} extra=${2:-} members='[]' n f
  P=$(mktemp -d "${TMPROOT}/pkg.XXXXXX")
  mkdir -p "${P}/stage/zccache-test" "${P}/tc" "${P}/src"
  cp -- "${FAKES}/fake-zccache" "${P}/stage/zccache-test/zccache"
  printf 'fingerprint helper\n' > "${P}/stage/zccache-test/zccache-fp"
  chmod 0755 "${P}/stage/zccache-test/zccache"
  [[ -n "${extra}" ]] && "${extra}" "${P}/stage"
  tar -czf "${P}/test.tar.gz" -C "${P}/stage" zccache-test
  for n in zccache zccache-fp; do
    f="${P}/stage/zccache-test/${n}"
    members=$(jq -c --arg n "${n}" --argjson b "$(zc_size "${f}")" --arg s "$(zc_sha "${f}")" \
      '. + [{name: $n, path: ("zccache-test/" + $n), bytes: $b, sha256: $s}]' <<< "${members}")
  done
  jq -n --argjson m "${members}" --argjson q "${q}" --arg s "$(zc_sha "${P}/test.tar.gz")" --argjson b "$(zc_size "${P}/test.tar.gz")" \
    '{schema: 1, zccache: {version: "1.15.6", commit: "15ec9537af0d219e07b72ce2b3f97d5f68d72b5e"},
      platforms: {"linux-x86_64": {acquisition_entry: "zccache-test", archive: "test.tar.gz", archive_sha256: $s, archive_bytes: $b,
                                   members: $m, qualified: $q}}}' > "${P}/wrappers.json"
  jq -n --arg s "$(zc_sha "${P}/test.tar.gz")" '{schema: "aap-provenance/1", name: "zccache-test", version: "1.15.6", file_name: "test.tar.gz",
    outcome: "accepted", staging_check: "strict", sha256: $s, hash: {verified: true}}' > "${P}/test.tar.gz.provenance.json"
  cp -- "${FAKES}/fake-cc" "${P}/tc/fake-cc"
  chmod 0755 "${P}/tc/fake-cc"
  jq -n --arg p "${P}/tc/fake-cc" '{toolchains: [{compiler: "clang", compiler_version: "18.1.3", path: $p}]}' > "${P}/toolchains.json"
  printf 'int a;\n' > "${P}/src/a.c"
  printf '#error deliberate\n' > "${P}/src/bad.c"
  CFG="${P}/job/state/config.json"
}
install_pkg() {
  bash "${SCRIPT}" install "${P}/test.tar.gz" "${P}/test.tar.gz.provenance.json" "${P}/install" "${P}/toolchains.json" "${P}/wrappers.json" &&
    cp -- "$(command -v sleep)" "${P}/install/bin/zccache-daemon"
}
init_pkg() { install_pkg > /dev/null 2>&1 && bash "${SCRIPT}" init "${P}/install" "${P}/job" "${1:-104857600}" "${@:2}" > /dev/null; }
shim() { AAP_ZC_STATE="${CFG}" "${P}/install/zcshim" "$@"; }
compile() { # SOURCE [EXTRA ARGS...] -> OUT, RC, ERR (environment: whatever the caller exported)
  local src=$1
  shift
  OUT=$(mktemp -u "${P}/out.XXXXXX").o
  ERR=$(shim "${P}/tc/fake-cc" -c "${P}/src/${src}" "$@" -o "${OUT}" 2>&1 > /dev/null)
  RC=$?
}
direct() { local o="${P}/direct.$$.o"; "${P}/tc/fake-cc" -c "${P}/src/a.c" -o "${o}" && cat -- "${o}"; }
journal() { local j="${P}/job/roots/${1:-private}/fake-journal.log"; if [[ -f "${j}" ]]; then wc -l < "${j}" | tr -d ' '; else echo 0; fi; }
flag() { cat -- "${P}/job/shim/degraded-${1:-private}" 2> /dev/null; }
same_as_direct() { [[ -f "$1" ]] && cmp -s -- "$1" <(direct); }
wait_for() { local i; for ((i = 0; i < 300; i++)); do [[ -e "$1" ]] && return 0; sleep 0.1; done; return 1; }

# ---- install ----
t_install_ok() {
  new_pkg
  install_pkg > /dev/null 2>&1
  check "install: pinned members installed" cmp -s "${P}/install/bin/zccache" "${FAKES}/fake-zccache"
  check "install: toolchain identity recorded" [ "$(jq -r '.toolchains[0].sha256' "${P}/install/toolchains.json")" == "$(zc_sha "${P}/tc/fake-cc")" ]
  check "install: receipt carries the toolchain digest" \
    [ "$(jq -r .toolchain_digest "${P}/install/install.json")" == "$(zc_digest "$(jq -c .toolchains "${P}/install/toolchains.json")")" ]
  check "install: zcshim installed" [ -x "${P}/install/zcshim" ]
}
t_install_tmp() {
  new_pkg
  mkdir "${P}/tmp"
  TMPDIR="${P}/tmp" bash "${SCRIPT}" install "${P}/test.tar.gz" "${P}/test.tar.gz.provenance.json" "${P}/install" "${P}/toolchains.json" "${P}/wrappers.json" > /dev/null 2> "${P}/err"
  check "install: leaves no temp folder behind" [ -z "$(ls -A "${P}/tmp")" ]
  check "install: and prints no unbound-variable error at exit" bash -c '! grep -q unbound "$1"' _ "${P}/err"
  printf 'x' >> "${P}/test.tar.gz"
  TMPDIR="${P}/tmp" bash "${SCRIPT}" install "${P}/test.tar.gz" "${P}/test.tar.gz.provenance.json" "${P}/install2" "${P}/toolchains.json" "${P}/wrappers.json" > /dev/null 2>&1
  check "install: nor after a refusal" [ -z "$(ls -A "${P}/tmp")" ]
}
t_install_archive() {
  new_pkg
  printf 'x' >> "${P}/test.tar.gz"
  bash "${SCRIPT}" install "${P}/test.tar.gz" "${P}/test.tar.gz.provenance.json" "${P}/install" "${P}/toolchains.json" "${P}/wrappers.json" 2> "${P}/err"
  check "install: refuses an archive that is not the pinned one" grep -q "not the pinned release archive" "${P}/err"
  check "install: installs nothing then" [ ! -e "${P}/install" ]
}
t_install_provenance() {
  local f v
  for f in 'hash.verified=false' 'staging_check="relaxed"' 'outcome="rejected"' 'name="docker-engine-windows-static"' 'sha256="00"'; do
    new_pkg
    v=$(jq ".${f}" "${P}/test.tar.gz.provenance.json") && printf '%s' "${v}" > "${P}/test.tar.gz.provenance.json"
    bash "${SCRIPT}" install "${P}/test.tar.gz" "${P}/test.tar.gz.provenance.json" "${P}/install" "${P}/toolchains.json" "${P}/wrappers.json" 2> "${P}/err"
    check "install: refuses provenance with ${f}" grep -q "strict P03 run" "${P}/err"
  done
}
t_install_member() {
  new_pkg
  jq '.platforms["linux-x86_64"].members[1].sha256 = "00"' "${P}/wrappers.json" > "${P}/w2" && mv "${P}/w2" "${P}/wrappers.json"
  bash "${SCRIPT}" install "${P}/test.tar.gz" "${P}/test.tar.gz.provenance.json" "${P}/install" "${P}/toolchains.json" "${P}/wrappers.json" 2> "${P}/err"
  check "install: refuses a member whose bytes differ from its pin" grep -q "is not the pinned member" "${P}/err"
}
add_parent() { mkdir -p "$1/../x" && printf 'evil\n' > "$1/../x/evil" && tar -cf "$1/../evil.tar" -C "$1/.." --transform 's,^x/,zccache-test/../,' x/evil; }
add_hardlink() { ln -- "$1/zccache-test/zccache-fp" "$1/zccache-test/fp-link"; }
add_symlink() { ln -s zccache-fp "$1/zccache-test/fp-sym"; }
t_install_tar_members() {
  local err
  new_pkg "${QUALIFIED}" add_parent
  tar -cf "${P}/plain.tar" -C "${P}/stage" zccache-test && tar -Af "${P}/plain.tar" "${P}/evil.tar" && gzip -c "${P}/plain.tar" > "${P}/test.tar.gz"
  jq --arg s "$(zc_sha "${P}/test.tar.gz")" --argjson b "$(zc_size "${P}/test.tar.gz")" \
    '.platforms["linux-x86_64"].archive_sha256 = $s | .platforms["linux-x86_64"].archive_bytes = $b' "${P}/wrappers.json" > "${P}/w2" && mv "${P}/w2" "${P}/wrappers.json"
  jq --arg s "$(zc_sha "${P}/test.tar.gz")" '.sha256 = $s' "${P}/test.tar.gz.provenance.json" > "${P}/p2" && mv "${P}/p2" "${P}/test.tar.gz.provenance.json"
  err=$(bash "${SCRIPT}" install "${P}/test.tar.gz" "${P}/test.tar.gz.provenance.json" "${P}/install" "${P}/toolchains.json" "${P}/wrappers.json" 2>&1)
  check "install: refuses a parent-segment member" grep -q "refused member" <<< "${err}"
  new_pkg "${QUALIFIED}" add_hardlink
  err=$(bash "${SCRIPT}" install "${P}/test.tar.gz" "${P}/test.tar.gz.provenance.json" "${P}/install" "${P}/toolchains.json" "${P}/wrappers.json" 2>&1)
  check "install: refuses a hard-link member" grep -q "refused a link or special member" <<< "${err}"
  if [[ ${MSYS} == 0 ]]; then
    new_pkg "${QUALIFIED}" add_symlink
    err=$(bash "${SCRIPT}" install "${P}/test.tar.gz" "${P}/test.tar.gz.provenance.json" "${P}/install" "${P}/toolchains.json" "${P}/wrappers.json" 2>&1)
    check "install: refuses a symbolic-link member" grep -q "refused a link or special member" <<< "${err}"
  fi
}
t_install_dir_link() {
  [[ ${MSYS} == 1 ]] && return 0  # Git Bash makes copies, not links
  new_pkg
  mkdir "${P}/elsewhere" && ln -s "${P}/elsewhere" "${P}/install"
  bash "${SCRIPT}" install "${P}/test.tar.gz" "${P}/test.tar.gz.provenance.json" "${P}/install" "${P}/toolchains.json" "${P}/wrappers.json" 2> "${P}/err"
  check "install: refuses an install folder that is a symbolic link" grep -q "is a symbolic link" "${P}/err"
}

# ---- init ----
t_init_direct() {
  new_pkg '[]'
  init_pkg
  check "init: nothing qualified means direct" [ "$(jq -r .state "${CFG}")" == direct ]
  check "init: and an empty runner environment" [ ! -s "${P}/job/state/runner.env" ]
  check "init: and no daemon" [ ! -e "${P}/job/roots/private/fake-daemon.pid" ]
}
t_init_qualified() {
  new_pkg
  init_pkg 104857600
  check "init: qualified pairs turn on a private root" [ "$(jq -r .state "${CFG}")" == qualified ]
  check "init: artifact budget is 3/4 of the job budget" [ "$(jq -r .roots.private.artifact_budget_bytes "${CFG}")" == 78643200 ]
  check "init: the daemon recorded is the one zccache started" [ "$(jq -r .roots.private.daemon.pid "${CFG}")" == "$(cat "${P}/job/roots/private/fake-daemon.pid")" ]
  check "init: shared roots off, a 60 s wrapper bound and the zccache version by default" \
    jq -e '.shared_roots == false and .wrapper_timeout_seconds == 60 and .wrapper_timeout_long_seconds == 600 and .zccache_version == "1.15.6"' "${CFG}" > /dev/null
  check "init: runner env names the state and the CMake launchers" \
    grep -qx "CMAKE_C_COMPILER_LAUNCHER=${P}/install/zcshim" "${P}/job/state/runner.env"
  check "init: no RUSTC_WRAPPER without a qualified rustc pair, no ZCCACHE_* for jobs" \
    bash -c '! grep -Eq "RUSTC_WRAPPER|ZCCACHE_" "$1"' _ "${P}/job/state/runner.env"
  check "init: daemon started in COPY mode with the explicit budget" grep -q "MODE=COPY SIZE=78643200$" "${P}/job/roots/private/fake-env.log"
}
t_init_rustc() {
  new_pkg '[{"compiler":"rustc","compiler_version":"1.99.0","invocation":"rustc-wrapper","evidence_ref":"parity/cache/qualification/evidence/r.json"}]'
  jq --arg p "${P}/tc/fake-cc" '.toolchains = [{compiler: "rustc", compiler_version: "1.99.0", path: $p}]' "${P}/toolchains.json" > "${P}/t2" &&
    mv "${P}/t2" "${P}/toolchains.json"
  init_pkg
  check "init: a qualified rustc pair sets RUSTC_WRAPPER to the shim" grep -qx "RUSTC_WRAPPER=${P}/install/zcshim" "${P}/job/state/runner.env"
}
t_init_env() {
  new_pkg
  GH_TOKEN=synthetic-p13 HTTPS_PROXY=http://u:synthetic@proxy:3128 ZCCACHE_ENDPOINT=shared init_pkg
  check "init: the daemon gets no credentials or inherited ZCCACHE_* variables" \
    bash -c '! grep -Eq "(^| )(GH_TOKEN|HTTPS_PROXY|ZCCACHE_ENDPOINT) " "$1"' _ "${P}/job/roots/private/fake-env.log"
}
t_init_daemon_env() {
  new_pkg
  AAP_P13_CANARY=1 init_pkg
  check "init: the daemon starts under env -i with the allowlist only" bash -c '! grep -q "AAP_P13_CANARY" "$1"' _ "${P}/job/roots/private/fake-env.log"
  check "init: which keeps PATH" grep -q "PATH " "${P}/job/roots/private/fake-env.log"
}
t_init_args() {
  new_pkg
  install_pkg > /dev/null 2>&1
  check "init: refuses a budget written with a leading zero" bash -c '! bash "$1" init "$2" "$3" 00 > /dev/null 2>&1' _ "${SCRIPT}" "${P}/install" "${P}/job"
  check "init: refuses a wrapper bound of 0" bash -c '! bash "$1" init "$2" "$3" 1048576 --wrapper-timeout 0 > /dev/null 2>&1' _ "${SCRIPT}" "${P}/install" "${P}/job"
  check "init: refuses a long wrapper bound of 0" bash -c '! bash "$1" init "$2" "$3" 1048576 --wrapper-timeout-long 0 > /dev/null 2>&1' _ "${SCRIPT}" "${P}/install" "${P}/job"
  bash "${SCRIPT}" init "${P}/install" "${P}/job" 104857600 --shared-roots --wrapper-timeout 7 --wrapper-timeout-long 70 > /dev/null
  check "init: records --shared-roots and both wrapper bounds" \
    jq -e '.shared_roots == true and .wrapper_timeout_seconds == 7 and .wrapper_timeout_long_seconds == 70' "${CFG}" > /dev/null
}
t_init_boot_binary() {
  new_pkg
  install_pkg > /dev/null 2>&1
  printf '# changed\n' >> "${P}/install/bin/zccache-fp"
  bash "${SCRIPT}" init "${P}/install" "${P}/job" 104857600 > /dev/null
  check "init: disabled when the installed zccache is not pinned" [ "$(jq -r .state "${CFG}")" == disabled ]
}
t_init_boot_toolchain() {
  new_pkg
  install_pkg > /dev/null 2>&1
  printf '# changed\n' >> "${P}/tc/fake-cc"
  bash "${SCRIPT}" init "${P}/install" "${P}/job" 104857600 > /dev/null
  check "init: a toolchain changed after sealing is dropped" [ "$(jq -r '.toolchains | length' "${CFG}")" == 0 ]
  check "init: so nothing is qualified" [ "$(jq -r .state "${CFG}")" == direct ]
}
t_init_job_link() {
  [[ ${MSYS} == 1 ]] && return 0
  new_pkg
  install_pkg > /dev/null 2>&1
  mkdir "${P}/elsewhere" && ln -s "${P}/elsewhere" "${P}/job"
  bash "${SCRIPT}" init "${P}/install" "${P}/job" 104857600 > /dev/null 2> "${P}/err"
  check "init: refuses a job root that is a symbolic link" grep -q "is a symbolic link" "${P}/err"
}

# ---- shim ----
t_shim_cold_warm() {
  new_pkg
  init_pkg
  compile a.c; local o1=${OUT} r1=${RC}
  compile a.c
  check "shim: cold build equals direct" same_as_direct "${o1}"
  check "shim: warm build equals direct" same_as_direct "${OUT}"
  check "shim: both exit 0" [ "${r1}${RC}" == 00 ]
  check "shim: miss then hit" [ "$(paste -sd, "${P}/job/roots/private/fake-journal.log")" == miss,hit ]
  check "shim: no degraded flag" [ -z "$(flag)" ]
  compile bad.c
  check "shim: a compile error keeps the direct exit code" [ "${RC}" == 1 ]
  check "shim: and its message, once" [ "$(grep -c 'error: deliberate' <<< "${ERR}")" == 1 ]
  check "shim: and is not a wrapper failure" [ -z "$(flag)" ]
}
t_shim_direct_cases() {
  new_pkg
  init_pkg
  local before
  before=$(journal)
  compile a.c -g
  check "shim: an unqualified class (debug-pdb) builds directly" [ "${RC}" == 0 ] && check "shim: without zccache" [ "$(journal)" == "${before}" ]
  compile a.c -E
  check "shim: an unclassifiable call (-E) builds directly without zccache" [ "$(journal)" == "${before}" ]
  printf '%s\n' "-c ${P}/src/a.c" > "${P}/args.rsp"
  shim "${P}/tc/fake-cc" "@${P}/args.rsp" -o "${P}/rsp.o" > /dev/null 2>&1
  check "shim: a response file (not qualified here) builds directly" [ "$(journal)" == "${before}" ]
  check "shim: with the right output" same_as_direct "${P}/rsp.o"
  OUT="${P}/nostate.o"
  "${P}/install/zcshim" "${P}/tc/fake-cc" -c "${P}/src/a.c" -o "${OUT}" > /dev/null 2>&1
  check "shim: without AAP_ZC_STATE it builds directly" same_as_direct "${OUT}"
  check "shim: unknown compilers build directly" bash -c 'AAP_ZC_STATE="$1" "$2" true' _ "${CFG}" "${P}/install/zcshim"
}
t_shim_env() {
  new_pkg
  init_pkg
  ACTIONS_RUNTIME_TOKEN=synthetic DATABASE_URL=postgres://a:synthetic@db/x ZCCACHE_MODE=LINK ZCCACHE_ENDPOINT=x ZCCACHE_PATH_REMAP=auto compile a.c
  check "shim: zccache gets no credentials or foreign ZCCACHE_* variables" \
    bash -c '! tail -n 1 "$1" | grep -Eq "(^| )(ACTIONS_RUNTIME_TOKEN|DATABASE_URL|ZCCACHE_ENDPOINT|ZCCACHE_PATH_REMAP) "' _ "${P}/job/roots/private/fake-env.log"
  check "shim: and always COPY mode" bash -c 'tail -n 1 "$1" | grep -q "MODE=COPY "' _ "${P}/job/roots/private/fake-env.log"
  check "shim: with the explicit artifact budget" bash -c 'tail -n 1 "$1" | grep -q "SIZE=78643200$"' _ "${P}/job/roots/private/fake-env.log"
  AAP_ZC_STATE="${CFG}" env 'ODD-TOKEN=synthetic' 'npm_config_//registry.example/:_authToken=synthetic' 'ODD-NAME=keep' \
    "${P}/install/zcshim" "${P}/tc/fake-cc" -c "${P}/src/a.c" -o "${P}/odd.o" > /dev/null 2>&1
  check "shim: drops secret-shaped names bash cannot hold as variables" \
    bash -c '! tail -n 1 "$1" | grep -Eq "(^| )(ODD-TOKEN|npm_config_//registry.example/:_authToken) "' _ "${P}/job/roots/private/fake-env.log"
  check "shim: and keeps the harmless ones" bash -c 'tail -n 1 "$1" | grep -q " ODD-NAME "' _ "${P}/job/roots/private/fake-env.log"
}
t_shim_hardlink() {
  new_pkg
  init_pkg
  compile a.c; compile a.c
  printf 'APPENDED BY A BUILD STEP\n' >> "${OUT}"
  compile a.c
  check "shim: writing into a delivered output does not poison the next hit" same_as_direct "${OUT}"
}
t_shim_concurrent() {
  new_pkg
  init_pkg
  local i pids=() good=1
  for i in 1 2 3 4 5 6 7 8; do
    shim "${P}/tc/fake-cc" -c "${P}/src/a.c" -o "${P}/conc-${i}.o" > /dev/null 2>&1 &
    pids+=($!)
  done
  for i in "${pids[@]}"; do wait "${i}" || good=0; done
  check "shim: 8 concurrent calls on one root all exit 0" [ ${good} == 1 ]
  for i in 1 2 3 4 5 6 7 8; do same_as_direct "${P}/conc-${i}.o" || good=0; done
  check "shim: and all equal direct" [ ${good} == 1 ]
  check "shim: whole log lines" bash -c '! grep -Evq "^[0-9T:-]+Z (zccache|direct|fallback) " "$1"' _ "${P}/job/shim/shim.log"
}
t_shim_daemon_down() {
  new_pkg
  init_pkg
  kill "$(jq -r .roots.private.daemon.pid "${CFG}")"
  sleep 0.3
  compile a.c
  check "shim: daemon down builds directly" same_as_direct "${OUT}"
  check "shim: without calling zccache" [ "$(journal)" == 0 ]
  check "shim: and reports degraded" [ "$(flag)" == daemon-down ]
  check "state: degraded" [ "$(zc_state "${P}/job" | jq -r .state)" == degraded ]
  new_pkg
  init_pkg
  jq '.roots.private.daemon.start = "1"' "${CFG}" > "${P}/c2" && mv "${P}/c2" "${CFG}"
  compile a.c
  check "shim: a recycled pid with another start time is down" [ "$(flag)" == daemon-down ]
}
t_shim_crash() {
  new_pkg
  init_pkg
  FAKE_ZC_CRASH=1 compile a.c
  check "shim: zccache crashing still yields the direct result" same_as_direct "${OUT}"
  check "shim: and marks the root degraded" [ "$(flag)" == wrapper-failure ]
  compile a.c
  check "shim: a degraded root is not used again" [ "$(journal)" == 0 ]
  new_pkg
  init_pkg
  FAKE_ZC_VERIFY=1 compile a.c
  local store
  store=$(find "${P}/job/roots/private/artifacts" -type f ! -name '*.sha' | head -n 1)
  printf 'POISONED' > "${store}"
  FAKE_ZC_VERIFY=1 compile a.c
  check "shim: a corrupted entry zccache rejects is rebuilt directly" same_as_direct "${OUT}"
  check "shim: as a wrapper failure" [ "$(flag)" == wrapper-failure ]
}
t_shim_toolchain_changed() {
  new_pkg
  init_pkg
  touch -d '2001-01-01' "${P}/tc/fake-cc"
  compile a.c
  check "shim: a toolchain changed after boot builds directly" [ "$(journal)" == 0 ]
}
t_shim_over_budget() {
  new_pkg
  init_pkg
  local dir before
  dir=$(jq -r .roots.private.dir "${CFG}")
  mkdir -p "${dir}/logs" && head -c 27262976 /dev/zero > "${dir}/logs/big.log"
  before=$(find "${dir}" -type f | sort)
  compile a.c
  check "shim: over budget builds directly" same_as_direct "${OUT}"
  check "shim: stops using the root" [ "$(flag)" == over-budget ]
  check "shim: and deletes nothing from it" [ "$(find "${dir}" -type f | sort)" == "${before}" ]
}
t_shim_over_budget_total() {
  new_pkg
  init_pkg 4194304
  local dir
  dir=$(jq -r .roots.private.dir "${CFG}")
  mkdir -p "${dir}/artifacts" && head -c 5242880 /dev/zero > "${dir}/artifacts/big"
  compile a.c
  check "shim: artifacts past the whole budget stop the root too" [ "$(flag)" == over-budget ]
  check "shim: without calling zccache" [ "$(journal)" == 0 ]
}
t_shim_timeout() {
  new_pkg
  init_pkg 104857600 --wrapper-timeout 2
  local t0=${SECONDS} daemon
  daemon=$(jq -r .roots.private.daemon.pid "${CFG}")
  # The hung client leaves a child that writes the output 8 s in, after the direct compile.
  FAKE_ZC_HANG=30 FAKE_ZC_LATE=8 compile a.c
  local took=$((SECONDS - t0))
  [[ -f "${P}/job/roots/private/fake-client.pid" ]] && kill "$(cat "${P}/job/roots/private/fake-client.pid")" 2> /dev/null
  check "shim: a hung zccache call is killed at the bound" [ "${took}" -lt 15 ]
  while ((SECONDS - t0 < 14)); do sleep 1; done
  check "shim: and the compiler runs directly, nothing the call started writes the output late" same_as_direct "${OUT}"
  check "shim: and the root's daemon, which may still compile that output, is stopped" bash -c '! kill -0 "$1" 2> /dev/null' _ "${daemon}"
  check "shim: with its exit code" [ "${RC}" == 0 ]
  check "shim: and the root is marked degraded" [ "$(flag)" == wrapper-timeout ]
}
t_timeout_class() {
  check "shim: an object compile gets the short bound" [ "$(zc_wrapper_timeout "compile-object depfile" 60 600)" == 60 ]
  check "shim: rustc gets the long bound" [ "$(zc_wrapper_timeout "rustc-wrapper" 60 600)" == 600 ]
  check "shim: a link gets the long bound" [ "$(zc_wrapper_timeout "debug-pdb link" 60 600)" == 600 ]
  check "shim: a precompiled header gets the long bound" [ "$(zc_wrapper_timeout "compile-pch" 60 600)" == 600 ]
}
t_shim_usage_unwritable() {
  new_pkg
  init_pkg
  mkdir "${P}/job/shim/usage-private"
  compile a.c
  check "shim: a usage stamp it cannot write builds directly" same_as_direct "${OUT}"
  check "shim: says nothing on the compile's stderr" [ -z "${ERR}" ]
  check "shim: and records degraded" [ "$(flag)" == usage-unwritable ]
}
t_shim_flag() {
  new_pkg
  init_pkg
  printf 'daemon-down' > "${P}/job/shim/degraded-private"
  compile a.c
  check "shim: a root marked degraded is not used" [ "$(journal)" == 0 ]
}
t_shim_log() {
  new_pkg
  init_pkg
  head -c 1048586 /dev/zero > "${P}/job/shim/shim.log"
  compile a.c
  check "shim: the log rotates past 1 MiB" [ "$(zc_size "${P}/job/shim/shim.log")" -lt 4096 ]
  check "shim: keeping one old generation" [ "$(zc_size "${P}/job/shim/shim.log.1")" == 1048586 ]
}

# ---- attach ----
binding() { # CLASS [RUNNER] [DIGEST] [VERSION] -> JSON
  jq -cn --arg c "$1" --arg r "${2:-aap-l-1-7-0011aabb}" --arg d "${3:-$(jq -r .toolchain_digest "${CFG}")}" --arg v "${4:-1.15.6}" \
    '{schema: 1, runner_name: $r, root_id: "ns-00112233aabbccdd", budget_bytes: 52428800,
      namespace: {repository_id: 4242, repository: "org/repo", trust_class: $c, platform: "linux-x86_64", toolchain_digest: $d, zccache_version: $v}}'
}
mount_for() { # BINDING_JSON [MARKER_NAMESPACE_OVERRIDE_JSON] -> mount dir
  local m o
  m=$(mktemp -d "${P}/mount.XXXXXX")
  o=${2:-}
  [[ -n "${o}" ]] || o='{}'
  jq -c --argjson o "${o}" '{schema: 1, root_id: .root_id, namespace: (.namespace + $o)}' <<< "$1" > "${m}/aap-cache-root.json"
  echo "${m}"
}
attach() { # BINDING_JSON_OR_EMPTY MOUNT [RUNNER] -> reply JSON
  local b="${P}/binding.$$.${RANDOM}.json"
  [[ -n "$1" ]] && printf '%s' "$1" > "${b}"
  bash "${SCRIPT}" attach "${P}/install" "${P}/job" "${b}" "$2" "${3:-aap-l-1-7-0011aabb}"
}
reason() { jq -r .reason <<< "$1"; }
t_attach_ok() {
  new_pkg
  init_pkg 104857600 --shared-roots
  local b m r
  b=$(binding trusted); m=$(mount_for "${b}")
  r=$(attach "${b}" "${m}")
  check "attach: a trusted root with a matching marker attaches" [ "$(jq -r .attached <<< "${r}")" == true ]
  check "attach: wrapped calls move to it" [ "$(jq -r .active_root "${CFG}")" == shared ]
  check "attach: the daemon recorded is the shared root's own" [ "$(jq -r .roots.shared.daemon.pid "${CFG}")" == "$(cat "${m}/root/fake-daemon.pid")" ]
  compile a.c
  check "attach: the compile lands in the shared root" [ "$(wc -l < "${m}/root/fake-journal.log" | tr -d ' ')" == 1 ]
  check "attach: and not the private one" [ "$(journal)" == 0 ]
  b=$(jq -c '.root_id = "ns-0000000000000002"' <<< "${b}")
  r=$(attach "${b}" "$(mount_for "${b}")")
  check "attach: binds at most once" [ "$(reason "${r}")" == already-bound ]
}
t_attach_switch() {
  new_pkg
  init_pkg
  local b m
  b=$(binding trusted); m=$(mount_for "${b}")
  check "attach: nothing unless init turned shared roots on" [ "$(reason "$(attach "${b}" "${m}")")" == shared-roots-off ]
  check "attach: and no daemon touched the root" [ ! -e "${m}/root" ]
}
t_attach_untrusted() {
  new_pkg
  init_pkg 104857600 --shared-roots
  local b m c
  for c in 'untrusted {}' 'untrusted {"trust_class":"trusted"}' 'maybe {}'; do
    b=$(binding "${c%% *}"); m=$(mount_for "${b}" "${c#* }")
    check "attach: an untrusted job never gets a shared root (${c})" [ "$(reason "$(attach "${b}" "${m}")")" == not-trusted ]
    compile a.c
    check "attach: nothing touched that root (${c})" [ ! -e "${m}/root" ]
  done
  check "attach: the job keeps its private root" [ "$(jq -r .active_root "${CFG}")" == private ]
}
t_attach_missing() {
  new_pkg
  init_pkg 104857600 --shared-roots
  local b m
  b=$(binding trusted); m=$(mount_for "${b}")
  check "attach: no binding file means no shared root" [ "$(reason "$(attach "" "${m}")")" == binding-missing ]
  check "attach: a binding that is not JSON" [ "$(reason "$(attach "{not json" "${m}")")" == binding-missing ]
  check "attach: no namespace" [ "$(reason "$(attach "$(jq -c 'del(.namespace)' <<< "${b}")" "${m}")")" == binding-missing ]
  check "attach: no trust class" [ "$(reason "$(AAP_CACHE_TRUST_CLASS=trusted attach "$(jq -c 'del(.namespace.trust_class)' <<< "${b}")" "${m}")")" == binding-missing ]
  check "attach: no zccache version" [ "$(reason "$(attach "$(jq -c 'del(.namespace.zccache_version)' <<< "${b}")" "${m}")")" == binding-missing ]
  check "attach: empty root id" [ "$(reason "$(attach "$(jq -c '.root_id = ""' <<< "${b}")" "${m}")")" == binding-missing ]
  check "attach: still private" [ "$(jq -r .active_root "${CFG}")" == private ]
}
t_attach_refusals() {
  new_pkg
  init_pkg 104857600 --shared-roots
  local b m o
  b=$(binding trusted aap-l-2-9-ffffffff)
  check "attach: a binding for another runner" [ "$(reason "$(attach "${b}" "$(mount_for "${b}")")")" == runner-mismatch ]
  b=$(binding trusted aap-l-1-7-0011aabb "$(printf 'a%.0s' {1..64})")
  check "attach: a root made for other toolchains" [ "$(reason "$(attach "${b}" "$(mount_for "${b}")")")" == toolchain-mismatch ]
  b=$(binding trusted aap-l-1-7-0011aabb "" 1.15.7)
  check "attach: a root made for another zccache version" [ "$(reason "$(attach "${b}" "$(mount_for "${b}")")")" == toolchain-mismatch ]
  b=$(binding trusted)
  m=$(mount_for "${b}")
  check "attach: a marker naming another root id" [ "$(reason "$(attach "$(jq -c '.root_id = "ns-ffffffffffffffff"' <<< "${b}")" "${m}")")" == marker-mismatch ]
  for o in '{"trust_class":"untrusted"}' '{"zccache_version":"1.0.0"}'; do
    check "attach: a marker naming ${o}" [ "$(reason "$(attach "${b}" "$(mount_for "${b}" "${o}")")")" == marker-mismatch ]
  done
  if [[ ${MSYS} == 0 ]]; then
    mkdir "${P}/other" && ln -s "${P}/other" "${m}/root"
    check "attach: a root that is a symbolic link" [ "$(reason "$(attach "${b}" "${m}")")" == root-is-link ]
  fi
  new_pkg '[]'
  init_pkg 104857600 --shared-roots
  b=$(binding trusted)
  check "attach: nothing qualified" [ "$(reason "$(attach "${b}" "$(mount_for "${b}")")")" == no-qualified-wrappers ]
}
t_attach_during_compile() {
  new_pkg
  init_pkg 104857600 --shared-roots
  local b m r bg client
  FAKE_ZC_HANG=60 compile a.c &
  bg=$!
  client="${P}/job/roots/private/fake-client.pid"
  check "attach: a wrapped compile is running" wait_for "${client}"
  b=$(binding trusted); m=$(mount_for "${b}")
  r=$(attach "${b}" "${m}")
  kill "$(cat "${client}")" 2> /dev/null
  wait "${bg}"
  check "attach: attaches while a wrapped compile runs" [ "$(jq -r .attached <<< "${r}")" == true ]
  check "attach: and never takes the compile client for the shared daemon" [ "$(jq -r .roots.shared.daemon.pid "${CFG}")" == "$(cat "${m}/root/fake-daemon.pid")" ]
}
t_attach_ambiguous() {
  new_pkg
  init_pkg 104857600 --shared-roots
  local b m stray
  b=$(binding trusted); m=$(mount_for "${b}")
  mkdir -p "${m}/root"
  ZCCACHE_CACHE_DIR="${m}/root" "${P}/install/bin/zccache-daemon" 600 < /dev/null > /dev/null 2>&1 &
  stray=$!
  check "attach: an ambiguous daemon attaches nothing" [ "$(reason "$(attach "${b}" "${m}")")" == daemon-start-failed ]
  sleep 0.3
  check "attach: and stops every candidate" bash -c '! kill -0 "$1" 2> /dev/null && ! kill -0 "$2" 2> /dev/null' _ "${stray}" "$(cat "${m}/root/fake-daemon.pid")"
  check "attach: the job keeps its private root" jq -e '.active_root == "private" and (.roots | has("shared") | not)' "${CFG}" > /dev/null
  check "attach: no temp file left in state" [ -z "$(find "${P}/job/state" -name '*.tmp')" ]
}

# ---- state, classes, digest ----
t_state() {
  check "state: unknown before init" [ "$(zc_state "${TMPROOT}/nothing" | jq -r .state)" == unknown ]
  new_pkg '[]'
  init_pkg
  check "state: direct, printable detail, byte counts" \
    jq -e '.state == "direct" and (.detail | test("^[ -~]{1,200}$")) and .bytes.private.budget == 104857600' <<< "$(zc_state "${P}/job")" > /dev/null
  printf '{"a":1}' > "${P}/w.json"
  check "zc_write: refuses empty content and keeps the file" bash -c 'source "$1"; ! printf "" | zc_write "$2" && [ "$(cat "$2")" == "{\"a\":1}" ]' _ "${SCRIPT}" "${P}/w.json"
}
t_classify() {
  local v compiler want got args=() a rsp
  rsp="${TMPROOT}/args.rsp"
  while IFS= read -r v; do
    compiler=$(jq -r .compiler <<< "${v}")
    want=$(jq -r 'if .classes == null then "NULL" else .classes | sort | join(",") end' <<< "${v}")
    args=()
    while IFS= read -r a; do
      case "${a}" in
        @RSP) jq -j .rsp <<< "${v}" > "${rsp}"; args+=("@${rsp}") ;;
        @MISSING) args+=("@${TMPROOT}/missing.rsp") ;;
        *) args+=("${a}") ;;
      esac
    done < <(jq -r '.args[]' <<< "${v}")
    if got=$(zc_classify "${compiler}" "${args[@]}"); then got=$(paste -sd, <<< "${got}"); else got=NULL; fi
    check "classify: ${compiler} $(jq -r '.args | join(" ")' <<< "${v}") -> ${want}" [ "${got}" == "${want}" ]
  done < <(jq -c '.vectors[] | select(.platforms | index("linux"))' "${HERE}/fixtures/classify.json")
}
t_digest() {
  check "digest: the cross-platform vector" [ "$(zc_digest '[{"compiler":"clang","compiler_version":"18.1.3","sha256":"ab"},{"compiler":"cl","compiler_version":"1","sha256":"cd"}]')" == \
    c1c5e12c68673106853368b917e2fdb713e57cc23687647c6104b1aebf3bf11c ]
  check "digest: of no toolchains" [ "$(zc_digest '[]')" == e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]
}

run t_install_ok
run t_install_tmp
run t_install_archive LNX-ARCHIVE-HASH
run t_install_provenance LNX-PROVENANCE
run t_install_member LNX-MEMBER-HASH
run t_install_tar_members LNX-TAR-MEMBER LNX-TAR-TYPE
run t_install_dir_link LNX-DIR-LINK
run t_init_direct
run t_init_qualified LNX-COPY-MODE LNX-BUDGET-SET
run t_init_rustc
run t_init_env LNX-ENV-SECRET LNX-ENV-ZCCACHE
run t_init_daemon_env LNX-DAEMON-ENV
run t_init_args
run t_init_boot_binary LNX-BOOT-BINARY
run t_init_boot_toolchain LNX-BOOT-TOOLCHAIN
run t_init_job_link LNX-DIR-LINK
run t_shim_cold_warm LNX-SHIM-QUALIFIED LNX-SHIM-DAEMON
run t_shim_direct_cases LNX-SHIM-QUALIFIED
run t_shim_env LNX-ENV-SECRET LNX-ENV-ZCCACHE LNX-COPY-MODE LNX-BUDGET-SET
run t_shim_hardlink LNX-COPY-MODE
run t_shim_concurrent
run t_shim_daemon_down LNX-SHIM-DAEMON LNX-DAEMON-ALIVE
run t_shim_crash LNX-SHIM-FALLBACK
run t_shim_toolchain_changed LNX-SHIM-TOOLCHAIN
run t_shim_over_budget LNX-OVER-BUDGET
run t_shim_over_budget_total LNX-OVER-BUDGET
run t_shim_timeout LNX-SHIM-TIMEOUT LNX-TIMEOUT-DAEMON
run t_timeout_class LNX-TIMEOUT-CLASS
run t_shim_usage_unwritable
run t_shim_flag LNX-SHIM-FLAG
run t_shim_log LNX-LOG-BOUND
run t_attach_ok LNX-BIND-ONCE
run t_attach_switch LNX-BIND-SWITCH
run t_attach_untrusted LNX-BIND-CLASS
run t_attach_missing LNX-BIND-MISSING
run t_attach_refusals LNX-BIND-RUNNER LNX-BIND-TOOLCHAIN LNX-BIND-MARKER LNX-BIND-LINK
run t_attach_during_compile LNX-DAEMON-ID
run t_attach_ambiguous
run t_state
run t_classify
run t_digest

trap - EXIT
# The suite's own hygiene check: hosted runners are thrown away, a developer's machine is not.
check "suite: no folder or process of this run is left behind" cleanup
echo "passed ${passes}, failed ${fails}"
[[ ${fails} -eq 0 ]]
