#!/usr/bin/env bash
# P04 Linux qualification harness: lab gate, argument and banner checks, command table, journal,
# environment hygiene, cache corruption and the shared record.jq verdict.
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
trap 'chmod -R u+w "${tmp}" 2> /dev/null; rm -rf "${tmp}"' EXIT

# ---- lab gate ----
expect_rc 3 "refuses without AAP_ZCCACHE_LAB" env -u AAP_ZCCACHE_LAB bash "${HARNESS}"
mkdir -p "${tmp}/root/etc/aap-runner" "${tmp}/empty"
expect_rc 3 "refuses on a live marker even with the opt-in" env AAP_ZCCACHE_LAB=1 AAP_ZQ_EXTRA_MARKER_ROOT="${tmp}/root" bash "${HARNESS}"
out=$(AAP_ZCCACHE_LAB=1 AAP_ZQ_EXTRA_MARKER_ROOT="${tmp}/root" bash "${HARNESS}" 2>&1)
[[ "${out}" == *"REFUSED: live aap-runner install markers present: ${tmp}/root/etc/aap-runner"* ]] && ok "names the marker" || no "names the marker: ${out}"
paths=$(AAP_ZQ_EXTRA_MARKER_ROOT=/x zq_marker_paths)
for p in /etc/aap-runner /var/lib/ghrunner /sys/fs/cgroup/aap.slice/aap-runner.slice /x/etc/aap-runner /x/var/lib/ghrunner; do
  grep -qxF "${p}" <<<"${paths}" && ok "probes ${p}" || no "probes ${p}"
done
(AAP_ZCCACHE_LAB=1 AAP_ZQ_EXTRA_MARKER_ROOT="${tmp}/empty" zq_assert_lab) 2> /dev/null && ok "passes in a clean lab" || no "passes in a clean lab (is this WSL or the live distro?)"
for k in 5.15.153.1-microsoft-standard-WSL2 4.4.0-19041-Microsoft 6.6.87.2-microsoft-standard-WSL2+; do
  zq_is_wsl_kernel "${k}" && ok "WSL kernel ${k}" || no "WSL kernel ${k}"
done
for k in 6.17.0-1022-azure 6.8.0-45-generic; do
  zq_is_wsl_kernel "${k}" && no "not WSL ${k}" || ok "not WSL ${k}"
done

# ---- arguments and banner ----
f="${tmp}/file"; : > "${f}"
good=(clang "${f}" 18.1.3 compile-object "${f}" "${tmp}/rec.json" parity/cache/qualification/evidence/x.json "${tmp}/new")
expect_rc 0 "accepts a valid set" zq_check_args "${good[@]}"
expect_rc 2 "rejects an unknown compiler" zq_check_args nvcc "${good[@]:1}"
expect_rc 2 "rejects a pair with no Linux row" zq_check_args gcc "${f}" 13.3.0 path-with-spaces "${f}" o parity/cache/qualification/x.json "${tmp}/new"
expect_rc 2 "rejects .. in the evidence ref" zq_check_args "${good[@]:0:6}" parity/cache/qualification/../x.json "${tmp}/new"
expect_rc 2 "rejects a ref outside the tree" zq_check_args "${good[@]:0:6}" docs/x.json "${tmp}/new"
expect_rc 2 "rejects a missing zccache" zq_check_args "${good[@]:0:4}" /nope "${good[@]:5}"
expect_rc 2 "rejects a non-empty work dir" zq_check_args "${good[@]:0:7}" "${tmp}/root"
expect_rc 2 "rejects a wrong argument count" zq_check_args clang
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

# ---- journal, environment, corruption ----
printf '%s\n' '{"outcome":"hit"}' '{"outcome":"miss"}' 'junk' '{"outcome":"link_hit"}' '{"x":1}' > "${tmp}/j.jsonl"
[[ "$(zq_journal "${tmp}/j.jsonl")" == '{"hit":1,"miss":1,"error":0,"link_hit":1,"link_miss":0,"other":1}' && "$(zq_journal "${tmp}/none.jsonl")" == null ]] &&
  ok "journal outcome counts" || no "journal outcome counts: $(zq_journal "${tmp}/j.jsonl")"
out=$(export ZCCACHE_ENDPOINT=pipe ZCCACHE_PATH_REMAP=auto AAP_ZQ_KEEP=y; zq_clear_env; echo "${ZQ_REMOVED[*]}|${ZCCACHE_ENDPOINT:-gone}|${AAP_ZQ_KEEP}")
[[ "${out}" == *ZCCACHE_ENDPOINT* && "${out}" == *ZCCACHE_PATH_REMAP* && "${out}" == *"|gone|y" ]] && ok "clears every ZCCACHE_ variable" || no "clears every ZCCACHE_ variable: ${out}"
store="${tmp}/store"
mkdir -p "${store}/sub"
printf 'ab\377' > "${store}/a.bin"; printf 'x' > "${store}/sub/b.bin"; : > "${store}/empty.bin"
touch -d '2026-01-02 03:04:05' "${store}/a.bin"; chmod 0444 "${store}/a.bin"
before=$(stat -c %Y "${store}/a.bin")
n=$(zq_corrupt "${store}" same-size)
[[ "${n}" == 2 && "$(od -An -tx1 "${store}/a.bin" | tr -d ' \n')" == 626300 && "$(stat -c %s/%Y/%a "${store}/a.bin")" == "3/${before}/444" && ! -s "${store}/empty.bin" ]] &&
  ok "same-size corruption keeps size, mtime and mode" || no "same-size corruption keeps size, mtime and mode (n=${n})"
