#!/usr/bin/env bash
# zccache guest integration (P13), Linux guest. Needs bash 4+, coreutils, tar and jq (all in the Ubuntu 24.04 image).
#   aap-zccache.sh install ARCHIVE PROVENANCE INSTALL_DIR TOOLCHAINS [WRAPPERS]   image build, as root
#   aap-zccache.sh init INSTALL_DIR JOB_ROOT BUDGET_BYTES [--shared-roots] [--wrapper-timeout SECONDS]
#                      [--wrapper-timeout-long SECONDS]
#                                                                                 guest agent, before Actions starts
#   aap-zccache.sh attach INSTALL_DIR JOB_ROOT BINDING MOUNT RUNNER_NAME          guest agent, on the host's bind
#   aap-zccache.sh state JOB_ROOT                                                 guest agent status/collect (JSON)
#   zcshim COMPILER [ARGS...]   (this file installed under the name zcshim)       per compiler call
# Any wrapper, daemon or budget problem runs the compiler directly (contract rule 7). Nothing here deletes a file
# from a cache root: retention is the daemon's, and a root over budget stops being used. Every safety check carries
# a SAFETY:<id> tag; tests/guests/cache/mutate.py breaks each one and expects a test to fail.
set -u

ZC_PLATFORM=linux-x86_64
# The P04 harness's rules (parity/cache/qualification/harness/qualify.sh): credential-shaped names, URL credentials.
ZC_SECRET_NAME_RE='token|secret|pass|credential|jit|jwt|private_?key|(^|_)(api_?)?key$|pem$|(^|_)(pat|auth)($|_)|_pwd$'
ZC_URL_CREDENTIAL_RE='://[^/@[:space:]]*:[^/@[:space:]]*@'
ZC_COMPILERS=" rustc gcc g++ clang clang++ "
ZC_LOG_LIMIT=1048576
ZC_USAGE_EVERY=30
# The daemon's whole environment besides its root's settings, as in the P04 harness (retention.md 9).
ZC_DAEMON_ENV="PATH HOME PWD TMPDIR LANG LC_ALL CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN"
# A shared root's namespace: binding, disk marker and the guest's own identity must agree on every field.
ZC_NS_KEYS='["repository_id", "repository", "trust_class", "platform", "toolchain_digest", "zccache_version"]'
ZC_TMP=""

zc_die() { echo "aap-zccache: $*" >&2; exit 1; }
zc_sha() { sha256sum -- "$1" | cut -d' ' -f1; }
zc_size() { stat -c %s -- "$1"; }

# Readers (the shim) see the old file or the new one, never half of one, and never an empty one: a failed jq in
# `jq ... FILE | zc_write FILE` leaves FILE as it was.
zc_write() { # PATH < content
  local tmp
  tmp="$1.$$.${RANDOM}.tmp"
  if cat > "${tmp}" && [[ -s "${tmp}" ]]; then mv -f -- "${tmp}" "$1"; else rm -f -- "${tmp}"; return 1; fi
}

zc_mkdir() {
  [[ -L "$1" ]] && zc_die "$1 is a symbolic link"  # SAFETY:LNX-DIR-LINK
  mkdir -p -- "$1"
}

# ---- install (image build) ----

