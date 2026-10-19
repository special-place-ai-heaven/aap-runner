#!/usr/bin/env bash
# zccache 1.15.6 qualification harness, Linux x86_64. LAB ONLY (P13/P22), see ../README.md.
#
# Runs one (compiler, invocation) pair through method steps 1-6: uncached, cold and warm builds,
# a relocated build for debug-pdb, two poisoned-cache builds and the deliberate-error case. Every
# case uses its own fresh cache root. It compares exit codes and artifact hashes, counts journal
# outcomes and writes one evidence record via record.jq. It never emits "qualified": the record's
# row stays "direct" and `harness_pass` says whether steps 1-6 held. Lab steps 7-9 decide the rest.
#
# Usage: qualify.sh COMPILER COMPILER_PATH COMPILER_VERSION INVOCATION ZCCACHE OUT EVIDENCE_REF WORK
#   ZCCACHE is the unpacked binary from the pinned archive, with zccache-fp beside it.
# Exit codes: 0 record written (read harness_pass), 1 unexpected harness error (no record), 2 usage,
# 3 refused (not a lab), 4 zccache or zccache-fp is not the pinned release binary.
# Needs bash 4+, coreutils, find and jq 1.7+.
set -u

ZQ_BINARY_SHA256=f97ae874042ab5c80fc2e35342e406972437f1fd45ec81372be33c0f5cbb18cc
ZQ_FP_SHA256=df637b927954093a6fd5c7cc34afc3dd9470a855ec3e03e0342ee9ea9e49f058
ZQ_EVIDENCE_RE='^parity/cache/qualification/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
ZQ_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

zq_pairs() {
  case "$1" in
    rustc) echo "rustc-wrapper link path-with-spaces" ;;
    clang | clang++) echo "compile-object compile-pch response-file depfile path-with-spaces debug-pdb" ;;
    gcc | g++) echo "compile-object compile-pch response-file depfile debug-pdb" ;;
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

# WSL kernels name themselves (e.g. 5.15.153.1-microsoft-standard-WSL2), even with interop off.
zq_is_wsl_kernel() {
  local k=${1,,}
  [[ "${k}" == *microsoft* || "${k}" == *wsl* ]]
}

zq_assert_lab() {
  if [[ "${AAP_ZCCACHE_LAB:-}" != 1 ]]; then
    echo "REFUSED: AAP_ZCCACHE_LAB=1 is not set; this harness runs only inside a disposable lab VM" >&2
    return 3
  fi
  local rel=""
  [[ -r /proc/sys/kernel/osrelease ]] && rel=$(< /proc/sys/kernel/osrelease)
  if [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" || -e /proc/sys/fs/binfmt_misc/WSLInterop ]] || zq_is_wsl_kernel "${rel}"; then
    echo "REFUSED: this is WSL (environment, interop or kernel release '${rel}'); the live pool is a WSL distro, the lab is a VM" >&2
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

# The compiler's --version banner must name the matrix version (dotted digits, whole number).
zq_check_banner() { # COMPILER VERSION BANNER
  [[ "$2" =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "USAGE: COMPILER_VERSION '$2' must be dotted digits" >&2; return 2; }
  local esc=${2//./[.]}
  grep -Eq "(^|[^0-9.])${esc}(\$|[^0-9.]|[.](\$|[^0-9]))" <<<"$3" ||
    { echo "USAGE: the $1 banner does not name version $2: $(head -n 1 <<<"$3")" >&2; return 2; }
}

# Prints the argv (one per line) for one run in SRC (outputs in SRC/out) and sets ZQ_PRIMARY, so
# call it with stdout redirected, not in a subshell. Runs execute with the working directory at SRC;
# debug-pdb uses relative paths so the relocated build exercises the comp_dir hazard.
zq_command() { # COMPILER INVOCATION SRC CASE RSP
  local c=$1 inv=$2 bad=0 s="$3/" o="$3/out/" base=hello ext=c lang=c-header source hdr
  [[ "$4" == error ]] && bad=1
  [[ "${inv}" == debug-pdb ]] && s="" o="out/"
  case "${c}" in
    rustc)
      # Binary crates pass through uncached upstream (README 400-403); only libraries cache.
      if [[ "${inv}" == rustc-wrapper || "${inv}" == path-with-spaces ]]; then
        local lib="${s}lib.rs"; ((bad)) && lib="${s}error.rs"
        ZQ_PRIMARY=libhello.rlib
        printf '%s\n' --crate-name hello --edition 2021 --crate-type lib --emit=metadata,link "${lib}" --out-dir "${o%/}"
      else
        local rs="${s}hello.rs"; ((bad)) && rs="${s}error.rs"
        ZQ_PRIMARY=hello
        printf '%s\n' "${rs}" -o "${o}hello"
      fi ;;
    gcc | clang | g++ | clang++)
      [[ "${c}" == g++ || "${c}" == clang++ ]] && ext=cpp lang=c++-header
      ((bad)) && base=error
      source="${s}${base}.${ext}"
      ZQ_PRIMARY=hello.o
      case "${inv}" in
        compile-pch)
          hdr="${s}hello.h"; ((bad)) && hdr="${source}"
          ZQ_PRIMARY=hello.h.gch
          printf '%s\n' -x "${lang}" "${hdr}" -o "${o}hello.h.gch" ;;
        response-file)
          printf '"%s" ' -c "${source}" -o "${o}hello.o" > "$5"
          printf '%s\n' "@$5" ;;
        depfile) printf '%s\n' -c "${source}" -o "${o}hello.o" -MD -MF "${o}hello.d" ;;
        debug-pdb) printf '%s\n' -g -c "${source}" -o "${o}hello.o" ;;
        *) printf '%s\n' -c "${source}" -o "${o}hello.o" ;;
      esac ;;
    *) return 2 ;;
  esac
}

