#!/usr/bin/env bash
# zccache 1.15.6 qualification harness, Linux x86_64. LAB ONLY (P13/P22), see ../README.md.
#
# Runs one (compiler, invocation) pair through uncached, cold, warm and poisoned-cache builds
# plus the deliberate-error case, compares exit codes and artifact hashes, counts warm hits from
# the per-session compile journal and writes one evidence record. It never edits the matrix: a
# reviewer copies the record's `row` into linux-x86_64.json.
#
# Usage: qualify.sh COMPILER COMPILER_PATH COMPILER_VERSION INVOCATION ZCCACHE OUT EVIDENCE_REF WORK
# Exit codes: 0 record written (read its verdict), 2 usage, 3 refused (not a lab), 4 the zccache
# binary is not the pinned release binary. Needs bash, coreutils, jq.
set -u

ZQ_BINARY_SHA256=f97ae874042ab5c80fc2e35342e406972437f1fd45ec81372be33c0f5cbb18cc
ZQ_EVIDENCE_RE='^parity/cache/qualification/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'

zq_pairs() {
  case "$1" in
    rustc) echo "rustc-wrapper link path-with-spaces" ;;
    clang | clang++) echo "compile-object compile-pch response-file depfile path-with-spaces" ;;
    gcc | g++) echo "compile-object compile-pch response-file depfile" ;;
    *) return 1 ;;
  esac
}

# The live pool: manager config, work disk, pool slice. AAP_ZQ_EXTRA_MARKER_ROOT adds a root
# (tests only); it never removes the real paths from the check.
zq_marker_paths() {
  local r
  for r in "" ${AAP_ZQ_EXTRA_MARKER_ROOT:+"${AAP_ZQ_EXTRA_MARKER_ROOT}"}; do
    printf '%s\n' "${r}/etc/aap-runner" "${r}/var/lib/ghrunner" "${r}/sys/fs/cgroup/aap.slice/aap-runner.slice"
  done
}

zq_assert_lab() {
  if [[ "${AAP_ZCCACHE_LAB:-}" != 1 ]]; then
    echo "REFUSED: AAP_ZCCACHE_LAB=1 is not set; this harness runs only inside a disposable lab VM" >&2
    return 3
  fi
  if [[ -n "${WSL_DISTRO_NAME:-}" || -e /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
    echo "REFUSED: running under WSL; the live pool is a WSL distro, the lab is a VM" >&2
    return 3
  fi
  local p found=()
  while IFS= read -r p; do [[ -e "${p}" ]] && found+=("${p}"); done < <(zq_marker_paths)
  if ((${#found[@]})); then
    echo "REFUSED: live aap-runner install markers present: ${found[*]}" >&2
    return 3
  fi
}

zq_check_args() { # COMPILER COMPILER_PATH COMPILER_VERSION INVOCATION ZCCACHE OUT EVIDENCE_REF WORK
  (($# == 8)) || { echo "USAGE: expected 8 arguments, got $#" >&2; return 2; }
  local pairs
  pairs=$(zq_pairs "$1") || { echo "USAGE: compiler '$1' is not one of rustc gcc g++ clang clang++" >&2; return 2; }
  [[ " ${pairs} " == *" $4 "* ]] || { echo "USAGE: $1 has no '$4' row in the Linux matrix" >&2; return 2; }
  [[ -n "$3" ]] || { echo "USAGE: COMPILER_VERSION must equal the matrix row" >&2; return 2; }
  [[ "$7" =~ ${ZQ_EVIDENCE_RE} && ! "$7" =~ (^|/)\.\.?(/|$) ]] || { echo "USAGE: EVIDENCE_REF '$7' is not under parity/cache/qualification/" >&2; return 2; }
  [[ -f "$2" && -f "$5" ]] || { echo "USAGE: compiler or zccache path is not a file" >&2; return 2; }
  [[ -n "$6" ]] || { echo "USAGE: OUT is required" >&2; return 2; }
  [[ -n "$8" ]] && { [[ ! -e "$8" ]] || [[ -z "$(ls -A "$8")" ]]; } || { echo "USAGE: WORK must name an empty or new directory" >&2; return 2; }
}

# Prints the argv (one per line) for one run; ZQ_PRIMARY gets the primary artifact name.
zq_command() { # COMPILER INVOCATION SRC OUTDIR CASE RSP
  local c=$1 inv=$2 src=$3 out=$4 bad=0 source lang hdr
  [[ "$5" == error ]] && bad=1
  case "${c}" in
    rustc)
      local rs="${src}/hello.rs" lib="${src}/lib.rs"
      ((bad)) && rs="${src}/error.rs" lib="${src}/error.rs"
      if [[ "${inv}" == rustc-wrapper ]]; then
        ZQ_PRIMARY=libhello.rlib
        printf '%s\n' --crate-name hello --edition 2021 --crate-type lib --emit=metadata,link "${lib}" --out-dir "${out}"
      else
        ZQ_PRIMARY=hello
        printf '%s\n' "${rs}" -o "${out}/hello"
      fi ;;
    gcc | clang | g++ | clang++)
      source="${src}/hello.c" lang=c-header
      [[ "${c}" == g++ || "${c}" == clang++ ]] && source="${src}/hello.cpp" lang=c++-header
      ((bad)) && source="${source%/hello.*}/error.${source##*.}"
      ZQ_PRIMARY=hello.o
      case "${inv}" in
        compile-pch)
          hdr="${src}/hello.h"; ((bad)) && hdr="${source}"
          ZQ_PRIMARY=hello.h.gch
          printf '%s\n' -x "${lang}" "${hdr}" -o "${out}/hello.h.gch" ;;
        response-file)
          printf '"%s" ' -c "${source}" -o "${out}/hello.o" > "$6"
          printf '%s\n' "@$6" ;;
        depfile) printf '%s\n' -c "${source}" -o "${out}/hello.o" -MD -MF "${out}/hello.d" ;;
        *) printf '%s\n' -c "${source}" -o "${out}/hello.o" ;;
      esac ;;
    *) return 2 ;;
  esac
}