zc_install() { # ARCHIVE PROVENANCE INSTALL_DIR TOOLCHAINS [WRAPPERS]
  local archive=$1 prov=$2 dir=$3 tcs=$4 wrappers=${5:-$(dirname "${BASH_SOURCE[0]}")/../wrappers.json}
  local plat copy names verbose line name m path bytes sha tmp entry tpath real compiler
  plat=$(jq -ce --arg p "${ZC_PLATFORM}" '.platforms[$p] // empty' "${wrappers}") || zc_die "no ${ZC_PLATFORM} entry in ${wrappers}"
  jq -e --argjson w "${plat}" --arg v "$(jq -r .zccache.version "${wrappers}")" '
    .schema == "aap-provenance/1" and .outcome == "accepted" and .hash.verified == true and .staging_check == "strict"
    and .name == $w.acquisition_entry and .version == $v and .file_name == $w.archive and .sha256 == $w.archive_sha256' \
    "${prov}" > /dev/null 2>&1 || zc_die "the archive was not accepted and verified by a strict P03 run for this pin"  # SAFETY:LNX-PROVENANCE
  # Hash and unpack one private copy, so the archive cannot change between the check and the use.
  ZC_TMP=$(mktemp -d) || zc_die "no temp dir"
  trap 'rm -rf -- "${ZC_TMP}"' EXIT
  copy="${ZC_TMP}/archive.tar.gz"
  cp -- "${archive}" "${copy}" || zc_die "cannot copy ${archive}"
  if [[ "$(zc_size "${copy}")" != "$(jq -r .archive_bytes <<< "${plat}")" || "$(zc_sha "${copy}")" != "$(jq -r .archive_sha256 <<< "${plat}")" ]]; then
    zc_die "the archive is not the pinned release archive"  # SAFETY:LNX-ARCHIVE-HASH
  fi
  names=$(tar -tzf "${copy}") || zc_die "unreadable archive"
  verbose=$(tar -tvzf "${copy}") || zc_die "unreadable archive"
  while IFS= read -r line; do
    [[ "${line}" == /* || "${line}" =~ (^|/)\.\.(/|$) ]] && zc_die "refused member '${line}' (absolute or parent segment)"  # SAFETY:LNX-TAR-MEMBER
  done <<< "${names}"
  while IFS= read -r line; do
    [[ -z "${line}" || "${line:0:1}" == - || "${line:0:1}" == d ]] || zc_die "refused a link or special member: ${line:0:1}"  # SAFETY:LNX-TAR-TYPE
  done <<< "${verbose}"
  zc_mkdir "${dir}"
  zc_mkdir "${dir}/bin"
  while IFS= read -r m; do
    name=$(jq -r .name <<< "${m}"); path=$(jq -r .path <<< "${m}"); bytes=$(jq -r .bytes <<< "${m}"); sha=$(jq -r .sha256 <<< "${m}")
    tmp="${ZC_TMP}/${name}"
    tar -xzf "${copy}" -O -- "${path}" > "${tmp}" 2> /dev/null || zc_die "${path} is missing"
    [[ "$(zc_size "${tmp}")" == "${bytes}" && "$(zc_sha "${tmp}")" == "${sha}" ]] || zc_die "${path} is not the pinned member"  # SAFETY:LNX-MEMBER-HASH
    install -m 0755 -- "${tmp}" "${dir}/bin/${name}"
  done < <(jq -c '.members[]' <<< "${plat}")
  install -m 0755 -- "${BASH_SOURCE[0]}" "${dir}/aap-zccache.sh"
  install -m 0755 -- "${BASH_SOURCE[0]}" "${dir}/zcshim"
  install -m 0644 -- "${wrappers}" "${dir}/wrappers.json"
  entry='[]'
  while IFS= read -r m; do
    compiler=$(jq -r .compiler <<< "${m}"); tpath=$(jq -r .path <<< "${m}")
    [[ "${ZC_COMPILERS}" == *" ${compiler} "* && "${tpath}" == /* && -f "${tpath}" ]] || zc_die "refused toolchain entry ${compiler} at '${tpath}'"
    real=$(readlink -f -- "${tpath}")
    entry=$(jq -c --argjson m "${m}" --arg real "${real}" --arg sha "$(zc_sha "${real}")" --argjson bytes "$(zc_size "${real}")" \
      --argjson mtime "$(stat -c %Y -- "${real}")" --argjson e "${entry}" \
      -n '$e + [{compiler: $m.compiler, compiler_version: $m.compiler_version, path: $m.path, real: $real, sha256: $sha, bytes: $bytes, mtime: $mtime}]')
  done < <(jq -c '.toolchains[]' "${tcs}")
  jq -n --argjson t "${entry}" '{schema: 1, toolchains: $t}' | zc_write "${dir}/toolchains.json"
  jq -n --argjson w "${plat}" --arg v "$(jq -r .zccache.version "${wrappers}")" --arg p "${ZC_PLATFORM}" --arg d "$(zc_digest "${entry}")" \
    '{schema: 1, zccache: $v, platform: $p, archive_sha256: $w.archive_sha256, members: [$w.members[] | {name, sha256}], toolchain_digest: $d}' |
    zc_write "${dir}/install.json"
}

# ---- job root, daemons ----

zc_cfg() { echo "$1/state/config.json"; }

# SHA-256 of the lines compiler|version|sha256, sorted bytewise, joined by \n (no final newline). Same on Windows; the
# installer records it for the image catalog, and a shared root is bound only to the digest the guest verified at boot.
zc_digest() { # TOOLCHAINS_JSON_ARRAY
  jq -j '[.[] | "\(.compiler)|\(.compiler_version)|\(.sha256)"] | sort | join("\n")' <<< "$1" | sha256sum | cut -d' ' -f1
}

zc_proc_start() { # PID -> the process start time (field 22 of /proc/PID/stat), or nothing
  local s
  s=$(cat "/proc/$1/stat" 2> /dev/null) || return 1
  s=${s##*) }
  read -r -a f <<< "${s}"
  echo "${f[19]}"
}

zc_daemon_alive() { # PID START
  [[ -n "$1" && -n "$2" && "$(zc_proc_start "$1")" == "$2" ]]  # SAFETY:LNX-DAEMON-ALIVE
}

# Stops a process and every descendant it has (a root's daemon and the compiles it runs).
zc_kill_tree() { # PID
  local all=("$1") i=0 s line f
  while [[ ${i} -lt ${#all[@]} ]]; do
    for s in /proc/[0-9]*/stat; do
      read -r line < "${s}" 2> /dev/null || continue
      read -r -a f <<< "${line##*) }"
      [[ "${f[1]}" == "${all[i]}" ]] && { s=${s#/proc/}; all+=("${s%%/*}"); }
    done
    i=$((i + 1))
  done
  kill -KILL "${all[@]}" 2> /dev/null
  return 0
}

# The installed zccache: always INSTALL_DIR/bin/<pinned member>, never a path from the job's config.
zc_bin() { # INSTALL_DIR
  echo "$1/bin/$(jq -r --arg p "${ZC_PLATFORM}" '.platforms[$p].members[0].name' "$1/wrappers.json")"
}

# Daemon candidates for a root being primed: processes running from BIN whose environment names exactly this root. A
# compile client running at the same time works on another root (the private one during an attach), so it never
# matches.
zc_find_daemons() { # BIN ROOT_DIR [PID...]
  local bin dir=$2 p exe
  bin=$(readlink -f -- "$1"); shift 2
  for p in /proc/[0-9]*; do
    p=${p##*/}
    [[ " $* " == *" ${p} "* ]] && continue
    exe=$(readlink -f -- "/proc/${p}/exe" 2> /dev/null) || continue
    [[ "${exe}" == "${bin}/"* ]] || continue
    tr '\0' '\n' < "/proc/${p}/environ" 2> /dev/null | grep -qxF -- "ZCCACHE_CACHE_DIR=${dir}" && echo "${p}"  # SAFETY:LNX-DAEMON-ID
  done
}

# Runs CMD under the environment a zccache call gets: this one minus every inherited ZCCACHE_* variable and anything
# credential-shaped, plus exactly the root's settings. Names come from `env -0`, so names bash cannot hold as
# variables (npm_config_//host/:_authToken) are seen and dropped too.
zc_child_env() { # ROOT_DIR ARTIFACT_BUDGET CMD...
  local dir=$1 budget=$2 kv n drop=()
  shift 2
  shopt -s nocasematch
  while IFS= read -r -d '' kv; do
    n=${kv%%=*}
    if [[ "${n}" == ZCCACHE_* ]]; then drop+=(-u "${n}"); continue; fi  # SAFETY:LNX-ENV-ZCCACHE
    if [[ "${n}" =~ ${ZC_SECRET_NAME_RE} || "${kv#*=}" =~ ${ZC_URL_CREDENTIAL_RE} ]]; then drop+=(-u "${n}"); fi  # SAFETY:LNX-ENV-SECRET
  done < <(env -0)
  shopt -u nocasematch
  # SAFETY:LNX-COPY-MODE: hardlink delivery stays off until proven (retention.md 6). SAFETY:LNX-BUDGET-SET.
  env "${drop[@]}" ZCCACHE_CACHE_DIR="${dir}" ZCCACHE_MODE=COPY ZCCACHE_CACHE_SIZE_BYTES="${budget}" "$@"
}

# Starts the root's daemon from this (the agent's) environment, never from a job step, under `env -i` with the
# ZC_DAEMON_ENV allowlist. zccache starts its daemon on demand (README 379-381); an empty journaled session is the
# documented call that does it. To confirm in lab.
zc_start_daemon() { # INSTALL_DIR JOB_ROOT ROOT_ID -> rewrites config with the daemon's pid and start time
  local install=$1 job=$2 id=$3 cfg zc dir budget out rc sid start n keep=() known pids
  cfg=$(zc_cfg "${job}")
  zc=$(zc_bin "${install}")
  dir=$(jq -r --arg i "${id}" '.roots[$i].dir' "${cfg}")
  budget=$(jq -r --arg i "${id}" '.roots[$i].artifact_budget_bytes' "${cfg}")
  zc_mkdir "${dir}"
  for n in ${ZC_DAEMON_ENV}; do [[ -n "${!n+x}" ]] && keep+=("${n}=${!n}"); done
  # Output goes to a file, not a pipe: a daemon that inherited the pipe would hold a command substitution open.
  out="${job}/state/prime-${id}.out"
  timeout 60 env -i "${keep[@]}" ZCCACHE_CACHE_DIR="${dir}" ZCCACHE_MODE=COPY ZCCACHE_CACHE_SIZE_BYTES="${budget}" \
    "${zc}" session-start --journal "${job}/state/prime-${id}.jsonl" > "${out}" 2> /dev/null  # SAFETY:LNX-DAEMON-ENV
  rc=$?
  sid=$(jq -r '.session_id // empty' "${out}" 2> /dev/null)
  [[ -n "${sid}" ]] && timeout 60 env -i "${keep[@]}" ZCCACHE_CACHE_DIR="${dir}" ZCCACHE_MODE=COPY ZCCACHE_CACHE_SIZE_BYTES="${budget}" \
    "${zc}" session-end "${sid}" > /dev/null 2>&1
  read -r -a known <<< "$(jq -r '[.roots[] | .daemon.pid // empty | tostring] | join(" ")' "${cfg}")"
  mapfile -t pids < <(zc_find_daemons "$(dirname "${zc}")" "${dir}" "${known[@]}")
  if [[ ${rc} != 0 || ${#pids[@]} -ne 1 ]]; then
    # A failed start, or none or several candidates: stop every candidate rather than leave an unrecorded daemon on a
    # root this job will not use.
    [[ ${#pids[@]} -gt 0 ]] && kill -- "${pids[@]}" 2> /dev/null
    return 1
  fi
  start=$(zc_proc_start "${pids[0]}") || return 1
  jq --arg i "${id}" --argjson p "${pids[0]}" --arg s "${start}" '.roots[$i].daemon = {pid: $p, start: $s}' "${cfg}" | zc_write "${cfg}"
}

zc_init() { # INSTALL_DIR JOB_ROOT BUDGET_BYTES [--shared-roots] [--wrapper-timeout SECONDS] [--wrapper-timeout-long SECONDS]
  local dir=$1 job=$2 budget=$3 shared=false tmo=60 tmol=600 plat ok=1 m d active=() t tcs digest qualified cfg state detail env_lines="" shim
  shift 3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --shared-roots) shared=true; shift ;;
      --wrapper-timeout) tmo=${2:-}; shift 2 || zc_die "--wrapper-timeout needs seconds" ;;
      --wrapper-timeout-long) tmol=${2:-}; shift 2 || zc_die "--wrapper-timeout-long needs seconds" ;;
      *) zc_die "unknown init option $1" ;;
    esac
  done
  [[ "${budget}" =~ ^(0|[1-9][0-9]*)$ ]] || zc_die "budget must be a byte count"
  [[ "${tmo}" =~ ^[1-9][0-9]{0,3}$ && "${tmol}" =~ ^[1-9][0-9]{0,3}$ ]] || zc_die "a wrapper timeout must be 1 to 9999 seconds"
  zc_mkdir "${job}"
  for d in state roots shim; do zc_mkdir "${job}/${d}"; done
  plat=$(jq -ce --arg p "${ZC_PLATFORM}" '.platforms[$p] // empty' "${dir}/wrappers.json") || zc_die "no ${ZC_PLATFORM} entry"
  while IFS= read -r m; do
    [[ -f "${dir}/bin/$(jq -r .name <<< "${m}")" && "$(zc_sha "${dir}/bin/$(jq -r .name <<< "${m}")")" == "$(jq -r .sha256 <<< "${m}")" ]] || ok=0  # SAFETY:LNX-BOOT-BINARY
  done < <(jq -c '.members[]' <<< "${plat}")
  tcs='[]'
  if [[ ${ok} == 1 && -f "${dir}/toolchains.json" ]]; then
    while IFS= read -r t; do
      [[ -f "$(jq -r .real <<< "${t}")" && "$(zc_sha "$(jq -r .real <<< "${t}")")" == "$(jq -r .sha256 <<< "${t}")" ]] && active+=("${t}")  # SAFETY:LNX-BOOT-TOOLCHAIN
    done < <(jq -c '.toolchains[]' "${dir}/toolchains.json")
    [[ ${#active[@]} -gt 0 ]] && tcs=$(printf '%s\n' "${active[@]}" | jq -cs .)
  fi
  digest=$(zc_digest "${tcs}")
  qualified=$(jq -c --argjson t "${tcs}" '[.qualified[] | select(. as $q | any($t[]; .compiler == $q.compiler and .compiler_version == $q.compiler_version))]' <<< "${plat}")
  if [[ ${ok} != 1 ]]; then state=disabled; detail="installed zccache is not the pinned release"
  elif [[ "${budget}" == 0 ]]; then state=disabled; detail="no cache budget"
  elif [[ "${qualified}" == "[]" ]]; then state=direct; detail="no qualified compiler and invocation pair"
  else state=pending; detail=""
  fi
  cfg=$(zc_cfg "${job}")
  jq -n --arg p "${ZC_PLATFORM}" --arg dir "${dir}" --arg job "${job}" --arg st "${state}" --arg de "${detail}" --argjson sh "${shared}" \
    --argjson tmo "${tmo}" --argjson tmol "${tmol}" --arg v "$(jq -r .zccache.version "${dir}/wrappers.json")" \
    --argjson t "${tcs}" --arg dg "${digest}" --argjson q "${qualified}" --argjson b "${budget}" '
    {schema: 1, platform: $p, install_dir: $dir, job_root: $job, zccache_version: $v, shared_roots: $sh, wrapper_timeout_seconds: $tmo,
     wrapper_timeout_long_seconds: $tmol,
     state: $st, detail: $de, toolchains: $t, toolchain_digest: $dg, qualified: $q, active_root: "private",
     roots: {private: {dir: ($job + "/roots/private"), budget_bytes: $b, artifact_budget_bytes: (($b * 3 / 4) | floor), daemon: null}}}' | zc_write "${cfg}"
  if [[ "${state}" == pending ]]; then
    if zc_start_daemon "${dir}" "${job}" private; then
      state=qualified; detail="$(jq length <<< "${qualified}") qualified pairs"
      shim="${dir}/zcshim"
      env_lines="AAP_ZC_STATE=${cfg}"$'\n'
      jq -e 'any(.[]; .compiler == "rustc")' <<< "${qualified}" > /dev/null && env_lines+="RUSTC_WRAPPER=${shim}"$'\n'
      jq -e 'any(.[]; .compiler != "rustc")' <<< "${qualified}" > /dev/null &&
        env_lines+="CMAKE_C_COMPILER_LAUNCHER=${shim}"$'\n'"CMAKE_CXX_COMPILER_LAUNCHER=${shim}"$'\n'
    else
      state=degraded; detail="daemon did not start; compilers run directly"
    fi
    jq --arg st "${state}" --arg de "${detail}" '.state = $st | .detail = $de' "${cfg}" | zc_write "${cfg}"
  fi
  printf '%s' "${env_lines}" > "${job}/state/runner.env"
  cat "${cfg}"
}

# ---- shared root (host-chosen) ----

# Prints {"attached":bool,"reason":...}; never reads the environment. Only a trusted binding is ever attached, and only
# when init turned shared roots on.
zc_attach() { # INSTALL_DIR JOB_ROOT BINDING MOUNT RUNNER_NAME
  local install=$1 job=$2 binding=$3 mount=$4 runner=$5 cfg reason="" b=""
  cfg=$(zc_cfg "${job}")
  b=$(jq -ce . "${binding}" 2> /dev/null) || b=""
  if [[ "$(jq -r .state "${cfg}")" != qualified ]]; then reason="no-qualified-wrappers"
  elif ! jq -e '.shared_roots == true' "${cfg}" > /dev/null; then reason="shared-roots-off"  # SAFETY:LNX-BIND-SWITCH
  elif jq -e '.roots.shared' "${cfg}" > /dev/null; then reason="already-bound"  # SAFETY:LNX-BIND-ONCE
  elif [[ -z "${b}" ]] || ! jq -e --argjson k "${ZC_NS_KEYS}" '.schema == 1 and (.root_id | type) == "string" and .root_id != "" and
      (.namespace | type) == "object" and (.namespace as $n | all($k[]; $n[.] != null and $n[.] != ""))' \
      <<< "${b}" > /dev/null 2>&1; then reason="binding-missing"  # SAFETY:LNX-BIND-MISSING
  elif ! jq -e '.namespace.trust_class == "trusted"' <<< "${b}" > /dev/null; then reason="not-trusted"  # SAFETY:LNX-BIND-CLASS
  elif ! jq -e --arg r "${runner}" '.runner_name == $r' <<< "${b}" > /dev/null; then reason="runner-mismatch"  # SAFETY:LNX-BIND-RUNNER
  elif ! jq -e --arg p "${ZC_PLATFORM}" --arg d "$(jq -r .toolchain_digest "${cfg}")" --arg v "$(jq -r .zccache.version "${install}/wrappers.json")" \
    '.namespace.platform == $p and .namespace.toolchain_digest == $d and .namespace.zccache_version == $v' <<< "${b}" > /dev/null; then reason="toolchain-mismatch"  # SAFETY:LNX-BIND-TOOLCHAIN
  elif [[ -L "${mount}" || -L "${mount}/root" ]]; then reason="root-is-link"  # SAFETY:LNX-BIND-LINK
  elif ! jq -e '(.budget_bytes | type) == "number" and .budget_bytes > 0' <<< "${b}" > /dev/null; then reason="budget-invalid"
  elif ! jq -e --argjson b "${b}" --argjson k "${ZC_NS_KEYS}" '. as $m | $m.root_id == $b.root_id and
      all($k[]; . as $f | $m.namespace[$f] == $b.namespace[$f])' \
      "${mount}/aap-cache-root.json" > /dev/null 2>&1; then reason="marker-mismatch"  # SAFETY:LNX-BIND-MARKER
  fi
  if [[ -z "${reason}" ]]; then
    jq --argjson b "${b}" --arg dir "${mount}/root" '.roots.shared = {dir: $dir, budget_bytes: $b.budget_bytes,
      artifact_budget_bytes: (($b.budget_bytes * 3 / 4) | floor), daemon: null, root_id: $b.root_id, trust_class: "trusted"}' \
      "${cfg}" | zc_write "${cfg}"
    if zc_start_daemon "${install}" "${job}" shared; then
      jq '.active_root = "shared"' "${cfg}" | zc_write "${cfg}"
    else
      jq 'del(.roots.shared)' "${cfg}" | zc_write "${cfg}"
      reason="daemon-start-failed"
    fi
  fi
  jq --arg r "${reason}" '.last_bind = {attached: ($r == ""), reason: (if $r == "" then null else $r end)}' "${cfg}" | zc_write "${cfg}"
  jq -cn --arg r "${reason}" '{attached: ($r == ""), reason: (if $r == "" then null else $r end)}'
}

zc_du() { [[ -d "$1" ]] && du -sb -- "$1" 2> /dev/null | cut -f1 || echo 0; }

zc_state() { # JOB_ROOT -> {"state","detail","bytes"} for status.v5.json cache.state and the agent's reply
  local job=$1 cfg flag state detail bytes='{}' id dir all art
  cfg=$(zc_cfg "${job}")
  [[ -f "${cfg}" ]] || { jq -cn '{state: "unknown", detail: "cache not initialized", bytes: null}'; return 0; }
  state=$(jq -r .state "${cfg}"); detail=$(jq -r .detail "${cfg}")
  flag="${job}/shim/degraded-$(jq -r .active_root "${cfg}")"
  if [[ "${state}" == qualified && -f "${flag}" ]]; then state=degraded; detail="compilers run directly: $(head -c 120 "${flag}")"; fi
  for id in $(jq -r '.roots | keys[]' "${cfg}"); do
    dir=$(jq -r --arg i "${id}" '.roots[$i].dir' "${cfg}")
    all=$(zc_du "${dir}"); art=$(zc_du "${dir}/artifacts")
    bytes=$(jq -c --arg i "${id}" --argjson a "${art}" --argjson t "${all}" --argjson b "$(jq --arg i "${id}" '.roots[$i].budget_bytes' "${cfg}")" \
      '.[$i] = {artifact: $a, other: ($t - $a), budget: $b}' <<< "${bytes}")
  done
  jq -cn --arg s "${state}" --arg d "${detail}" --argjson b "${bytes}" --argjson sh "$(zc_du "${job}/shim")" \
    '{state: $s, detail: ($d | gsub("[^ -~]"; "?") | .[0:200]), bytes: ($b + {shim: $sh})}'
}

# ---- invocation classes (contract enum); prints them, or fails when the call cannot be classified ----

zc_classify() { # COMPILER ARGS...
  local compiler=$1 t=() a rsp=0 i n classes=() compile=0 pch=0 types=""
  shift
  for a in "$@"; do
    if [[ "${a}" == @* ]]; then
      rsp=1
      [[ -f "${a:1}" ]] || return 1
      while IFS= read -r n; do
        n=${n#\"}; n=${n%\"}
        [[ "${n}" == @* ]] && return 1  # nested response files are not classified
        t+=("${n}")
      done < <(grep -oE '"[^"]*"|[^[:space:]]+' -- "${a:1}")
    else
      t+=("${a}")
    fi
  done
  case "${compiler}" in
    rustc)
      for ((i = 0; i < ${#t[@]}; i++)); do
        a=${t[i]}
        case "${a}" in -|--print*|-V|-vV|--version) return 1 ;; esac
        if [[ "${a}" == --crate-type && $((i + 1)) -lt ${#t[@]} ]]; then types+=" ${t[i + 1]//,/ }"
        elif [[ "${a}" == --crate-type=* ]]; then n=${a#--crate-type=}; types+=" ${n//,/ }"; fi
        if [[ "${a}" == -g ]] || { [[ "${a}" =~ ^-Cdebuginfo=(.*)$ ]] && [[ "${BASH_REMATCH[1]}" != 0 && "${BASH_REMATCH[1]}" != none ]]; } ||
          { [[ "${a}" == -C && $((i + 1)) -lt ${#t[@]} && "${t[i + 1]}" =~ ^debuginfo=(.*)$ ]] && [[ "${BASH_REMATCH[1]}" != 0 && "${BASH_REMATCH[1]}" != none ]]; }; then
          classes+=(debug-pdb)
        fi
      done
      [[ -n "${types// /}" ]] || return 1
      n="rustc-wrapper"
      for a in ${types}; do [[ "${a}" == lib || "${a}" == rlib ]] || n="link"; done
      classes+=("${n}")
      ;;
    gcc | g++ | clang | clang++)
      for ((i = 0; i < ${#t[@]}; i++)); do
        a=${t[i]}
        case "${a}" in -|-E|-S|-M|-MM|-fsyntax-only|-###|--version|-dumpversion|-dumpmachine|-print-*) return 1 ;; esac
        [[ "${a}" == -c ]] && compile=1
        if [[ "${a}" == -x && $((i + 1)) -lt ${#t[@]} && "${t[i + 1]}" == *-header ]] || [[ "${a}" == -x*-header ]]; then pch=1; fi
        case "${a}" in -MD|-MMD|-MT|-MQ|-MF*) classes+=(depfile) ;; esac
        [[ "${a}" == -g* && "${a}" != -g0 && "${a}" != -gno-* ]] && classes+=(debug-pdb)
      done
      [[ ${compile} == 1 ]] || return 1
      if [[ ${pch} == 1 ]]; then classes+=(compile-pch); else classes+=(compile-object); fi
      ;;
    *) return 1 ;;
  esac
  [[ ${rsp} == 1 ]] && classes+=(response-file)
  for a in "$@" "${t[@]}"; do [[ "${a}" == *" "* ]] && { classes+=(path-with-spaces); break; }; done
  printf '%s\n' "${classes[@]}" | sort -u
}

# ---- the shim ----

zc_log() { # JOB_ROOT LINE; never fails a build, never writes to the compile's stderr
  local log="$1/shim/shim.log"
  { [[ -f "${log}" && $(zc_size "${log}") -gt ${ZC_LOG_LIMIT} ]] && mv -f -- "${log}" "${log}.1"; } 2> /dev/null  # SAFETY:LNX-LOG-BOUND
  { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >> "${log}"; } 2> /dev/null || true
}

zc_degrade() { { printf '%s' "$3" > "$1/shim/degraded-$2"; } 2> /dev/null || true; }

# Measured at most every 30 s per root. Over budget means the root stops being used for this VM; nothing is evicted.
zc_over_budget() { # JOB_ROOT ROOT_ID DIR BUDGET ARTIFACT_BUDGET -> 0 over budget, 1 within, 2 cannot record the measurement
  local stamp="$1/shim/usage-$2" all art
  if [[ -f "${stamp}" && $(($(date +%s) - $(stat -c %Y -- "${stamp}"))) -lt ${ZC_USAGE_EVERY} ]]; then return 1; fi
  { : > "${stamp}"; } 2> /dev/null || return 2
  all=$(zc_du "$3"); art=$(zc_du "$3/artifacts")
  [[ ${all} -gt $4 || $((all - art)) -gt $(($4 - $5)) ]]  # SAFETY:LNX-OVER-BUDGET
}

zc_resolve() { # NAME -> absolute path (symbolic links kept: clang and clang++ share one binary)
  if [[ "$1" == /* ]]; then echo "$1"; else type -P -- "$1"; fi
}

# The bound of one wrapped call: a single object compile is short; rustc (a whole crate), links and precompiled headers
# routinely run for minutes.
zc_wrapper_timeout() { # CLASSES SHORT LONG
  if [[ " $1 " == *" compile-object "* ]]; then echo "$2"; else echo "$3"; fi  # SAFETY:LNX-TIMEOUT-CLASS
}

zc_shim() { # COMPILER ARGS...
  [[ $# -ge 1 ]] || { echo "zcshim: usage: zcshim COMPILER [ARGS...]" >&2; exit 2; }
  local compiler=$1 self path cfg=${AAP_ZC_STATE:-} info reason="" job="" state root dir budget abudget pid start zcname tmo tmol kind real bytes mtime quals c tc out err rc rc2
  shift
  # zccache is always the pinned member of the install this shim runs from, never a path from the job's config.
  self=$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")
  path=$(zc_resolve "${compiler}") || path=""
  [[ -n "${path}" ]] || path=${compiler}
  if [[ -z "${cfg}" || ! -f "${cfg}" ]]; then reason="no-state"
  elif ! info=$(jq -r --arg p "${path}" --arg pl "${ZC_PLATFORM}" --slurpfile w "${self}/wrappers.json" '
      (.toolchains | map(select(.path == $p)) | first) as $t | .roots[.active_root] as $r |
      [.state, .job_root, .active_root, $r.dir, $r.budget_bytes, $r.artifact_budget_bytes, ($r.daemon.pid // ""), ($r.daemon.start // ""),
       $w[0].platforms[$pl].members[0].name, (.wrapper_timeout_seconds // 60), (.wrapper_timeout_long_seconds // 600),
       ($t.compiler // ""), ($t.real // ""), ($t.bytes // ""), ($t.mtime // ""),
       ([.qualified[] | select(.compiler == $t.compiler and .compiler_version == $t.compiler_version) | .invocation] | join(" "))]
      | map(tostring) | join("\u001f")' "${cfg}" 2> /dev/null); then
    reason="state-unreadable"
  else
    IFS=$'\x1f' read -r state job root dir budget abudget pid start zcname tmo tmol kind real bytes mtime quals <<< "${info}"
    if [[ "${state}" != qualified ]]; then reason="state-${state}"
    elif [[ -z "${kind}" ]]; then reason="unknown-toolchain"
    # ponytail: size and mtime per call, the full hash once per boot (init); a hash per call costs more than a compile.
    elif [[ "$(readlink -f -- "${path}")" != "${real}" || "$(zc_size "${real}" 2> /dev/null)" != "${bytes}" ||
      "$(stat -c %Y -- "${real}" 2> /dev/null)" != "${mtime}" ]]; then reason="toolchain-changed"  # SAFETY:LNX-SHIM-TOOLCHAIN
    elif ! tc=$(zc_classify "${kind}" "$@"); then reason=unclassified
    else
      for c in ${tc}; do [[ " ${quals} " == *" ${c} "* ]] || { reason="not-qualified:${c}"; break; }; done  # SAFETY:LNX-SHIM-QUALIFIED
      if [[ -z "${reason}" ]]; then
        if [[ -f "${job}/shim/degraded-${root}" ]]; then reason=degraded  # SAFETY:LNX-SHIM-FLAG
        else
          zc_over_budget "${job}" "${root}" "${dir}" "${budget}" "${abudget}"
          case $? in 0) reason="over-budget" ;; 2) reason="usage-unwritable" ;; esac
          if [[ -z "${reason}" ]] && ! zc_daemon_alive "${pid}" "${start}"; then reason="daemon-down"; fi  # SAFETY:LNX-SHIM-DAEMON
          [[ -n "${reason}" ]] && zc_degrade "${job}" "${root}" "${reason}"
        fi
      fi
    fi
  fi
  if [[ -n "${reason}" ]]; then
    [[ -n "${job}" ]] && zc_log "${job}" "direct ${path##*/} ${reason}"
    exec "${path}" "$@"
  fi
  { out=$(mktemp "${job}/shim/out.XXXXXX") && err=$(mktemp "${job}/shim/err.XXXXXX"); } 2> /dev/null || exec "${path}" "$@"
  tmo=$(zc_wrapper_timeout "${tc}" "${tmo}" "${tmol}")
  zc_child_env "${dir}" "${abudget}" timeout -k 5 "${tmo}" "${self}/bin/${zcname}" "${path}" "$@" > "${out}" 2> "${err}"  # SAFETY:LNX-SHIM-TIMEOUT
  rc=$?
  if [[ ${rc} == 0 ]]; then
    cat -- "${out}"; cat -- "${err}" >&2; rm -f -- "${out}" "${err}"
    zc_log "${job}" "zccache ${path##*/} exit 0"
    exit 0
  fi
  # Any zccache failure, a compile error included, is answered by the direct compiler: its exit code and output are
  # the build's (contract rule 7). The wrapped call's output is dropped so errors are not reported twice, and a compile
  # error costs two compiler runs. A call that ran past the bound (timeout: 124, or 137 after the kill; timeout killed
  # the client's whole process group) marks the root degraded either way, and the root's daemon is stopped first: it may
  # still be compiling this call's output, which the direct compile is about to write. Other wrapped calls on that root
  # then fail and compile directly too.
  rm -f -- "${out}" "${err}"
  if [[ ${rc} == 124 || ${rc} == 137 ]]; then
    zc_degrade "${job}" "${root}" wrapper-timeout
    zc_daemon_alive "${pid}" "${start}" && zc_kill_tree "${pid}"  # SAFETY:LNX-TIMEOUT-DAEMON
  fi
  "${path}" "$@"  # SAFETY:LNX-SHIM-FALLBACK
  rc2=$?
  [[ ${rc} != 124 && ${rc} != 137 && ${rc2} == 0 ]] && zc_degrade "${job}" "${root}" wrapper-failure
  zc_log "${job}" "fallback ${path##*/} zccache-exit ${rc} direct-exit ${rc2}"
  exit "${rc2}"
}

zc_main() {
  if [[ "$(basename "$0")" == zcshim ]]; then zc_shim "$@"; fi
  local cmd=${1:-}
  shift || true
  case "${cmd}" in
    install) [[ $# -ge 4 ]] || zc_die "usage: install ARCHIVE PROVENANCE INSTALL_DIR TOOLCHAINS [WRAPPERS]"; zc_install "$@" ;;
    init) [[ $# -ge 3 ]] || zc_die "usage: init INSTALL_DIR JOB_ROOT BUDGET_BYTES [--shared-roots] [--wrapper-timeout SECONDS] [--wrapper-timeout-long SECONDS]"; zc_init "$@" ;;
    attach) [[ $# -eq 5 ]] || zc_die "usage: attach INSTALL_DIR JOB_ROOT BINDING MOUNT RUNNER_NAME"; zc_attach "$@" ;;
    state) [[ $# -eq 1 ]] || zc_die "usage: state JOB_ROOT"; zc_state "$@" ;;
    shim) zc_shim "$@" ;;
    *) zc_die "usage: install | init | attach | state | shim (see the header of this file)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then zc_main "$@"; fi