zq_artifacts() { # DIR -> JSON object {relative path: sha256}
  (cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) |
    jq -R -s 'split("\n") | map(select(length > 0) | capture("^(?<h>[0-9a-f]{64}) [ *]\\./(?<p>.*)$")) | map({(.p): .h}) | add // {}'
}

zq_journal() { # JOURNAL -> outcome counts (journal.jq), or null when there is no journal
  if [[ -f "$1" ]]; then jq -R -s -c -f "${ZQ_HERE}/journal.jq" "$1"; else echo null; fi
}

# Removes every exported ZCCACHE_* variable so nothing leaks from the lab shell; names in ZQ_REMOVED.
zq_clear_env() {
  local n
  ZQ_REMOVED=()
  for n in $(compgen -e); do
    if [[ "${n}" == ZCCACHE_* ]]; then unset "${n}"; ZQ_REMOVED+=("${n}"); fi
  done
}

# Corrupts every file in a cache store and prints how many changed. same-size keeps each file's
# size and modification time (every byte + 1), so only a content check can notice; marker
# replaces the file with the short marker P04-POISON.
zq_corrupt() { # STORE same-size|marker
  local n=0 f mode ref
  ref=$(mktemp)
  while IFS= read -r -d '' f; do
    [[ "$2" == same-size && ! -s "${f}" ]] && continue
    mode=$(stat -c %a "${f}") && chmod u+w "${f}" || continue
    if [[ "$2" == same-size ]]; then
      touch -r "${f}" "${ref}" &&
        LC_ALL=C tr '\000-\376\377' '\001-\377\000' < "${f}" > "${ref}.data" &&
        cat "${ref}.data" > "${f}" && touch -r "${ref}" "${f}" && n=$((n + 1))
    else
      printf P04-POISON > "${f}" && n=$((n + 1))
    fi
    chmod "${mode}" "${f}"
  done < <(find "$1" -type f -print0 2> /dev/null)
  rm -f "${ref}" "${ref}.data"
  echo "${n}"
}

