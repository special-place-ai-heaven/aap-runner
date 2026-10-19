#!/usr/bin/env bash
# P04 Linux qualification harness: lab gate, argument checks, command table and verdict logic.
# RUN ON REAL LINUX ONLY (needs jq, coreutils). Never on the live distro: the gate test expects
# no live markers on the machine. Nothing here runs zccache or a compiler.
#   bash tests/parity/cache/qualification/harness_test.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HARNESS="${HERE}/../../../../parity/cache/qualification/harness/qualify.sh"
# shellcheck source=../../../../parity/cache/qualification/harness/qualify.sh
source "${HARNESS}"
fails=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fails=$((fails + 1)); }
expect_rc() { # WANT NAME CMD...
  local want=$1 name=$2; shift 2
  "$@" > /dev/null 2>&1; local rc=$?
  if [[ ${rc} -eq ${want} ]]; then ok "${name}"; else no "${name} (rc ${rc}, want ${want})"; fi
}
tmp=$(mktemp -d); trap 'rm -rf "${tmp}"' EXIT

# Lab gate.
expect_rc 3 "refuses without AAP_ZCCACHE_LAB" env -u AAP_ZCCACHE_LAB bash "${HARNESS}"
mkdir -p "${tmp}/root/etc/aap-runner"
expect_rc 3 "refuses on a live marker even with the opt-in" env AAP_ZCCACHE_LAB=1 AAP_ZQ_EXTRA_MARKER_ROOT="${tmp}/root" bash "${HARNESS}"
out=$(AAP_ZCCACHE_LAB=1 AAP_ZQ_EXTRA_MARKER_ROOT="${tmp}/root" bash "${HARNESS}" 2>&1)
[[ "${out}" == *"REFUSED: live aap-runner install markers present: ${tmp}/root/etc/aap-runner"* ]] && ok "names the marker" || no "names the marker: ${out}"
paths=$(AAP_ZQ_EXTRA_MARKER_ROOT=/x zq_marker_paths)
for p in /etc/aap-runner /var/lib/ghrunner /sys/fs/cgroup/aap.slice/aap-runner.slice /x/etc/aap-runner; do
  grep -qxF "${p}" <<<"${paths}" && ok "probes ${p}" || no "probes ${p}"
done
(AAP_ZCCACHE_LAB=1 AAP_ZQ_EXTRA_MARKER_ROOT="${tmp}/empty" zq_assert_lab) 2>/dev/null && ok "passes in a clean lab" || no "passes in a clean lab (is this the live distro or WSL?)"

# Arguments.
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

# Command table.
mapfile -t a < <(zq_command gcc response-file /s /o ok "${tmp}/a.rsp")
[[ "${a[*]}" == "@${tmp}/a.rsp" && "$(cat "${tmp}/a.rsp")" == '"-c" "/s/hello.c" "-o" "/o/hello.o" ' ]] && ok "response file" || no "response file: ${a[*]}"
mapfile -t a < <(zq_command clang++ depfile /s /o error "${tmp}/a.rsp")
[[ " ${a[*]} " == *" /s/error.cpp "* && " ${a[*]} " == *" -MF /o/hello.d "* ]] && ok "error source and depfile" || no "error source and depfile: ${a[*]}"
zq_command rustc rustc-wrapper /s /o ok r > /dev/null; [[ "${ZQ_PRIMARY}" == libhello.rlib ]] && ok "rustc primary" || no "rustc primary"
for c in rustc gcc g++ clang clang++; do
  for i in $(zq_pairs "${c}"); do
    for k in ok error; do [[ -n "$(zq_command "${c}" "${i}" /s /o "${k}" "${tmp}/b.rsp")" ]] || no "command ${c}/${i}/${k}"; done
  done
done
ok "every pair has a command"

# Verdict.
pass_runs='{"uncached":{"exit":0,"artifacts":{"hello.o":"a"},"primary_present":true},"cold":{"exit":0,"artifacts":{"hello.o":"a"},"primary_present":true},"warm":{"exit":0,"artifacts":{"hello.o":"a"},"primary_present":true},"poisoned":{"exit":0,"artifacts":{"hello.o":"a"},"primary_present":true}}'
errs='{"uncached":{"exit":1,"artifacts":{},"primary_present":false},"cold":{"exit":1,"artifacts":{},"primary_present":false},"warm":{"exit":1,"artifacts":{},"primary_present":false}}'
meta='{"zccache_sha256":"x","observed":"clang 18","started":"t","compiler":"clang","version":"18.1.3","invocation":"compile-object","evidence_ref":"parity/cache/qualification/e.json"}'
[[ "$(zq_record "${meta}" "${pass_runs}" "${errs}" '{"cold":0,"warm":2}' | jq -r .row.mode)" == qualified ]] && ok "qualified when all checks hold" || no "qualified when all checks hold"
r=$(zq_record "${meta}" "${pass_runs}" "${errs}" '{"cold":0,"warm":0}')
[[ "$(jq -r .row.mode <<<"${r}")" == direct && "$(jq -r .row.evidence_ref <<<"${r}")" == null && "$(jq -r .row.reason <<<"${r}")" == *warm_has_hits* ]] && ok "no warm hit means direct" || no "no warm hit means direct"
r=$(zq_record "${meta}" "$(jq -c '.poisoned = null' <<<"${pass_runs}")" "${errs}" '{"cold":0,"warm":1}')
[[ "$(jq -r .row.reason <<<"${r}")" == *poisoned_entry_unused* ]] && ok "missing poison step means direct" || no "missing poison step means direct"
r=$(zq_record "${meta}" "${pass_runs}" "$(jq -c '.warm.exit = 0' <<<"${errs}")" '{"cold":0,"warm":1}')
[[ "$(jq -r .row.reason <<<"${r}")" == *errors_stay_errors* ]] && ok "cached error success means direct" || no "cached error success means direct"
printf '%s\n' '{"outcome":"hit"}' '{"outcome":"miss"}' 'junk' '{"outcome":"link_hit"}' > "${tmp}/j.jsonl"
[[ "$(zq_hits "${tmp}/j.jsonl")" == 2 && "$(zq_hits "${tmp}/none.jsonl")" == null ]] && ok "journal hit count" || no "journal hit count"

echo "${fails} failure(s)"
((fails == 0))
