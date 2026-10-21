#!/usr/bin/env bash
# zccache 1.15.6 qualification harness, Linux x86_64. LAB ONLY (P13/P22), see ../README.md.
#
# Runs one (compiler, invocation) pair through method steps 1-6: uncached, cold and warm builds,
# a relocated build for debug-pdb, a control build (prime, stop the daemon, rebuild with nothing
# corrupted), three poisoned-cache builds and the deliberate-error case. Every
# case uses its own fresh cache root. It compares exit codes and artifact hashes, counts journal
# outcomes and writes one evidence record via record.jq. It never emits "qualified": the record's
# row stays "direct" and `harness_pass` says whether steps 1-6 held. Lab steps 7-9 decide the rest.
# zccache runs from a private, hash-checked copy under WORK; its daemons (the copies zccache deploys
# into each cache root) are recorded with their hashes and stopped at the end.
#
# Usage: qualify.sh COMPILER COMPILER_PATH COMPILER_VERSION INVOCATION ZCCACHE OUT EVIDENCE_REF WORK
#   ZCCACHE is the unpacked binary from the pinned archive, with zccache-fp beside it.
# Exit codes: 0 record written (read harness_pass), 1 unexpected harness error (no record), 2 usage,
# 3 refused (not a clean lab), 4 zccache or zccache-fp is not the pinned release binary.
# Needs bash 4+, coreutils, find, Linux /proc and jq 1.7+. Start it from a clean shell:
# no tokens, keys, URL credentials or runner JIT config in the environment (it refuses otherwise).
# Builds and zccache run under `env -i` with only the ZQ_ENV_KEEP variables.
set -u

ZQ_BINARY_SHA256=f97ae874042ab5c80fc2e35342e406972437f1fd45ec81372be33c0f5cbb18cc
ZQ_FP_SHA256=df637b927954093a6fd5c7cc34afc3dd9470a855ec3e03e0342ee9ea9e49f058
ZQ_EVIDENCE_RE='^parity/cache/qualification/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
# Variable names that look like credentials (the zccache daemon and its crash dumps inherit them).
# pat and auth only as whole words (GH_PAT, SSH_AUTH_SOCK, NPM_CONFIG__AUTH, not PATH or
# GIT_AUTHOR_NAME); _pwd$ catches MYSQL_PWD but not PWD.
ZQ_SECRET_NAME_RE='token|secret|pass|credential|jit|jwt|private_?key|(^|_)(api_?)?key$|pem$|(^|_)(pat|auth)($|_)|_pwd$'
# A value carrying URL credentials, scheme://user:password@host, whatever the variable is called.
ZQ_URL_CREDENTIAL_RE='://[^/@[:space:]]*:[^/@[:space:]]*@'
# The only variables builds and zccache (hence its daemons) see; everything else is dropped by
# `env -i`, so a credential the name and value checks miss never reaches them. PWD stays: GCC
# takes DW_AT_comp_dir from it. HOME and the rustup variables let the rustc proxy find its toolchain.
ZQ_ENV_KEEP=(PATH HOME PWD TMPDIR LANG LC_ALL CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN
  ZCCACHE_MODE ZCCACHE_CACHE_DIR ZCCACHE_SESSION_ID)
ZQ_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# zccache 1.15.6 keeps its state one level below the root ZCCACHE_CACHE_DIR names, in v1.15.6/: the
# artifact store, crashes/, crash-spool/, and the copy of itself it deploys and runs as the daemon,
# v1.15.6/zccache-daemon (resolve.rs versioned_subdir, cli/runtime/deploy.rs 106-125 at the pin).
ZQ_STATE=v1.15.6

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

# WSL kernels name themselves (e.g. 5.15.153.1-microsoft-standard-WSL2), even with interop off and
# inside containers, which share the kernel.
zq_is_wsl_kernel() {
  local k=${1,,}
  [[ "${k}" == *microsoft* || "${k}" == *wsl* ]]
}

zq_secret_env_names() { compgen -e | grep -Ei "${ZQ_SECRET_NAME_RE}" | sort -u; }

zq_url_credential_names() { # names only; the values are never printed
  local n
  for n in $(compgen -e); do [[ "${!n-}" =~ ${ZQ_URL_CREDENTIAL_RE} ]] && echo "${n}"; done | sort -u
}