# One build as a JSON run entry. ROOT empty: the compiler directly. Otherwise through zccache with
# that cache root, inside a journaled session.
zq_phase() { # SRC CASE ROOT NAME
  local src=$1 root=$3 log="${ZQ_LOGS}/$4" rc sid journal=null present=false
  local -a argv
  rm -rf "${src}/out" && mkdir "${src}/out" || return 1
  zq_command "${ZQ_COMPILER}" "${ZQ_INVOCATION}" "${src}" "$2" "${ZQ_RSP}" > "${log}.argv" || return 1
  mapfile -t argv < "${log}.argv"
  if [[ -z "${root}" ]]; then
    (cd "${src}" && exec "${ZQ_CC}" "${argv[@]}") > "${log}.out" 2> "${log}.err"; rc=$?
  else
    export ZCCACHE_CACHE_DIR="${root}"
    sid=$(cd "${src}" && "${ZQ_ZC}" session-start --journal "${log}.jsonl" 2> "${log}.session-start.err" | jq -r '.session_id // empty' 2> /dev/null)
    [[ -n "${sid}" ]] && export ZCCACHE_SESSION_ID="${sid}"
    (cd "${src}" && exec "${ZQ_ZC}" "${ZQ_CC}" "${argv[@]}") > "${log}.out" 2> "${log}.err"; rc=$?
    if [[ -n "${sid}" ]]; then
      (cd "${src}" && "${ZQ_ZC}" session-end "${sid}" --json) > "${log}.session-end.json" 2>&1
      journal=$(zq_journal "${log}.jsonl")
    fi
    unset ZCCACHE_CACHE_DIR ZCCACHE_SESSION_ID
  fi
  [[ -e "${src}/out/${ZQ_PRIMARY}" ]] && present=true
  jq -c -n --argjson x "${rc}" --argjson a "$(zq_artifacts "${src}/out")" --argjson p "${present}" \
    --argjson j "${journal}" --arg c "${root##*/}" \
    '{exit: $x, artifacts: $a, primary_present: $p, argv: $ARGS.positional,
      cache_dir: (if $c == "" then null else $c end), journal: $j}' --args "${argv[@]}"
}

zq_poison() { # SRC ROOT same-size|marker
  local prime n p
  prime=$(zq_phase "$1" ok "$2" "ok-prime-$3") || return 1
  n=$(zq_corrupt "$2/artifacts" "$3")
  p=$(zq_phase "$1" ok "$2" "ok-poisoned-$3") || return 1
  jq -c --argjson e "$(jq .exit <<<"${prime}")" --argjson n "${n}" '.prime_exit = $e | .corrupted_files = $n' <<<"${p}"
}

