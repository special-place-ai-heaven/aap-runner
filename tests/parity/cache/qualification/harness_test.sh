#!/usr/bin/env bash
# P04 Linux qualification harness: lab gate, argument and banner checks, command table, journal,
# environment hygiene, cache corruption, daemon bookkeeping and the shared record.jq verdict.
# REAL LINUX ONLY; hosted ubuntu-latest is fine. Needs bash 4+, coreutils and jq; needs no zccache,
# no compiler and no lab marker, and never runs a build. Not on WSL or the live distro: the
# clean-lab gate test expects neither.
#   bash tests/parity/cache/qualification/harness_test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "${HERE}/../../../.." && pwd)
HARNESS="${REPO}/parity/cache/qualification/harness/qualify.sh"
MATRIX="${REPO}/parity/cache/qualification/linux-x86_64.json"
# shellcheck source=../../../../parity/cache/qualification/harness/qualify.sh
source "${HARNESS}"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails + 1)); }
expect_rc() { # WANT NAME CMD...
  local want=$1 name=$2; shift 2
  "$@" > /dev/null 2>&1
  local rc=$?
  if [[ ${rc} -eq ${want} ]]; then ok "${name}"; else no "${name} (rc ${rc}, want ${want})"; fi
}
tmp=$(mktemp -d)
bg=()
trap '((${#bg[@]})) && kill "${bg[@]}" 2> /dev/null; chmod -R u+w "${tmp}" 2> /dev/null; rm -rf "${tmp}"' EXIT
clean() { env -i PATH="${PATH}" HOME="${HOME:-/}" "$@"; }  # an environment without CI credentials

# ---- lab gate ----
expect_rc 3 "refuses without AAP_ZCCACHE_LAB" clean bash "${HARNESS}"
mkdir -p "${tmp}/root/etc/aap-runner" "${tmp}/empty"
expect_rc 3 "refuses on a live marker even with the opt-in" clean AAP_ZCCACHE_LAB=1 AAP_ZQ_EXTRA_MARKER_ROOT="${tmp}/root" bash "${HARNESS}"
out=$(clean AAP_ZCCACHE_LAB=1 AAP_ZQ_EXTRA_MARKER_ROOT="${tmp}/root" bash "${HARNESS}" 2>&1)
[[ "${out}" == *"REFUSED: live aap-runner install markers present: ${tmp}/root/etc/aap-runner"* ]] && ok "names the marker" || no "names the marker: ${out}"
out=$(clean AAP_ZCCACHE_LAB=1 AAP_ZQ_EXTRA_MARKER_ROOT="${tmp}/empty" GH_TOKEN=hunter2 MY_API_KEY=hunter3 bash "${HARNESS}" 2>&1)
[[ "${out}" == *"REFUSED: credential-shaped environment variables present (names only): GH_TOKEN MY_API_KEY"* && "${out}" != *hunter* ]] &&
  ok "refuses credential-shaped variables by name only" || no "refuses credential-shaped variables by name only: ${out}"
out=$(clean AAP_ZCCACHE_LAB=1 AAP_ZQ_EXTRA_MARKER_ROOT="${tmp}/empty" GH_PAT=a GITHUB_PAT=a DB_PASS=a GPG_PASSPHRASE=a NPM_CONFIG__AUTH=a \
  DOCKER_AUTH_CONFIG=a CI_JOB_JWT=a SSH_AUTH_SOCK=/s MYSQL_PWD=a GIT_AUTHOR_NAME=a XAUTHORITY=/x SELENIUM_JAR_PATH=/j bash "${HARNESS}" 2>&1)
[[ "${out}" == *"(names only): CI_JOB_JWT DB_PASS DOCKER_AUTH_CONFIG GH_PAT GITHUB_PAT GPG_PASSPHRASE MYSQL_PWD NPM_CONFIG__AUTH SSH_AUTH_SOCK ;"* ]] &&
  ok "refuses PAT, pass, auth and JWT names; leaves PWD, PATH and GIT_AUTHOR_NAME" || no "refuses PAT, pass, auth and JWT names: ${out}"