zq_artifacts() { # DIR -> JSON object {relative path: sha256}
  (cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) |
    jq -R -s 'split("\n") | map(select(length > 0) | capture("^(?<h>[0-9a-f]{64}) [ *]\\./(?<p>.*)$")) | map({(.p): .h}) | add // {}'
}

# Journal outcomes per README 1240-1273 at the pin: hit, miss, error, link_hit, link_miss.
zq_hits() { # JOURNAL -> count, or null when the journal is missing
  [[ -f "$1" ]] || { echo null; return; }
  jq -R 'fromjson? | select(.outcome == "hit" or .outcome == "link_hit")' "$1" | jq -s length
}

# Builds the record from the runs/error_runs/hits JSON. The row is `qualified` only when every
# check is true.
zq_record() { # META_JSON RUNS_JSON ERRORS_JSON HITS_JSON
  jq -n --argjson m "$1" --argjson r "$2" --argjson e "$3" --argjson h "$4" '
    ($r.uncached) as $u
    | {ok_exit_zero: ($u.exit == 0),
       exit_codes_equal: ($r.cold.exit == $u.exit and $r.warm.exit == $u.exit),
       artifacts_equal: ($r.cold.artifacts == $u.artifacts and $r.warm.artifacts == $u.artifacts),
       cold_has_no_hits: ($h.cold == 0),
       warm_has_hits: (($h.warm // 0) > 0),
       errors_stay_errors: (($e | length) == 3 and ([$e[] | select(.exit == 0 or .primary_present)] | length) == 0),
       poisoned_entry_unused: ($r.poisoned != null and $r.poisoned.exit == $u.exit and $r.poisoned.artifacts == $u.artifacts)} as $c
    | ([$c | to_entries[] | select(.value | not) | .key]) as $failed
    | (if ($failed | length) == 0 then "qualified" else "direct" end) as $mode
    | {schema: 1, item: "P04", platform: "linux-x86_64", zccache_binary_sha256: $m.zccache_sha256,
       compiler_version_observed: $m.observed, started_at: $m.started, ended_at: (now | todate),
       runs: $r, error_runs: $e, hits: $h, checks: $c,
       row: {compiler: $m.compiler, compiler_version: $m.version, invocation: $m.invocation, mode: $mode,
             evidence_ref: (if $mode == "qualified" then $m.evidence_ref else null end),
             reason: (if $mode == "qualified"
                      then "uncached/cold/warm/poisoned exits and artifacts equal; errors stay errors; warm hit observed"
                      else "lab run failed: " + ($failed | join(",")) end)[0:200]}}'
}

zq_main() {
  zq_assert_lab || return 3
  zq_check_args "$@" || return 2
  local compiler=$1 cpath=$2 cver=$3 inv=$4 zc=$5 out=$6 eref=$7 work=$8
  local zsha
  zsha=$(sha256sum "${zc}" | cut -d' ' -f1)
  [[ "${zsha}" == "${ZQ_BINARY_SHA256}" ]] || { echo "BINARY: ${zc} is ${zsha}, not the pinned 1.15.6 zccache" >&2; return 4; }

  local started here src outdir rsp observed
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  mkdir -p "${work}" && work=$(cd "${work}" && pwd)
  src="${work}/src"; [[ "${inv}" == path-with-spaces ]] && src="${work}/src with spaces"
  mkdir -p "${src}" "${work}/logs"
  cp "${here}"/fixtures/* "${src}/"
  outdir="${src}/out" rsp="${work}/args.rsp"
  observed=$("${cpath}" --version 2>&1 | head -n 1)

  # Fresh, isolated cache root and COPY delivery (contract rule 6).
  export ZCCACHE_CACHE_DIR="${work}/cache" ZCCACHE_MODE=COPY
  unset ZCCACHE_DISABLE
  local runs='{}' errs='{}' hits='{}' case phase log rc sid journal entry
  local -a argv
  for case in ok error; do
    for phase in uncached cold warm poisoned; do
      [[ "${case}" == error && "${phase}" == poisoned ]] && continue
      if [[ "${case}" == ok && "${phase}" == poisoned ]]; then
        # Store layout (artifacts/) per README 422-437; corruption must never be served.
        if [[ -z "$(find "${ZCCACHE_CACHE_DIR}/artifacts" -type f 2>/dev/null | head -n 1)" ]]; then
          runs=$(jq -c '.poisoned = null' <<<"${runs}"); continue
        fi
        find "${ZCCACHE_CACHE_DIR}/artifacts" -type f -exec chmod u+w {} + -exec sh -c 'for f; do printf P04-POISON > "$f"; done' sh {} +
      fi
      [[ "${case}" == error && "${phase}" == cold ]] && rm -rf "${ZCCACHE_CACHE_DIR}"
      rm -rf "${outdir}" && mkdir -p "${outdir}"
      log="${work}/logs/${case}-${phase}"
      zq_command "${compiler}" "${inv}" "${src}" "${outdir}" "${case}" "${rsp}" > "${log}.argv"  # sets ZQ_PRIMARY
      mapfile -t argv < "${log}.argv"
      if [[ "${phase}" == uncached ]]; then
        "${cpath}" "${argv[@]}" > "${log}.out" 2> "${log}.err"; rc=$?
      else
        journal="${log}.jsonl"
        sid=$("${zc}" session-start --journal "${journal}" 2> "${log}.session-start.err" | jq -r '.session_id // empty' 2>/dev/null)
        [[ -n "${sid}" ]] && export ZCCACHE_SESSION_ID="${sid}"
        "${zc}" "${cpath}" "${argv[@]}" > "${log}.out" 2> "${log}.err"; rc=$?
        if [[ -n "${sid}" ]]; then
          "${zc}" session-end "${sid}" --json > "${log}.session.json" 2>&1
          unset ZCCACHE_SESSION_ID
        fi
        if [[ "${case}" == ok && "${phase}" != poisoned ]]; then
          if [[ -n "${sid}" ]]; then hits=$(jq -c --arg p "${phase}" --argjson n "$(zq_hits "${journal}")" '.[$p] = $n' <<<"${hits}")
          else hits=$(jq -c --arg p "${phase}" '.[$p] = null' <<<"${hits}"); fi
        fi
      fi
      local present=false; [[ -e "${outdir}/${ZQ_PRIMARY}" ]] && present=true
      entry=$(jq -c -n --argjson x "${rc}" --argjson a "$(zq_artifacts "${outdir}")" --argjson p "${present}" '{exit: $x, artifacts: $a, primary_present: $p}')
      if [[ "${case}" == ok ]]; then runs=$(jq -c --arg k "${phase}" --argjson v "${entry}" '.[$k] = $v' <<<"${runs}")
      else errs=$(jq -c --arg k "${phase}" --argjson v "${entry}" '.[$k] = $v' <<<"${errs}"); fi
    done
  done
  local meta
  meta=$(jq -c -n --arg s "${zsha}" --arg o "${observed}" --arg t "${started}" --arg c "${compiler}" --arg v "${cver}" --arg i "${inv}" --arg e "${eref}" \
    '{zccache_sha256: $s, observed: $o, started: $t, compiler: $c, version: $v, invocation: $i, evidence_ref: $e}')
  zq_record "${meta}" "${runs}" "${errs}" "${hits}" > "${out}" || return 1
  jq -r '.row.mode + ": " + .row.reason' "${out}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  zq_main "$@"
  exit $?
fi