n=$(zq_corrupt "${store}" marker)
[[ "${n}" == 3 && "$(cat "${store}/a.bin")" == P04-POISON && "$(stat -c %a "${store}/a.bin")" == 444 ]] && ok "marker corruption" || no "marker corruption (n=${n})"
[[ "$(zq_corrupt "${tmp}/missing" marker)" == 0 ]] && ok "no store, nothing corrupted" || no "no store, nothing corrupted"

# ---- verdict (record.jq): the harness never emits qualified ----
J='{"hit":0,"miss":1,"error":0,"link_hit":0,"link_miss":0,"other":0}'
H='{"hit":1,"miss":0,"error":0,"link_hit":0,"link_miss":0,"other":0}'
A='{"hello.o":"a"}'
input=$(jq -c -n --argjson j "${J}" --argjson h "${H}" --argjson a "${A}" '
  def e($x; $art; $jr): {exit: $x, artifacts: $art, primary_present: ($x == 0), argv: ["x"], cache_dir: null, journal: $jr};
  {meta: {platform: "linux-x86_64", command: "qualify.sh clang 18.1.3 compile-object x", tool_versions: {compiler: "clang 18.1.3"},
          env: {set: {ZCCACHE_MODE: "COPY"}, removed: []}, started_at: "2026-10-19T00:00:00Z", ended_at: "2026-10-19T00:01:00Z",
          compiler: "clang", compiler_version: "18.1.3", invocation: "compile-object",
          evidence_ref: "parity/cache/qualification/evidence/linux-x86_64/clang-18.1.3-compile-object.json"},
   runs: {uncached: e(0; $a; null), cold: e(0; $a; $j), warm: e(0; $a; $h),
          poisoned_same_size: (e(0; $a; $j) + {prime_exit: 0, corrupted_files: 2}),
          poisoned_marker: (e(0; $a; $j) + {prime_exit: 0, corrupted_files: 2})},
   errors: {uncached: e(1; {}; null), cold: e(1; {}; $j), warm: e(1; {}; $j)}}')
verdict() { jq -c -f "${ZQ_HERE}/record.jq" <<<"$1"; }
r=$(verdict "${input}")
[[ "$(jq -r '"\(.harness_pass)|\(.row.mode)|\(.row.reason)|\(.lab_gates | [.[] | select(. != null)] | length)"' <<<"${r}")" == "true|direct|harness checks pass; lab steps 7-9 pending|0" ]] &&
  ok "all checks pass, row stays direct" || no "all checks pass, row stays direct: ${r}"
for c in 'warm_has_hits#.runs.warm.journal.hit = 0' 'cold_has_no_hits#.runs.cold.journal = null' \
  'errors_stay_errors#.errors.cold.exit = 3' 'errors_stay_errors#.errors.warm.primary_present = true' \
  'artifacts_equal#.runs.warm.artifacts = {"hello.o": "b"}' 'poisoned_same_size_rejected#.runs.poisoned_same_size.journal.hit = 1' \
  'poisoned_marker_rejected#.runs.poisoned_marker.journal.miss = 0' 'poisoned_marker_rejected#del(.runs.poisoned_marker)' \
  'poisoned_same_size_rejected#.runs.poisoned_same_size.corrupted_files = 0'; do
  want=${c%%#*}
  r=$(verdict "$(jq -c "${c#*#}" <<<"${input}")")
  [[ "$(jq -r --arg k "${want}" '"\(.harness_pass)|\(.row.mode)|\(.checks[$k])"' <<<"${r}")" == "false|direct|false" && "$(jq -r .row.reason <<<"${r}")" == *"${want}"* ]] &&
    ok "fails ${want} for: ${c#*#}" || no "fails ${want} for: ${c#*#}"
done
dbg=$(jq -c '.meta.invocation = "debug-pdb" | .runs.relocated_direct = (.runs.uncached | .artifacts = {"hello.o": "b"})
  | .runs.relocated = (.runs.cold | .artifacts = {"hello.o": "b"})' <<<"${input}")
[[ "$(verdict "${dbg}" | jq -r '"\(.harness_pass)|\(.checks.relocated_matches_direct)"')" == "true|true" ]] && ok "debug-pdb adds the relocated check" || no "debug-pdb adds the relocated check"
[[ "$(verdict "$(jq -c '.runs.relocated.artifacts = {"hello.o": "a"}' <<<"${dbg}")" | jq -r '"\(.harness_pass)|\(.checks.relocated_matches_direct)"')" == "false|false" ]] &&
  ok "a relocated build served from the first tree fails" || no "a relocated build served from the first tree fails"

echo "${fails} failure(s)"
((fails == 0))