out=$(clean AAP_ZCCACHE_LAB=1 AAP_ZQ_EXTRA_MARKER_ROOT="${tmp}/empty" DATABASE_URL=postgres://app:hunter5@db/x \
  HTTPS_PROXY=http://u:hunter6@proxy:3128 PLAIN_URL=https://example.com:443/a@b GIT_URL=ssh://git@github.com/o/r bash "${HARNESS}" 2>&1)
[[ "${out}" == *"(names only): DATABASE_URL HTTPS_PROXY ;"* && "${out}" != *hunter* ]] &&
  ok "refuses URL credentials by value, naming only the variables" || no "refuses URL credentials by value: ${out}"
paths=$(AAP_ZQ_EXTRA_MARKER_ROOT=/x zq_marker_paths)
for p in /etc/aap-runner /var/lib/ghrunner /sys/fs/cgroup/aap.slice/aap-runner.slice /x/etc/aap-runner /x/var/lib/ghrunner; do
  grep -qxF "${p}" <<<"${paths}" && ok "probes ${p}" || no "probes ${p}"
done
clean AAP_ZCCACHE_LAB=1 AAP_ZQ_EXTRA_MARKER_ROOT="${tmp}/empty" bash -c 'source "$1" && zq_assert_lab' _ "${HARNESS}" 2> /dev/null &&
  ok "passes in a clean lab" || no "passes in a clean lab (is this WSL or the live distro?)"
for k in 5.15.153.1-microsoft-standard-WSL2 4.4.0-19041-Microsoft 6.6.87.2-microsoft-standard-WSL2+; do
  zq_is_wsl_kernel "${k}" && ok "WSL kernel ${k}" || no "WSL kernel ${k}"
done
for k in 6.17.0-1022-azure 6.8.0-45-generic; do
  zq_is_wsl_kernel "${k}" && no "not WSL ${k}" || ok "not WSL ${k}"
done

# ---- arguments and banner ----
f="${tmp}/file"; : > "${f}"
ln -s "${tmp}/empty" "${tmp}/worklink"
good=(clang "${f}" 18.1.3 compile-object "${f}" "${tmp}/rec.json" parity/cache/qualification/evidence/x.json "${tmp}/new")
expect_rc 0 "accepts a valid set" zq_check_args "${good[@]}"
expect_rc 2 "rejects an unknown compiler" zq_check_args nvcc "${good[@]:1}"
expect_rc 2 "rejects a pair with no Linux row" zq_check_args gcc "${f}" 13.3.0 path-with-spaces "${f}" o parity/cache/qualification/x.json "${tmp}/new"
expect_rc 2 "rejects .. in the evidence ref" zq_check_args "${good[@]:0:6}" parity/cache/qualification/../x.json "${tmp}/new"
expect_rc 2 "rejects a ref outside the tree" zq_check_args "${good[@]:0:6}" docs/x.json "${tmp}/new"
expect_rc 2 "rejects a missing zccache" zq_check_args "${good[@]:0:4}" /nope "${good[@]:5}"
expect_rc 2 "rejects a non-empty work dir" zq_check_args "${good[@]:0:7}" "${tmp}/root"
expect_rc 2 "rejects a work path that is a file" zq_check_args "${good[@]:0:7}" "${f}"
expect_rc 2 "rejects a work dir that is a symlink" zq_check_args "${good[@]:0:7}" "${tmp}/worklink"
expect_rc 0 "accepts an empty work dir" zq_check_args "${good[@]:0:7}" "${tmp}/empty"
expect_rc 2 "rejects a wrong argument count" zq_check_args clang
mkdir -p "${tmp}/real"; ln -s "${tmp}/real" "${tmp}/via"
[[ "$(zq_work_dir "${tmp}/via/w")" == "$(cd "${tmp}/real" && pwd -P)/w" && -d "${tmp}/real/w" && "$(stat -c %a "${tmp}/real/w")" == 700 ]] &&
  ok "WORK is created 0700 and canonical (symlinked parent resolved)" || no "WORK is canonical: $(zq_work_dir "${tmp}/via/w")"
[[ "$(cd "${tmp}" && zq_work_dir rel/w)" == "$(cd "${tmp}" && pwd -P)/rel/w" ]] && ok "a relative WORK becomes absolute" || no "a relative WORK becomes absolute"
expect_rc 0 "banner names the version" zq_check_banner rustc 1.99.0 "rustc 1.99.0 (0123abcd 2026-09-01)"
expect_rc 0 "gcc banner with a distro suffix" zq_check_banner gcc 13.3.0 "gcc (Ubuntu 13.3.0-6ubuntu2~24.04) 13.3.0"
expect_rc 2 "rejects a longer version" zq_check_banner clang 18.1.3 "Ubuntu clang version 18.1.30"
expect_rc 2 "rejects a partial version" zq_check_banner rustc 1.99 "rustc 1.99.0 (0123abcd 2026-09-01)"
expect_rc 2 "dots are literal" zq_check_banner clang 18.1.3 "clang version 18x1x3"
expect_rc 2 "rejects a non-numeric version" zq_check_banner clang "VS 18" "clang version 18"

# ---- harness and matrix agree ----
mpairs=$(jq -r '.rows[] | "\(.compiler)/\(.invocation)"' "${MATRIX}" | sort -u)
hpairs=$(for c in rustc gcc g++ clang clang++; do for i in $(zq_pairs "${c}"); do echo "${c}/${i}"; done; done | sort -u)
[[ "${mpairs}" == "${hpairs}" ]] && ok "harness pairs equal the Linux matrix" || no "harness pairs equal the Linux matrix"
[[ "$(jq -r .zccache.binary_sha256 "${MATRIX}")" == "${ZQ_BINARY_SHA256}" ]] && ok "pinned zccache hash equals the matrix" || no "pinned zccache hash equals the matrix"

# ---- command table ----
mapfile -t a < <(zq_command gcc response-file /s ok "${tmp}/a.rsp")
[[ "${a[*]}" == "@${tmp}/a.rsp" && "$(cat "${tmp}/a.rsp")" == '"-c" "/s/hello.c" "-o" "/s/out/hello.o" ' ]] && ok "response file" || no "response file: ${a[*]}"
mapfile -t a < <(zq_command clang++ depfile /s error "${tmp}/b.rsp")
[[ " ${a[*]} " == *" /s/error.cpp "* && " ${a[*]} " == *" -MF /s/out/hello.d "* ]] && ok "error source and depfile" || no "error source and depfile: ${a[*]}"
mapfile -t a < <(zq_command gcc debug-pdb /s ok "${tmp}/b.rsp")
[[ "${a[*]}" == "-g -c hello.c -o out/hello.o" ]] && ok "debug-pdb uses relative paths" || no "debug-pdb uses relative paths: ${a[*]}"
zq_command rustc path-with-spaces "/s w" ok "${tmp}/b.rsp" > "${tmp}/argv"
[[ "${ZQ_PRIMARY}" == libhello.rlib ]] && grep -qxF "/s w/lib.rs" "${tmp}/argv" && grep -qxF lib "${tmp}/argv" && ok "rustc path-with-spaces builds the library" || no "rustc path-with-spaces builds the library"
zq_command rustc link /s ok "${tmp}/b.rsp" > /dev/null
[[ "${ZQ_PRIMARY}" == hello ]] && ok "rustc link builds the binary" || no "rustc link builds the binary"
missing=0
for c in rustc gcc g++ clang clang++; do
  for i in $(zq_pairs "${c}"); do
    for k in ok error; do [[ -n "$(zq_command "${c}" "${i}" /s "${k}" "${tmp}/b.rsp")" ]] || { missing=1; no "command ${c}/${i}/${k}"; }; done
  done
done
((missing)) || ok "every pair has a command in both cases"

# ---- journal, environment, corruption, crash dumps, daemons ----
printf '%s\n' '{"outcome":"hit"}' '{"outcome":"miss"}' 'junk' '{"outcome":"link_hit"}' '{"x":1}' > "${tmp}/j.jsonl"
[[ "$(zq_journal "${tmp}/j.jsonl")" == '{"hit":1,"miss":1,"error":0,"link_hit":1,"link_miss":0,"other":1}' && "$(zq_journal "${tmp}/none.jsonl")" == null ]] &&
  ok "journal outcome counts" || no "journal outcome counts: $(zq_journal "${tmp}/j.jsonl")"
out=$(export ZCCACHE_ENDPOINT=pipe ZCCACHE_PATH_REMAP=auto AAP_ZQ_KEEP=y; zq_clear_env; echo "${ZQ_REMOVED[*]}|${ZCCACHE_ENDPOINT:-gone}|${AAP_ZQ_KEEP}")
[[ "${out}" == *ZCCACHE_ENDPOINT* && "${out}" == *ZCCACHE_PATH_REMAP* && "${out}" == *"|gone|y" ]] && ok "clears every ZCCACHE_ variable" || no "clears every ZCCACHE_ variable: ${out}"
printf '#!/bin/sh\nenv > "$1"\n' > "${tmp}/envdump"; chmod +x "${tmp}/envdump"
(export ZQ_INNOCENT_NAME=hunter7 ZCCACHE_MODE=COPY ZCCACHE_ENDPOINT=pipe TMPDIR="${tmp}"; cd "${tmp}" && zq_run "${tmp}/envdump" "${tmp}/env.txt")
e=$(cat "${tmp}/env.txt")
[[ "${e}" != *hunter7* && "${e}" != *ZCCACHE_ENDPOINT* && "${e}" == *"ZCCACHE_MODE=COPY"* && "${e}" == *"PWD=${tmp}"* && "${e}" == *"PATH=${PATH}"* &&
  "${e}" == *"TMPDIR=${tmp}"* ]] && ok "builds run under env -i with only the allowlist" || no "builds run under env -i with only the allowlist: ${e}"
out=$(echo from-the-shell | zq_run readlink /proc/self/fd/0)
[[ "${out}" == /dev/null ]] && ok "builds and zccache calls read /dev/null, not the shell's stdin" || no "builds and zccache calls read /dev/null: ${out}"
out=$(unset ZCCACHE_CACHE_DIR ZCCACHE_SESSION_ID; export ZCCACHE_MODE=COPY ZCCACHE_ENDPOINT=pipe; zq_kept_zccache_names)
[[ "${out}" == "ZCCACHE_MODE " ]] && ok "records only the ZCCACHE_ names a build sees" || no "records only the ZCCACHE_ names a build sees: ${out}"
store="${tmp}/store"
mkdir -p "${store}/sub" "${tmp}/outside"
printf 'abc' > "${store}/a.bin"; printf 'x' > "${store}/sub/b.bin"; : > "${store}/empty.bin"
printf 'vv' > "${tmp}/outside/v.bin"; ln -s "${tmp}/outside" "${store}/link"; ln -s "${tmp}/outside/v.bin" "${store}/vlink"
touch -d '2026-01-02 03:04:05' "${store}/a.bin"; chmod 0444 "${store}/a.bin"
before=$(stat -c %Y "${store}/a.bin")
n=$(zq_corrupt "${store}" same-size)
[[ "${n}" == 2 && "$(od -An -tx1 "${store}/a.bin" | tr -d ' \n')" == 619d63 && "$(stat -c %s/%Y/%a "${store}/a.bin")" == "3/${before}/444" && ! -s "${store}/empty.bin" && "$(cat "${tmp}/outside/v.bin")" == vv ]] &&
  ok "same-size corruption flips one byte in place, keeps size, mtime and mode, follows no link" || no "same-size corruption (n=${n})"
n=$(zq_corrupt "${store}" marker)
[[ "${n}" == 3 && "$(cat "${store}/a.bin")" == P04-POISON && "$(stat -c %a "${store}/a.bin")" == 444 && "$(cat "${tmp}/outside/v.bin")" == vv ]] && ok "marker corruption" || no "marker corruption (n=${n})"
[[ "$(zq_corrupt "${tmp}/missing" marker)" == 0 ]] && ok "no store, nothing corrupted" || no "no store, nothing corrupted"
mkdir -p "${tmp}/store2"; printf 'abc' > "${tmp}/store2/entry.bin"; printf 'meta' > "${tmp}/store2/entry.meta"
touch -d '2026-01-02 03:04:05' "${tmp}/store2/entry.bin"; before=$(stat -c %Y "${tmp}/store2/entry.bin")
n=$(zq_corrupt "${tmp}/store2" artifact "x $(printf abc | sha256sum | cut -d' ' -f1) y")
[[ "${n}" == 1 && "$(od -An -tx1 "${tmp}/store2/entry.bin" | tr -d ' \n')" == 619d63 && "$(stat -c %Y "${tmp}/store2/entry.bin")" == "${before}" &&
  "$(cat "${tmp}/store2/entry.meta")" == meta ]] && ok "artifact corruption flips only stored copies of uncached artifacts" || no "artifact corruption (n=${n})"
[[ "$(zq_corrupt "${tmp}/store2" artifact "")" == 0 ]] && ok "no artifact hash, nothing corrupted" || no "no artifact hash, nothing corrupted"
mkdir -p "${tmp}/w/cache-ok/crashes" "${tmp}/w/cache-error"; : > "${tmp}/w/cache-ok/crashes/dump.bin"
[[ "$(zq_crash_dumps "${tmp}/w")" == '{"cache-error":0,"cache-ok":1}' || "$(zq_crash_dumps "${tmp}/w")" == '{"cache-ok":1,"cache-error":0}' ]] &&
  ok "counts crash dumps per cache root" || no "counts crash dumps per cache root: $(zq_crash_dumps "${tmp}/w")"
mkdir -p "${tmp}/w/cache-ok/v1.15.6/crashes" "${tmp}/w/cache-ok/v1.15.6/artifacts" "${tmp}/w/cache-error/v1.15.6/crash-spool"
: > "${tmp}/w/cache-ok/v1.15.6/crashes/d.dmp"; : > "${tmp}/w/cache-ok/v1.15.6/artifacts/x"
: > "${tmp}/w/cache-error/v1.15.6/crash-spool/pending-1-2-a.rpcrash"; printf 'r' > "${tmp}/w/cache-error/v1.15.6/crash-spool/pending-3-4-b.rpcrash"
[[ "$(zq_crash_dumps "${tmp}/w" | jq -c -S .)" == '{"cache-error":1,"cache-ok":2}' ]] &&
  ok "counts crash dumps and filled crash-spool records in zccache's v1.15.6 state folder, not empty pending ones" ||
  no "counts crash dumps and filled crash-spool records: $(zq_crash_dumps "${tmp}/w")"
out=$(export ZQ_WORK=/w; zq_phase() { echo "phase $4" >> "${tmp}/poison-steps"; echo '{"exit":0}'; }
  zq_corrupt() { echo "corrupt $1" >> "${tmp}/poison-steps"; echo 1; }; zq_stop_daemons() { echo "stop $1" >> "${tmp}/poison-steps"; echo true; }
  zq_poison /s /w/cache-poison-artifact artifact h)
[[ "$(cat "${tmp}/poison-steps")" == $'phase ok-prime-artifact\ncorrupt /w/cache-poison-artifact/v1.15.6/artifacts\nstop /w\nphase ok-poisoned-artifact' &&
  "$(jq -c . <<<"${out}")" == '{"exit":0,"prime_exit":0,"corrupted_files":1}' ]] &&
  ok "poisons zccache's store in the v1.15.6 state folder, then stops the daemons before the poisoned build" ||
  no "poisons zccache's store in the v1.15.6 state folder: $(cat "${tmp}/poison-steps") ${out}"
mkdir -p "${tmp}/run/src" "${tmp}/run/logs"; printf '#!/bin/sh\n: > out/hello.o\n' > "${tmp}/run/cc"; chmod +x "${tmp}/run/cc"
out=$(export ZQ_COMPILER=gcc ZQ_INVOCATION=debug-pdb ZQ_CC="${tmp}/run/cc" ZQ_LOGS="${tmp}/run/logs" ZQ_RSP="${tmp}/run/a.rsp"; zq_phase "${tmp}/run/src" ok "" direct)
[[ "$(jq -c '[.exit, .argv, .primary_present, .cache_dir, .journal]' <<<"${out}" 2> /dev/null)" == '[0,["-g","-c","hello.c","-o","out/hello.o"],true,null,null]' ]] &&
  ok "a run entry records an argv that starts with options" || no "a run entry records an argv that starts with options: ${out}"
[[ "$(zq_os | jq -r '.kernel_release | length > 0')" == true ]] && ok "records the kernel release" || no "records the kernel release"
for c in "/w/bin/zccache|bin" "/w/bin/sub/x|bin" "/w/cache-ok/v1.15.6/zccache-daemon|root" "/w/cache-poison-marker/v1.15.6/zccache-daemon|root" \
  "/w/cache-ok/v1.15.6/zccache|" "/w/cache-ok/v1.15.5/zccache-daemon|" "/w/cache-ok/x/v1.15.6/zccache-daemon|" "/w/src/v1.15.6/zccache-daemon|" \
  "/w/cache-ok/zccache-daemon|" "/w/cache-ok/v1.15.6/zccache-daemon.old|" "/wx/bin/zccache|" "/other/bin/zccache|"; do
  [[ "$(zq_owner /w "${c%%|*}")" == "${c#*|}" ]] && ok "owner of ${c%%|*} is '${c#*|}'" || no "owner of ${c%%|*}: $(zq_owner /w "${c%%|*}")"
done
dw="${tmp}/dw"; mkdir -p "${dw}/bin" "${dw}/cache-ok/v1.15.6" "${dw}/cache-ok/v9.9.9"
# Copies of bash, not sleep: a multi-call coreutils (uutils) refuses to run under another file name.
for x in bin/zccache-sleep cache-ok/v1.15.6/zccache-daemon cache-ok/v9.9.9/zccache-daemon; do cp "$(command -v bash)" "${dw}/${x}"; done
loop='while :; do sleep 1; done'
"${dw}/bin/zccache-sleep" -c "${loop}" & bg+=($!)
"${dw}/cache-ok/v1.15.6/zccache-daemon" -c "${loop}" & bg+=($!)
"${dw}/cache-ok/v9.9.9/zccache-daemon" -c "${loop}" & decoy=$!; bg+=("${decoy}")
sleep 0.3
d=$(zq_daemons "${dw}")
s=$(sha256sum "${dw}/bin/zccache-sleep" | cut -d' ' -f1)
[[ "$(jq -r --argjson p "${bg[0]}" --arg s "${s}" \
  'map(select(.pid == $p)) | length == 1 and (.[0].in_private_bin == true) and (.[0].in_cache_root == false) and (.[0].sha256 == $s)' <<<"${d}")" == true ]] &&
  ok "lists a zccache process from the private copy with its hash" || no "lists a zccache process from the private copy: ${d}"
[[ "$(jq -r --argjson p "${bg[1]}" --arg s "${s}" \
  'map(select(.pid == $p)) | length == 1 and (.[0].in_private_bin == false) and (.[0].in_cache_root == true) and (.[0].sha256 == $s)' <<<"${d}")" == true ]] &&
  ok "lists the daemon zccache deployed into a cache root with its hash" || no "lists the deployed daemon: ${d}"
[[ "$(jq -r --argjson p "${decoy}" 'map(select(.pid == $p)) | length == 1 and (.[0].in_private_bin == false) and (.[0].in_cache_root == false)' <<<"${d}")" == true ]] &&
  ok "a zccache process elsewhere is listed but not owned" || no "a zccache process elsewhere is listed but not owned: ${d}"
stopped=$(zq_stop_daemons "${dw}")
gone() { [[ "$(cut -d' ' -f3 "/proc/$1/stat" 2> /dev/null || echo X)" == [ZX] ]]; }  # exited: unreaped (a zombie) or no entry
[[ "${stopped}" == true ]] && gone "${bg[0]}" && gone "${bg[1]}" && ok "stops the private copy and the deployed daemon" ||
  no "stops the private copy and the deployed daemon"
gone "${decoy}" && no "leaves a process it does not own running" || ok "leaves a process it does not own running"
[[ "$(zq_stop_daemons "${tmp}/nothing-runs-here")" == true ]] && ok "nothing to stop is a success" || no "nothing to stop is a success"
for b in "" work rel/work /; do
  # kill is shadowed, so even a regressed guard could not signal anything here.
  out=$(kill() { echo "would kill $*"; }; zq_stop_daemons "${b}" 2> /dev/null; echo "rc=$?")
  [[ "${out}" == $'false\nrc=1' ]] && ok "stop refuses work path '${b}'" || no "stop refuses work path '${b}': ${out}"
  expect_rc 1 "pid lookup refuses work path '${b}'" zq_own_pids "${b}"
  [[ "$(zq_daemons "${b}" 2> /dev/null)" == '[]' ]] && ok "work path '${b}' lists nothing" || no "work path '${b}' lists nothing"
done

# ---- verdict (record.jq): the harness never emits qualified ----
J='{"hit":0,"miss":1,"error":0,"link_hit":0,"link_miss":0,"other":0}'
H='{"hit":1,"miss":0,"error":0,"link_hit":0,"link_miss":0,"other":0}'
A='{"hello.o":"a"}'
input=$(jq -c -n --argjson j "${J}" --argjson h "${H}" --argjson a "${A}" --arg zs "${ZQ_BINARY_SHA256}" --arg fs "${ZQ_FP_SHA256}" '
  def e($x; $art; $jr): {exit: $x, artifacts: $art, primary_present: ($x == 0), argv: ["x"], cache_dir: null,
    zccache_env: (if $jr == null then ["ZCCACHE_MODE"] else ["ZCCACHE_CACHE_DIR", "ZCCACHE_MODE", "ZCCACHE_SESSION_ID"] end), journal: $jr};
  {meta: {platform: "linux-x86_64", command: "qualify.sh clang 18.1.3 compile-object x",
          tool_versions: {compiler: "Ubuntu clang version 18.1.3 (1ubuntu1)", compiler_path: "/usr/bin/clang-18",
                          compiler_sha256: ("c" * 64), zccache: "zccache 1.15.6", zccache_sha256: $zs, "zccache-fp_sha256": $fs,
                          jq: "jq-1.7.1"},
          os: {kernel_release: "6.8.0-45-generic", os_release: "Ubuntu 24.04.5 LTS", image_os: "ubuntu24", image_version: "20261012.334.1"},
          env: {set: {ZCCACHE_MODE: "COPY"}, removed: []},
          daemons: [{pid: 42, exe: "/w/bin/zccache", in_private_bin: true, sha256: $zs}], daemons_stopped: true,
          crash_dumps: {"cache-ok": 0, "cache-error": 0},
          started_at: "2026-10-19T00:00:00Z", ended_at: "2026-10-19T00:01:00Z",
          compiler: "clang", compiler_version: "18.1.3", invocation: "compile-object",
          evidence_ref: "parity/cache/qualification/evidence/linux-x86_64/clang-18.1.3-compile-object.json"},
   runs: {uncached: e(0; $a; null), cold: e(0; $a; $j), warm: e(0; $a; $h),
          poisoned_artifact: (e(0; $a; $j) + {prime_exit: 0, corrupted_files: 1}),
          poisoned_same_size: (e(0; $a; $j) + {prime_exit: 0, corrupted_files: 2}),
          poisoned_marker: (e(0; $a; $j) + {prime_exit: 0, corrupted_files: 2})},
   errors: {uncached: e(1; {}; null), cold: e(1; {}; $j), warm: e(1; {}; $j)}}')
verdict() { jq -c -f "${ZQ_HERE}/record.jq" <<<"$1"; }
r=$(verdict "${input}")
[[ "$(jq -r '"\(.harness_pass)|\(.row.mode)|\(.row.reason)|\(.lab_gates | [.[] | select(. != null)] | length)|\(.checks | length)"' <<<"${r}")" == "true|direct|harness checks pass; lab steps 7-9 pending|0|15" ]] &&
  ok "all checks pass, row stays direct" || no "all checks pass, row stays direct: ${r}"
for c in 'warm_has_hits#.runs.warm.journal.hit = 0' 'cold_has_no_hits#.runs.cold.journal = null' \
  'cold_has_no_hits#.runs.cold.journal.other = 1' 'warm_has_hits#.runs.warm.journal.hit = "1"' \
  'errors_stay_errors#.errors.cold.exit = 3' 'errors_stay_errors#.errors.warm.primary_present = true' 'errors_stay_errors#.errors[].exit = null' \
  'artifacts_equal#.runs.warm.artifacts = {"hello.o": "b"}' \
  'ok_runs_produce_primary#(.runs.uncached, .runs.cold, .runs.warm) |= (.artifacts = {} | .primary_present = false)' \
  'poisoned_artifact_rejected#.runs.poisoned_artifact.journal.hit = 1' 'poisoned_artifact_rejected#.runs.poisoned_artifact.corrupted_files = 0' \
  'poisoned_artifact_rejected#.runs.poisoned_artifact.corrupted_files = "2"' \
  'poisoned_same_size_rejected#.runs.poisoned_same_size.journal.hit = 1' 'poisoned_marker_rejected#.runs.poisoned_marker.journal.link_hit = 1' \
  'poisoned_same_size_rejected#.runs.poisoned_same_size.journal |= (.miss = 0 | .other = 1)' \
  'poisoned_marker_rejected#.runs.poisoned_marker.journal.other = 1' \
  'poisoned_marker_rejected#.runs.poisoned_marker.journal.miss = 0' 'poisoned_marker_rejected#del(.runs.poisoned_marker)' \
  'poisoned_same_size_rejected#.runs.poisoned_same_size.corrupted_files = 0' \
  'zccache_env_clean#.runs.warm.zccache_env = ["ZCCACHE_ENDPOINT", "ZCCACHE_MODE"]' 'zccache_env_clean#del(.runs.warm.zccache_env)' \
  'zccache_env_clean#.runs.warm.zccache_env = "ZCCACHE_MODE"' \
  'daemons_pinned#.meta.daemons = []' 'daemons_pinned#.meta.daemons[0].in_private_bin = false' 'daemons_pinned#.meta.daemons[0].sha256 = "0"' \
  'daemons_pinned#.meta.daemons[0].sha256 = null | .meta.tool_versions.zccache_sha256 = null' \
  'daemons_pinned#.meta.daemons[0] |= (.in_private_bin = false | .in_cache_root = false)' \
  'daemons_pinned#.meta.daemons[0] |= (.in_private_bin = false | .in_cache_root = "true")' \
  'no_crash_dumps#.meta.crash_dumps["cache-ok"] = 1' 'no_crash_dumps#.meta.crash_dumps = null' \
  'no_crash_dumps#.meta.crash_dumps["cache-ok"] = null' 'no_crash_dumps#.meta.crash_dumps = {}' \
  'tool_versions_recorded#del(.meta.tool_versions)' 'tool_versions_recorded#del(.meta.tool_versions.jq)' \
  'tool_versions_recorded#.meta.tool_versions.zccache = ""' \
  'compiler_version_observed#.meta.tool_versions.compiler = "clang version 18.1.30"' 'compiler_version_observed#.meta.compiler_version = ""'; do
  want=${c%%#*}
  r=$(verdict "$(jq -c "${c#*#}" <<<"${input}")")
  [[ "$(jq -r --arg k "${want}" '"\(.harness_pass)|\(.row.mode)|\(.checks[$k])"' <<<"${r}")" == "false|direct|false" && "$(jq -r .row.reason <<<"${r}")" == *"${want}"* ]] &&
    ok "fails ${want} for: ${c#*#}" || no "fails ${want} for: ${c#*#}"
done
for k in miss error link_miss; do
  [[ "$(verdict "$(jq -c --arg k "${k}" '.runs.poisoned_marker.journal = ({hit: 0, miss: 0, error: 0, link_hit: 0, link_miss: 0, other: 0} | .[$k] = 1)' <<<"${input}")" |
    jq -r .checks.poisoned_marker_rejected)" == true ]] && ok "a rejected entry may show as ${k}" || no "a rejected entry may show as ${k}"
done
for bad in '{}' '[]' '{"meta":5,"runs":"x","errors":[1]}'; do
  [[ "$(verdict "${bad}" | jq -r '"\(.harness_pass)|\([.checks[] | select(. == true)] | length)"')" == "false|0" ]] &&
    ok "input ${bad} fails every check without a jq error" || no "input ${bad} fails every check without a jq error"
done
r=$(verdict "$(jq -c '.meta.daemons[0] |= (.in_private_bin = false | .in_cache_root = true | .exe = "/w/cache-ok/v1.15.6/zccache-daemon")' <<<"${input}")")
[[ "$(jq -r '"\(.harness_pass)|\(.checks.daemons_pinned)"' <<<"${r}")" == "true|true" ]] && ok "a pinned daemon deployed into a cache root passes" || no "a pinned daemon deployed into a cache root passes"
dbg=$(jq -c '.meta.invocation = "debug-pdb" | .runs.relocated_direct = (.runs.uncached | .artifacts = {"hello.o": "b"})
  | .runs.relocated = (.runs.cold | .artifacts = {"hello.o": "b"})' <<<"${input}")
[[ "$(verdict "${dbg}" | jq -r '"\(.harness_pass)|\(.checks.relocated_matches_direct)"')" == "true|true" ]] && ok "debug-pdb adds the relocated check" || no "debug-pdb adds the relocated check"
[[ "$(verdict "$(jq -c '.runs.relocated.artifacts = {"hello.o": "a"}' <<<"${dbg}")" | jq -r '"\(.harness_pass)|\(.checks.relocated_matches_direct)"')" == "false|false" ]] &&
  ok "a relocated build served from the first tree fails" || no "a relocated build served from the first tree fails"

echo "${fails} failure(s)"
((fails == 0))
