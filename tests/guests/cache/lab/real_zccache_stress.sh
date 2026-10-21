#!/usr/bin/env bash
# Lab test (P22, gate D2), not part of the suite: the real shim from this checkout with the real pinned zccache archive
# and the distro's gcc, through the real install and init. Each iteration compiles a fresh source (a cold key) with
# CALLS concurrent shim calls on the one private root, each to its own -o with a STALE object already there (and with
# DEP=1 also -MD over a STALE depfile), then requires every object to equal a direct compile and every depfile to be
# fresh. It answers: does
# zccache ever exit 0 without delivering an output (the shim's delivery check would fall back and say so), and do
# concurrent hits and misses on one entry ever hand out a bad object?
#   bash real_zccache_stress.sh ARCHIVE ITERATIONS [CALLS] [STAGGER_MS] [LOAD] [TEAR] [DEP]
# ARCHIVE: zccache-v1.15.6-x86_64-unknown-linux-musl.tar.gz, checked against guests/cache/wrappers.json by install.
# STAGGER_MS: call k starts (k-1)*STAGGER_MS after the first, so later calls hit while earlier ones still store.
# LOAD=1: everything pinned to CPUs 0-3 with four busy loops on them.
# TEAR=1 (sensitivity): after init the installed zccache becomes a wrapper that runs the real one and then cuts 1 in 8
#   delivered objects to 64 bytes while still exiting 0; the comparison must report failures.
# DEP=1: every call also writes a depfile (-MD). zccache keys such a call on its output name, so there are no hits
#   between calls then: run it apart from the runs that race hits against misses.
# Prints one line per bad iteration, then the totals; exits 0 only when no iteration failed and no call fell back.
# Leaves nothing behind: the run folder, its daemon and the busy loops go on exit.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "${HERE}/../../../.." && pwd)
ARCHIVE=$(readlink -f -- "$1") ITER=$2 CALLS=${3:-8} STAGGER=${4:-0} LOAD=${5:-0} TEAR=${6:-0} DEP=${7:-0}
SCRIPT="${REPO}/guests/cache/linux/aap-zccache.sh"
# shellcheck source=../../../../guests/cache/linux/aap-zccache.sh
source "${SCRIPT}"
W=$(mktemp -d "${HOME}/zc-lab.XXXXXX") || exit 1
export TMPDIR="${W}/tmp"
mkdir -p "${TMPDIR}" "${W}/src" "${W}/out"
BUSY=()
finish() {
  local p f exe
  [[ ${#BUSY[@]} -gt 0 ]] && { kill -KILL "${BUSY[@]}"; wait "${BUSY[@]}"; } 2> /dev/null  # wait: no "Killed" notices
  p=$(jq -r '.roots.private.daemon.pid // empty' "${W}/job/state/config.json" 2> /dev/null)
  [[ -n "${p}" ]] && zc_kill_tree "${p}"
  for f in /proc/[0-9]*/exe; do  # anything still running from this run's folder
    exe=$(readlink -f -- "${f}" 2> /dev/null) || continue
    [[ "${exe}" == "${W}/"* ]] && { f=${f#/proc/}; kill -KILL "${f%%/*}" 2> /dev/null; echo "stopped leftover ${exe}"; }
  done
  rm -rf -- "${W}"
  [[ -e "${W}" ]] && echo "LEFT ${W}"
}
trap finish EXIT
PIN=()
if [[ ${LOAD} == 1 ]]; then
  for _ in 1 2 3 4; do taskset -c 0-3 bash -c 'while :; do :; done' & BUSY+=($!); done
  PIN=(taskset -c 0-3)
fi

# The pin's matrix qualifies nothing yet; this run qualifies the distro's gcc for compile-object and depfile.
ver=$(gcc -dumpfullversion)
jq --arg v "${ver}" '.platforms["linux-x86_64"].qualified = [
    {compiler: "gcc", compiler_version: $v, invocation: "compile-object", evidence_ref: "lab-only"},
    {compiler: "gcc", compiler_version: $v, invocation: "depfile", evidence_ref: "lab-only"}]' \
  "${REPO}/guests/cache/wrappers.json" > "${W}/wrappers.json"
jq -n --arg s "$(zc_sha "${ARCHIVE}")" --arg f "${ARCHIVE##*/}" '{schema: "aap-provenance/1", name: "zccache-x86_64-unknown-linux-musl",
  version: "1.15.6", file_name: $f, outcome: "accepted", staging_check: "strict", sha256: $s, hash: {verified: true}}' > "${W}/prov.json"
jq -n --arg v "${ver}" '{toolchains: [{compiler: "gcc", compiler_version: $v, path: "/usr/bin/gcc"}]}' > "${W}/tc.json"
bash "${SCRIPT}" install "${ARCHIVE}" "${W}/prov.json" "${W}/install" "${W}/tc.json" "${W}/wrappers.json" > /dev/null || { echo "install failed"; exit 1; }
"${PIN[@]}" bash "${SCRIPT}" init "${W}/install" "${W}/job" 4294967296 > /dev/null || { echo "init failed"; exit 1; }
CFG="${W}/job/state/config.json"
echo "init: $(jq -c '{state, detail, daemon: .roots.private.daemon}' "${CFG}")"
[[ "$(jq -r .state "${CFG}")" == qualified ]] || exit 1
if [[ ${TEAR} == 1 ]]; then
  mv -- "${W}/install/bin/zccache" "${W}/install/bin/zccache.real"
  printf '%s\n' '#!/usr/bin/env bash' '"${0}.real" "$@"; rc=$?; o=""' \
    'while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && o=$2; shift; done' \
    '[[ ${rc} == 0 && -n "${o}" && $((RANDOM % 8)) == 0 ]] && truncate -s 64 -- "${o}"' 'exit ${rc}' > "${W}/install/bin/zccache"
  chmod 0755 "${W}/install/bin/zccache"
fi

gen() { # FILE SEED: about 300 functions, so an object is tens of KB and a copy is not instant
  local f
  { echo "/* ${2} */"
    for ((f = 0; f < 300; f++)); do
      echo "int f${f}(int x) { volatile int a[64]; for (int i = 0; i < 64; i++) a[i] = x * ${f} + i + ${2}; return a[x & 63] ^ ${f}; }"
    done; } > "$1"
}
fails=0 started=${SECONDS}
for ((i = 1; i <= ITER; i++)); do
  gen "${W}/src/s${i}.c" "${i}"
  pids=()
  for ((k = 1; k <= CALLS; k++)); do
    printf 'STALE\n' > "${W}/out/c${i}-${k}.o"; printf 'STALE\n' > "${W}/out/c${i}-${k}.d"
    md=(); [[ ${DEP} == 1 ]] && md=(-MD)
    ( sleep "$(printf '%d.%03d' $(((k - 1) * STAGGER / 1000)) $(((k - 1) * STAGGER % 1000)))"
      AAP_ZC_STATE="${CFG}" "${PIN[@]}" "${W}/install/zcshim" gcc -O2 -c "${W}/src/s${i}.c" "${md[@]}" -o "${W}/out/c${i}-${k}.o"
      echo $? > "${W}/out/c${i}-${k}.rc" ) &
    pids+=($!)
  done
  wait "${pids[@]}"
  gcc -O2 -c "${W}/src/s${i}.c" -o "${W}/out/d${i}.o"
  bad=""
  for ((k = 1; k <= CALLS; k++)); do
    o="${W}/out/c${i}-${k}.o"
    if [[ "$(cat -- "${W}/out/c${i}-${k}.rc")" != 0 ]]; then bad+=" c${k}:exit-$(cat -- "${W}/out/c${i}-${k}.rc")"
    elif [[ ! -f "${o}" ]]; then bad+=" c${k}:missing"
    elif ! cmp -s -- "${o}" "${W}/out/d${i}.o"; then bad+=" c${k}:$(wc -c < "${o}")-of-$(wc -c < "${W}/out/d${i}.o")-bytes"
    elif [[ ${DEP} == 1 ]] && { grep -q STALE -- "${W}/out/c${i}-${k}.d" || [[ ! -s "${W}/out/c${i}-${k}.d" ]]; }; then bad+=" c${k}:depfile"
    fi
  done
  [[ -n "${bad}" ]] && { fails=$((fails + 1)); echo "iteration ${i}:${bad}"; }
  rm -f -- "${W}/out/c${i}-"* "${W}/out/d${i}.o" "${W}/src/s${i}.c"
done
log="${W}/job/shim/shim.log"
through=$(grep -c ' zccache gcc exit 0$' "${log}") fallback=$(grep -c ' fallback ' "${log}") delivery=$(grep -c ' delivery ' "${log}")
echo "iterations ${ITER}, calls ${CALLS} each, failed iterations ${fails}, $((SECONDS - started))s"
echo "shim: ${through} through zccache, ${fallback} fallback (${delivery} delivery), $(grep -c ' direct ' "${log}") direct; degraded: $(cat -- "${W}/job/shim/degraded-private" 2> /dev/null || echo no)"
ZCCACHE_CACHE_DIR="${W}/job/roots/private" "${W}/install/bin/zccache$([[ ${TEAR} == 1 ]] && echo .real)" status 2>&1 | grep -iE 'compilations' | head -1
[[ ${fails} == 0 && ${fallback} == 0 ]]