zq_tree() { # WORK NAME -> a fresh copy of the fixtures
  mkdir "$1/$2" && cp "${ZQ_HERE}"/fixtures/* "$1/$2/" && printf '%s\n' "$1/$2"
}

zq_abs() { if [[ "$1" == /* ]]; then printf '%s\n' "$1"; else printf '%s/%s\n' "${PWD}" "$1"; fi; }  # no symlink resolution: clang++ is a symlink to clang
zq_printable() { tr -cd '\40-\176' | cut -c1-120; }

zq_main() {
  zq_assert_lab || return 3
  zq_check_args "$@" || return 2
  command -v jq > /dev/null || { echo "USAGE: jq is not on PATH" >&2; return 2; }
  ZQ_COMPILER=$1 ZQ_INVOCATION=$4
  ZQ_CC=$(zq_abs "$2") ZQ_ZC=$(zq_abs "$5")
  local cver=$3 eref=$7 out work zsha fpsha fp
  out=$(zq_abs "$6") work=$(zq_abs "$8")
  zsha=$(sha256sum "${ZQ_ZC}" | cut -d' ' -f1)
  [[ "${zsha}" == "${ZQ_BINARY_SHA256}" ]] || { echo "BINARY: ${ZQ_ZC} is ${zsha}, not the pinned 1.15.6 zccache" >&2; return 4; }
  fp="$(dirname "${ZQ_ZC}")/zccache-fp" fpsha=missing
  [[ -f "${fp}" ]] && fpsha=$(sha256sum "${fp}" | cut -d' ' -f1)
  [[ "${fpsha}" == "${ZQ_FP_SHA256}" ]] || { echo "BINARY: ${fp} is ${fpsha}, not the pinned 1.15.6 zccache-fp" >&2; return 4; }

  zq_clear_env
  export ZCCACHE_MODE=COPY  # contract rule 6; hardlink and reflink need their own proof
  local started banner src moved
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "${work}/logs" || return 1
  ZQ_LOGS="${work}/logs" ZQ_RSP="${work}/args.rsp"
  banner=$("${ZQ_CC}" --version 2>&1)
  zq_check_banner "${ZQ_COMPILER}" "${cver}" "${banner}" || return 2
  if [[ "${ZQ_INVOCATION}" == path-with-spaces ]]; then src=$(zq_tree "${work}" "src with spaces"); else src=$(zq_tree "${work}" src); fi || return 1

  # Fresh cache root per case; no cache root is ever deleted (its daemon may still be alive).
  local u c w rd=null r=null ps pm eu ec ew
  u=$(zq_phase "${src}" ok "" ok-uncached) || return 1
  c=$(zq_phase "${src}" ok "${work}/cache-ok" ok-cold) || return 1
  w=$(zq_phase "${src}" ok "${work}/cache-ok" ok-warm) || return 1
  if [[ "${ZQ_INVOCATION}" == debug-pdb ]]; then
    moved=$(zq_tree "${work}" relocated) || return 1
    rd=$(zq_phase "${moved}" ok "" ok-relocated-direct) || return 1
    r=$(zq_phase "${moved}" ok "${work}/cache-ok" ok-relocated) || return 1
  fi
  ps=$(zq_poison "${src}" "${work}/cache-poison-same-size" same-size) || return 1
  pm=$(zq_poison "${src}" "${work}/cache-poison-marker" marker) || return 1
  eu=$(zq_phase "${src}" error "" error-uncached) || return 1
  ec=$(zq_phase "${src}" error "${work}/cache-error" error-cold) || return 1
  ew=$(zq_phase "${src}" error "${work}/cache-error" error-warm) || return 1

  local tools meta
  tools=$(jq -c -n --arg b "$(head -n 1 <<<"${banner}" | zq_printable)" --arg p "$(zq_printable <<<"${ZQ_CC}")" \
    --arg s "$(sha256sum "${ZQ_CC}" | cut -d' ' -f1)" --arg z "$("${ZQ_ZC}" --version 2>&1 | head -n 1 | zq_printable)" \
    --arg zs "${zsha}" --arg fs "${fpsha}" \
    '{compiler: $b, compiler_path: $p, compiler_sha256: $s, zccache: $z, zccache_sha256: $zs, "zccache-fp_sha256": $fs}')
  meta=$(jq -c -n --argjson t "${tools}" --arg cmd "qualify.sh ${ZQ_COMPILER} ${cver} ${ZQ_INVOCATION} ${eref}" \
    --arg st "${started}" --arg en "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "${ZQ_COMPILER}" --arg v "${cver}" \
    --arg i "${ZQ_INVOCATION}" --arg e "${eref}" \
    '{platform: "linux-x86_64", command: $cmd, tool_versions: $t,
      env: {set: {ZCCACHE_MODE: "COPY", ZCCACHE_CACHE_DIR: "<work>/<cache_dir> per wrapped run",
                  ZCCACHE_SESSION_ID: "per wrapped run, from session-start"}, removed: $ARGS.positional},
      started_at: $st, ended_at: $en, compiler: $c, compiler_version: $v, invocation: $i, evidence_ref: $e}' \
    --args ${ZQ_REMOVED[@]+"${ZQ_REMOVED[@]}"})
  jq -n --argjson m "${meta}" --argjson u "${u}" --argjson c "${c}" --argjson w "${w}" --argjson rd "${rd}" \
    --argjson r "${r}" --argjson ps "${ps}" --argjson pm "${pm}" --argjson eu "${eu}" --argjson ec "${ec}" --argjson ew "${ew}" \
    '{meta: $m, errors: {uncached: $eu, cold: $ec, warm: $ew},
      runs: ({uncached: $u, cold: $c, warm: $w, relocated_direct: $rd, relocated: $r,
              poisoned_same_size: $ps, poisoned_marker: $pm} | with_entries(select(.value != null)))}' \
    > "${work}/record-input.json" || return 1
  jq -a -f "${ZQ_HERE}/record.jq" "${work}/record-input.json" > "${out}" || return 1
  jq -r '"harness_pass=\(.harness_pass): \(.row.reason)"' "${out}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  zq_main "$@"
  exit $?
fi