# stdin is /dev/null: the zccache 1.15.6 client reads its stdin, and one started from a shell whose
# stdin stays open (a pipe or a terminal) waited on it forever before compiling (seen in WSL, P04.1).
zq_run() { # CMD... -> CMD under `env -i` with the ZQ_ENV_KEEP variables that are set
  local n
  local -a keep=()
  for n in "${ZQ_ENV_KEEP[@]}"; do [[ -n "${!n+x}" ]] && keep+=("${n}=${!n}"); done
  env -i "${keep[@]}" "$@" < /dev/null
}

zq_kept_zccache_names() { # the ZCCACHE_* names zq_run passes on, space-separated
  local n
  for n in "${ZQ_ENV_KEEP[@]}"; do [[ "${n}" == ZCCACHE_* && -n "${!n+x}" ]] && printf '%s ' "${n}"; done
}

zq_assert_lab() {
  if [[ "${AAP_ZCCACHE_LAB:-}" != 1 ]]; then
    echo "REFUSED: AAP_ZCCACHE_LAB=1 is not set; this harness runs only inside a disposable lab VM" >&2
    return 3
  fi
  local rel=""
  [[ -r /proc/sys/kernel/osrelease ]] && rel=$(< /proc/sys/kernel/osrelease)
  if [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] || compgen -G '/proc/sys/fs/binfmt_misc/WSLInterop*' > /dev/null ||
    zq_is_wsl_kernel "${rel}"; then
    echo "REFUSED: this is WSL (environment, WSLInterop binfmt entry or kernel release '${rel}'); the live pool is a WSL distro, the lab is a VM" >&2
    return 3
  fi
  local p found=()
  while IFS= read -r p; do [[ -e "${p}" ]] && found+=("${p}"); done < <(zq_marker_paths)
  if ((${#found[@]})); then
    echo "REFUSED: live aap-runner install markers present: ${found[*]}" >&2
    return 3
  fi
  local secrets
  secrets=$({ zq_secret_env_names; zq_url_credential_names; } | sort -u | tr '\n' ' ')
  if [[ -n "${secrets}" ]]; then
    echo "REFUSED: credential-shaped environment variables present (names only): ${secrets}; start the harness from a clean shell" >&2
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
  [[ -n "$8" && ! -L "$8" ]] || { echo "USAGE: WORK must be named and must not be a symlink" >&2; return 2; }
  [[ ! -e "$8" ]] || [[ -d "$8" && -z "$(ls -A "$8")" ]] || { echo "USAGE: WORK must name an empty or new directory" >&2; return 2; }
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

zq_artifacts() { # DIR -> JSON object {relative path: sha256}; find does not follow links
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

# Corrupts regular files in a cache store (links are not followed) and prints how many changed.
# artifact flips one byte mid-file in place, keeping length and modification time, in each file
# whose SHA-256 is one of HASHES (a stored copy of an uncached artifact); metadata stays intact,
# so only a content check can notice (upstream does not claim to prove integrity, README 1123).
# same-size does the same to every file, which can include metadata a format check rejects.
# marker replaces each file with the 10-byte P04-POISON, changing its length.
zq_corrupt() { # STORE artifact|same-size|marker [HASHES]
  local n=0 f mode ref size at byte
  ref=$(mktemp)
  while IFS= read -r -d '' f; do
    [[ "$2" != marker && ! -s "${f}" ]] && continue
    [[ "$2" == artifact && " ${3:-} " != *" $(sha256sum < "${f}" | cut -d' ' -f1) "* ]] && continue
    mode=$(stat -c %a "${f}") && chmod u+w "${f}" || continue
    if [[ "$2" == marker ]]; then
      printf P04-POISON > "${f}" && n=$((n + 1))
    else
      size=$(stat -c %s "${f}")
      at=$((size / 2))
      byte=$(od -An -tu1 -j "${at}" -N1 "${f}" | tr -d ' \n')
      if [[ "${byte}" =~ ^[0-9]+$ ]] && touch -r "${f}" "${ref}" &&
        printf '%b' "\\0$(printf '%03o' $((byte ^ 255)))" | dd of="${f}" bs=1 seek="${at}" count=1 conv=notrunc status=none &&
        touch -r "${ref}" "${f}"; then
        n=$((n + 1))
      fi
    fi
    chmod "${mode}" "${f}"
  done < <(find "$1" -type f -print0 2> /dev/null)
  rm -f "${ref}"
  echo "${n}"
}

# WORK must be absolute and below /: an empty or relative path would make the process helpers
# match executables the harness does not own.
zq_work_ok() { [[ "$1" == /?* ]] || { echo "zq: refusing work path '$1'; it must be absolute" >&2; return 1; }; }

# Where an executable runs from: "bin" (the private copy, WORK/bin), "root" (the daemon copy zccache
# deployed into one of the harness's cache roots, exactly WORK/cache-*/v1.15.6/zccache-daemon) or "".
zq_owner() { # WORK EXE
  local rel=${2#"$1"/}
  if [[ "${rel}" == "$2" ]]; then echo ""
  elif [[ "${rel}" == bin/* ]]; then echo bin
  elif [[ "${rel}" == cache-*/* && "${rel#*/}" == "${ZQ_STATE}/zccache-daemon" ]]; then echo root
  else echo ""; fi
}

# Every visible process whose executable is named zccache*, as JSON: the lab records which binary
# the daemons really run, and from where.
zq_daemons() { # WORK
  zq_work_ok "$1" || { echo '[]'; return 1; }
  local p exe
  for p in /proc/[0-9]*; do
    exe=$(readlink "${p}/exe" 2> /dev/null) || continue
    [[ "${exe##*/}" == zccache* ]] || continue
    printf '%s\t%s\t%s\t%s\n' "${p##*/}" "${exe}" "$(sha256sum "${p}/exe" 2> /dev/null | cut -d' ' -f1)" "$(zq_owner "$1" "${exe}")"
  done | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
    | {pid: (.[0] | tonumber), exe: (.[1] | .[0:120]), in_private_bin: (.[3] == "bin"), in_cache_root: (.[3] == "root"),
       sha256: (if .[2] == "" then null else .[2] end)})'
}

zq_own_pids() { # WORK -> pids of processes running the private copy or a deployed daemon copy
  zq_work_ok "$1" || return 1
  local p exe
  for p in /proc/[0-9]*; do
    exe=$(readlink "${p}/exe" 2> /dev/null) || continue
    [[ -n "$(zq_owner "$1" "${exe}")" ]] && echo "${p##*/}"
  done
}

zq_stop_daemons() { # WORK -> prints true when nothing the harness owns runs any more
  zq_work_ok "$1" || { echo false; return 1; }
  local -a pids
  mapfile -t pids < <(zq_own_pids "$1")
  ((${#pids[@]})) && kill -TERM "${pids[@]}" 2> /dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -z "$(zq_own_pids "$1")" ]] && { echo true; return; }
    sleep 0.5
  done
  mapfile -t pids < <(zq_own_pids "$1")
  ((${#pids[@]})) && kill -KILL "${pids[@]}" 2> /dev/null
  sleep 0.5
  if [[ -z "$(zq_own_pids "$1")" ]]; then echo true; else echo false; fi
}

# Counts every file in a crashes/ folder and every non-empty one in a crash-spool/ folder below a
# root: README 433-434 names <root>/crashes; at the pin they are <root>/v1.15.6/crashes and
# crash-spool, where each live process keeps an empty pending-*.rpcrash that a crash fills
# (crash.rs 24-34). No link is followed.
zq_crash_dumps() { # WORK -> JSON object {cache root: crash files below it}; dumps never leave the VM
  local root
  for root in "$1"/cache-*; do
    [[ -d "${root}" ]] || continue
    printf '%s\t%s\n' "${root##*/}" "$(find "${root}" -type f \( -path '*/crashes/*' -o \( -path '*/crash-spool/*' -size +0 \) \) 2> /dev/null | wc -l)"
  done | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber)}) | add // {}'
}

zq_os() { # kernel release and image identity for the record
  local kernel="" pretty=""
  [[ -r /proc/sys/kernel/osrelease ]] && kernel=$(< /proc/sys/kernel/osrelease)
  [[ -r /etc/os-release ]] && pretty=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')
  jq -c -n --arg k "$(zq_printable <<<"${kernel}")" --arg o "$(zq_printable <<<"${pretty}")" \
    --arg io "$(zq_printable <<<"${ImageOS:-}")" --arg iv "$(zq_printable <<<"${ImageVersion:-}")" \
    '{kernel_release: $k, os_release: $o, image_os: (if $io == "" then null else $io end),
      image_version: (if $iv == "" then null else $iv end)}'
}

# One build as a JSON run entry. ROOT empty: the compiler directly. Otherwise through zccache with
# that cache root, inside a journaled session. Every command runs under zq_run (env -i).
zq_phase() { # SRC CASE ROOT NAME
  local src=$1 root=$3 log="${ZQ_LOGS}/$4" rc sid journal=null present=false zenv
  local -a argv
  rm -rf "${src}/out" && mkdir "${src}/out" || return 1
  zq_command "${ZQ_COMPILER}" "${ZQ_INVOCATION}" "${src}" "$2" "${ZQ_RSP}" > "${log}.argv" || return 1
  mapfile -t argv < "${log}.argv"
  if [[ -z "${root}" ]]; then
    zenv=$(zq_kept_zccache_names)
    (cd "${src}" && zq_run "${ZQ_CC}" "${argv[@]}") > "${log}.out" 2> "${log}.err"; rc=$?
  else
    export ZCCACHE_CACHE_DIR="${root}"
    sid=$(cd "${src}" && zq_run "${ZQ_ZC}" session-start --journal "${log}.jsonl" 2> "${log}.session-start.err" | jq -r '.session_id // empty' 2> /dev/null)
    [[ -n "${sid}" ]] && export ZCCACHE_SESSION_ID="${sid}"
    zenv=$(zq_kept_zccache_names)
    (cd "${src}" && zq_run "${ZQ_ZC}" "${ZQ_CC}" "${argv[@]}") > "${log}.out" 2> "${log}.err"; rc=$?
    if [[ -n "${sid}" ]]; then
      (cd "${src}" && zq_run "${ZQ_ZC}" session-end "${sid}" --json) > "${log}.session-end.json" 2>&1
      journal=$(zq_journal "${log}.jsonl")
    fi
    unset ZCCACHE_CACHE_DIR ZCCACHE_SESSION_ID
  fi
  [[ -e "${src}/out/${ZQ_PRIMARY}" ]] && present=true
  # The argv goes in as JSON read from its file: after --args jq still parses options, so -c, -g
  # or -x as a compiler argument would change or break jq's own command line.
  jq -c -n --argjson x "${rc}" --argjson a "$(zq_artifacts "${src}/out")" --argjson p "${present}" \
    --argjson j "${journal}" --arg c "${root##*/}" --arg z "${zenv}" \
    --argjson v "$(jq -R -s -c 'rtrimstr("\n") | split("\n")' "${log}.argv")" \
    '{exit: $x, artifacts: $a, primary_present: $p, argv: $v,
      cache_dir: (if $c == "" then null else $c end), zccache_env: ($z | split(" ") | map(select(length > 0))),
      journal: $j}'
}

zq_poison() { # SRC ROOT artifact|same-size|marker [HASHES]
  local prime stop n p
  prime=$(zq_phase "$1" ok "$2" "ok-prime-$3") || return 1
  # Stop the daemon before corrupting: the daemon alive since priming must not watch the store
  # change (in WSL it served a hit with correct bytes after every store file was replaced, which
  # says nothing about the store), and the poisoned build must start a fresh daemon that reads
  # the store from disk. The stop result is recorded; record.jq's rejected() requires it.
  stop=$(zq_stop_daemons "${ZQ_WORK}") || return 1
  n=$(zq_corrupt "$2/${ZQ_STATE}/artifacts" "$3" "${4:-}")
  p=$(zq_phase "$1" ok "$2" "ok-poisoned-$3") || return 1
  jq -c --argjson e "$(jq .exit <<<"${prime}")" --argjson s "${stop}" --argjson n "${n}" \
    '.prime_exit = $e | .daemon_stopped = $s | .corrupted_files = $n' <<<"${p}"
}

# The control phase: prime a fresh root, stop the daemon, rebuild with nothing corrupted. The
# rebuild must hit and equal uncached, proving a daemon restart alone keeps serving the store.
# Without it every poisoned build's miss could be the restart's doing, not the corruption's
# (M1), and all three poison checks would pass without exercising corruption detection.
# record.jq's rejected() requires this run.
zq_control() { # SRC ROOT
  local prime stop p
  prime=$(zq_phase "$1" ok "$2" ok-control-prime) || return 1
  stop=$(zq_stop_daemons "${ZQ_WORK}") || return 1
  p=$(zq_phase "$1" ok "$2" ok-control) || return 1
  jq -c --argjson e "$(jq .exit <<<"${prime}")" --argjson s "${stop}" '.prime_exit = $e | .daemon_stopped = $s' <<<"${p}"
}

zq_tree() { # WORK NAME -> a fresh copy of the fixtures
  mkdir "$1/$2" && cp "${ZQ_HERE}"/fixtures/* "$1/$2/" && printf '%s\n' "$1/$2"
}

zq_abs() { if [[ "$1" == /* ]]; then printf '%s\n' "$1"; else printf '%s/%s\n' "${PWD}" "$1"; fi; }  # no symlink resolution: clang++ is a symlink to clang
zq_printable() { tr -cd '\40-\176' | cut -c1-120; }

# Creates WORK (mode 0700) and prints its canonical path, symlinks in its parents resolved the way
# /proc/<pid>/exe reports them, so the private bin path matches the daemons' executables.
zq_work_dir() { mkdir -p -- "$1" && chmod 0700 -- "$1" && (cd -- "$1" && pwd -P); }

zq_main() {
  zq_assert_lab || return 3
  zq_clear_env
  zq_check_args "$@" || return 2
  command -v jq > /dev/null || { echo "USAGE: jq is not on PATH" >&2; return 2; }
  ZQ_COMPILER=$1 ZQ_INVOCATION=$4
  ZQ_CC=$(zq_abs "$2")
  local cver=$3 eref=$7 out work zc fp zsha fpsha
  zc=$(zq_abs "$5") out=$(zq_abs "$6")
  fp="$(dirname "${zc}")/zccache-fp"
  [[ -f "${fp}" ]] || { echo "BINARY: ${fp} is missing; unpack zccache-fp beside zccache" >&2; return 4; }

  # Canonical WORK first, then a private copy under it, hashed after copying, never the file given
  # on the command line.
  work=$(zq_work_dir "$8") && mkdir -- "${work}/logs" || return 1
  ZQ_WORK=${work} ZQ_BIN="${work}/bin"
  install -d -m 0700 "${ZQ_BIN}" && cp -- "${zc}" "${ZQ_BIN}/zccache" && cp -- "${fp}" "${ZQ_BIN}/zccache-fp" &&
    chmod 0700 "${ZQ_BIN}/zccache" "${ZQ_BIN}/zccache-fp" || return 1
  ZQ_ZC="${ZQ_BIN}/zccache"
  zsha=$(sha256sum "${ZQ_ZC}" | cut -d' ' -f1)
  fpsha=$(sha256sum "${ZQ_BIN}/zccache-fp" | cut -d' ' -f1)
  [[ "${zsha}" == "${ZQ_BINARY_SHA256}" ]] || { echo "BINARY: ${zc} is ${zsha}, not the pinned 1.15.6 zccache" >&2; return 4; }
  [[ "${fpsha}" == "${ZQ_FP_SHA256}" ]] || { echo "BINARY: ${fp} is ${fpsha}, not the pinned 1.15.6 zccache-fp" >&2; return 4; }
  trap 'zq_stop_daemons "${ZQ_WORK}" > /dev/null' EXIT

  export ZCCACHE_MODE=COPY  # contract rule 6; hardlink and reflink need their own proof
  local started banner src moved
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ZQ_LOGS="${work}/logs" ZQ_RSP="${work}/args.rsp"
  banner=$(zq_run "${ZQ_CC}" --version 2>&1)
  zq_check_banner "${ZQ_COMPILER}" "${cver}" "${banner}" || return 2
  if [[ "${ZQ_INVOCATION}" == path-with-spaces ]]; then src=$(zq_tree "${work}" "src with spaces"); else src=$(zq_tree "${work}" src); fi || return 1

  # Fresh cache root per case; no cache root is ever deleted (its daemon may still be alive).
  local u c w rd=null r=null ctl pa ps pm eu ec ew
  u=$(zq_phase "${src}" ok "" ok-uncached) || return 1
  c=$(zq_phase "${src}" ok "${work}/cache-ok" ok-cold) || return 1
  w=$(zq_phase "${src}" ok "${work}/cache-ok" ok-warm) || return 1
  if [[ "${ZQ_INVOCATION}" == debug-pdb ]]; then
    moved=$(zq_tree "${work}" relocated) || return 1
    rd=$(zq_phase "${moved}" ok "" ok-relocated-direct) || return 1
    r=$(zq_phase "${moved}" ok "${work}/cache-ok" ok-relocated) || return 1
  fi
  ctl=$(zq_control "${src}" "${work}/cache-control") || return 1
  pa=$(zq_poison "${src}" "${work}/cache-poison-artifact" artifact "$(jq -r '.artifacts[]' <<<"${u}" | tr '\n' ' ')") || return 1
  ps=$(zq_poison "${src}" "${work}/cache-poison-same-size" same-size) || return 1
  pm=$(zq_poison "${src}" "${work}/cache-poison-marker" marker) || return 1
  eu=$(zq_phase "${src}" error "" error-uncached) || return 1
  ec=$(zq_phase "${src}" error "${work}/cache-error" error-cold) || return 1
  ew=$(zq_phase "${src}" error "${work}/cache-error" error-warm) || return 1

  local daemons stopped crashes tools meta
  daemons=$(zq_daemons "${work}")
  tools=$(jq -c -n --arg b "$(head -n 1 <<<"${banner}" | zq_printable)" --arg p "$(zq_printable <<<"${ZQ_CC}")" \
    --arg s "$(sha256sum "${ZQ_CC}" | cut -d' ' -f1)" --arg z "$(zq_run "${ZQ_ZC}" --version 2>&1 | head -n 1 | zq_printable)" \
    --arg zs "${zsha}" --arg fs "${fpsha}" --arg jv "$(jq --version 2>&1 | head -n 1 | zq_printable)" \
    '{compiler: $b, compiler_path: $p, compiler_sha256: $s, zccache: $z, zccache_sha256: $zs, "zccache-fp_sha256": $fs, jq: $jv}')
  # The final stop before the record: `zccache --version` above may have started a daemon, so the
  # recorded stop covers it too. Crash dumps are counted after the stop, so a daemon that dumps
  # while being stopped (its pending crash-spool record fills) is not missed.
  stopped=$(zq_stop_daemons "${work}")
  crashes=$(zq_crash_dumps "${work}")
  meta=$(jq -c -n --argjson t "${tools}" --argjson os "$(zq_os)" --argjson d "${daemons}" --argjson cd "${crashes}" \
    --argjson ds "${stopped}" --arg cmd "qualify.sh ${ZQ_COMPILER} ${cver} ${ZQ_INVOCATION} ${eref}" \
    --arg st "${started}" --arg en "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg c "${ZQ_COMPILER}" --arg v "${cver}" \
    --arg i "${ZQ_INVOCATION}" --arg e "${eref}" \
    '{platform: "linux-x86_64", command: $cmd, tool_versions: $t, os: $os,
      env: {set: {ZCCACHE_MODE: "COPY", ZCCACHE_CACHE_DIR: "<work>/<cache_dir> per wrapped run",
                  ZCCACHE_SESSION_ID: "per wrapped run, from session-start"}, removed: $ARGS.positional},
      daemons: $d, daemons_stopped: $ds, crash_dumps: $cd,
      started_at: $st, ended_at: $en, compiler: $c, compiler_version: $v, invocation: $i, evidence_ref: $e}' \
    --args ${ZQ_REMOVED[@]+"${ZQ_REMOVED[@]}"})
  jq -n --argjson m "${meta}" --argjson u "${u}" --argjson c "${c}" --argjson w "${w}" --argjson rd "${rd}" \
    --argjson r "${r}" --argjson ctl "${ctl}" --argjson pa "${pa}" --argjson ps "${ps}" --argjson pm "${pm}" \
    --argjson eu "${eu}" --argjson ec "${ec}" --argjson ew "${ew}" \
    '{meta: $m, errors: {uncached: $eu, cold: $ec, warm: $ew},
      runs: ({uncached: $u, cold: $c, warm: $w, control: $ctl, relocated_direct: $rd, relocated: $r,
              poisoned_artifact: $pa, poisoned_same_size: $ps, poisoned_marker: $pm} | with_entries(select(.value != null)))}' \
    > "${work}/record-input.json" || return 1
  jq -a -f "${ZQ_HERE}/record.jq" "${work}/record-input.json" > "${out}" || return 1
  jq -r '"harness_pass=\(.harness_pass): \(.row.reason)"' "${out}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  zq_main "$@"
  exit $?
fi
