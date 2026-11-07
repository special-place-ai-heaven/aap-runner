#!/bin/bash
# P15 guest agent of a Linux runner clone (profile ubuntu-24.04), installed by install.sh as
# /usr/local/libexec/aap-guest/agent (root 0755). Contracts: parity/contracts/guest-transport.md (envelope, runner start),
# broker.md (JIT delivery); what the host side expects: supervisor/backends/linux/INTEGRATION.md, P15. Three ways in:
#   agent            the forced command of root's management key (sshd -i on vsock 5222, aap-guest-ssh@.service). stdin:
#                    one envelope line (a leading UTF-8 BOM is tolerated), then exactly payload_bytes bytes. stdout: one
#                    guest_reply line, then exit 0, a refusal included. Input it cannot read gets no reply and exit 0 (the
#                    host counts a failed guest and retries with a higher seq).
#   agent firstboot  aap-guest-firstboot.service, once per clone after cloud-init: host key to KVP, the job user, the TLS
#                    test pair, the post-generation scripts, lingering, Docker, the runner root and the private compile
#                    cache. Seed copies stay until the first probe binds identity; delivery removes them before registered.
#   agent launch     deliver_registration starts it in the transient scope aap-runner.scope with the JIT config on its stdin
#                    pipe; it runs Runner.Listener as the job user with the config in that process's environment only, and
#                    records the runner's exit code. The config never reaches a file, a command line or a log.
# Every guard carries '# check:<name>'; tests/guests/linux/agent_mutations.sh disables each in turn.
# First of all, no core dump of the agent or the launcher (both hold the JIT config): if the limit cannot be set, stop
# before any input is read, with no reply. PR_SET_DUMPABLE cannot be set from bash (INTEGRATION.md, P02.1).
ulimit -c 0 || exit 0   # check:core-off
set -u
export LC_ALL=C
umask 022
S=${AAP_SYSROOT:-}                    # tests only: a fake system root; empty in a guest
ST="${S}/var/lib/aap-guest"           # agent state, root 0700
RR="${S}/opt/actions-runner"          # runner root: the actions-runner overlay (P21); its registration files are written here
CJ="${S}/var/lib/aap-cache"           # the job's private compile-cache root (P13), the job user's, 0700
ZCI="${S}/usr/local/libexec/aap-guest/cache"
CACHE_BUDGET=10737418240              # 10 GiB; counted in the clone cap (the Linux profile has no scratch disk)
KVP_POOL="${S}/var/lib/hyperv/.kvp_pool_1"
HOST_KEY_ITEM=aap-ssh-host-key-ed25519
JOB_USER=runner
START_WAIT=${AAP_START_WAIT:-45}      # seconds start_runner waits for the runner it handed the registration to (tests: less)
SELF=${BASH_SOURCE[0]}
JIT_RE='^[A-Za-z0-9+/]+={0,2}$'       # encoded_jit_config is base64
ONE_SHOT=' deliver_registration start_runner shutdown '

# --- reply -----------------------------------------------------------------------------------------------------------
# One guest_reply echoing this command's vm_id, reservation_id, lease_generation, seq and nonce (E_*, already checked).
# diag is printable ASCII, at most 300 characters before escaping (the schema allows 512).
reply() { # STATUS STATE EXIT_CODE DIAG
  local d="${4//[^ -~]/?}"
  d=${d:0:300}; d=${d//\\/\\\\}; d=${d//\"/\\\"}
  printf '{"schema":1,"kind":"guest_reply","vm_id":"%s","reservation_id":"%s","lease_generation":%s,"seq":%s,"nonce":"%s","status":"%s","guest_state":"%s","runner_exit_code":%s,"diag":"%s"}\n' \
    "${E_VM}" "${E_RID}" "${E_GEN}" "${E_SEQ}" "${E_NONCE}" "$1" "$2" "$3" "${d}"
}

# The envelope: exactly the ten host_cmd fields with their schema types and patterns, one JSON object on the line.
parse_envelope() { # LINE -> E_VM E_RID E_GEN E_SEQ E_NONCE E_CMD E_LEN E_EXP
  local t
  t=$(jq -ers '
    def str($re): type == "string" and test($re);
    def int($lo; $hi): type == "number" and . == floor and . >= $lo and . <= $hi;
    if length == 1 then .[0] else empty end
    | select(type == "object"
        and keys == ["cmd", "expires_at", "kind", "lease_generation", "nonce", "payload_bytes", "reservation_id", "schema", "seq", "vm_id"]
        and .schema == 1 and .kind == "host_cmd"
        and (.vm_id | str("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z"))
        and (.reservation_id | str("\\Ar-[0-9a-f]{16}\\z"))
        and (.lease_generation | int(1; 999999999)) and (.seq | int(1; 2147483647))
        and (.nonce | str("\\A[0-9a-f]{32}\\z"))
        and (.cmd | str("\\A(probe|deliver_registration|start_runner|status|collect|shutdown)\\z"))
        and (.payload_bytes | int(0; 16384))
        and (.expires_at | str("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z")))
    | [.vm_id, .reservation_id, .lease_generation, .seq, .nonce, .cmd, .payload_bytes, .expires_at] | @tsv' <<< "$1" 2> /dev/null) || return 1   # check:cmd-envelope
  IFS=$'\t' read -r E_VM E_RID E_GEN E_SEQ E_NONCE E_CMD E_LEN E_EXP <<< "${t}"
}


proc_start() { # PID -> the process start time (field 22 of /proc/PID/stat), or nothing
  local s f
  s=$(< "/proc/$1/stat") 2> /dev/null || return 1
  read -ra f <<< "${s##*) }"
  printf '%s' "${f[19]:-}"
}

save() { printf '%s\n' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"; }   # FILE VALUE, swapped in whole

# --- offline identity (guest-transport revision 2) --------------------------------------------------------------------
# Comments are ignored by cloud-init. The only input is the host's per-clone user-data, not SMBIOS, KVP or the command.
# A raw stream pass rejects duplicate JSON keys (jq's object parser would silently keep the last); the second pass
# checks the closed Linux record and emits canonical text for comparisons and the persistent binding.
parse_identity() {
  jq --stream -es 'map(select(length == 2) | .[0]) | length == 6 and (unique | length) == 6' <<< "$1" > /dev/null 2>&1 || return 1   # check:identity-duplicates
  jq -ecs '
    def str($re): type == "string" and test($re);
    if length == 1 then .[0] else empty end
    | select(type == "object" and keys == ["kind", "lease_generation", "reservation_id", "schema", "scratch", "vm_id"]
        and .schema == 2 and .kind == "guest_identity"
        and (.vm_id | str("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z"))
        and (.reservation_id | str("\\Ar-[0-9a-f]{16}\\z"))
        and (.lease_generation | type == "number" and . == floor and . >= 1 and . <= 999999999)
        and .scratch == null)
    | {schema, kind, vm_id, reservation_id, lease_generation, scratch}' <<< "$1" 2> /dev/null
}

# All cloud-init identity sources, without following arbitrary links. The instance alias may be relative or absolute; its
# one-segment target must be a plain directory below this NoCloud datasource's instances folder.
identity_material() { # -> MATERIAL CACHE_MATERIAL arrays
  local c="${S}/var/lib/cloud" f d target prefix instance_id
  MATERIAL=(); CACHE_MATERIAL=()
  [ ! -L "${c}" ] && [ ! -L "${c}/instances" ] && [ ! -L "${c}/seed" ] || return 1
  for d in "${c}" "${c}/instances" "${c}/seed"; do
    [ ! -e "${d}" ] || { [ -d "${d}" ] && [ -r "${d}" ] && [ -x "${d}" ]; } || return 1
  done
  if [ -L "${c}/instance" ]; then
    target=$(readlink "${c}/instance") || return 1
    if [[ ${target} == /* ]]; then
      prefix="${c}/instances/"
      [[ ${target} == "${prefix}"* ]] || return 1   # check:identity-instance-link
      instance_id=${target#"${prefix}"}
    else
      [[ ${target} == instances/* ]] || return 1   # check:identity-instance-link
      instance_id=${target#instances/}
    fi
    [[ -n ${instance_id} && ${instance_id} != */* && ${instance_id} != . && ${instance_id} != .. ]] || return 1
    d="${c}/instances/${instance_id}"
    [ -d "${d}" ] && [ ! -L "${d}" ] || return 1
  fi
  for d in "${c}/instances/"* "${c}/instance"; do
    [ -e "${d}" ] || [ -L "${d}" ] || continue
    [ ! -L "${d}" ] || { [ "${d}" = "${c}/instance" ] && continue; return 1; }
    [ -d "${d}" ] && [ -r "${d}" ] && [ -x "${d}" ] || return 1
    for f in "${d}/user-data.txt"* "${d}/cloud-config.txt"*; do
      [ -e "${f}" ] || [ -L "${f}" ] || continue
      MATERIAL+=("${f}")
    done
    f="${d}/obj.pkl"
    [ -e "${f}" ] || [ -L "${f}" ] || continue
    CACHE_MATERIAL+=("${f}")
  done
  if [ -e "${c}/seed" ]; then
    # Capture find's status, not a process substitution's: unreadable material must never look absent.
    find -P "${c}/seed" -mindepth 1 -print0 > "${ST}/material.tmp" 2> /dev/null || return 1
    while IFS= read -r -d '' f; do
      [ ! -L "${f}" ] || return 1
      [ -d "${f}" ] || MATERIAL+=("${f}")
    done < "${ST}/material.tmp"
    rm -f "${ST}/material.tmp" || return 1
  fi
}

read_identity() { # PHASE -> ID, empty only after cleanup. One record per file; identical cached copies are normal.
  local f line record found count size
  ID=''
  identity_material || return 1   # check:identity-material
  [ "$1" != after ] || [ "${#CACHE_MATERIAL[@]}" = 0 ] || return 1   # check:identity-cache-reappeared
  for f in "${MATERIAL[@]}"; do
    [ ! -L "${f}" ] && [ -f "${f}" ] && [ -r "${f}" ] || return 1   # check:identity-readable
    size=$(stat -c %s "${f}") || return 1
    [ "${size}" -le 1048576 ] || return 1   # check:identity-size
    # The writer emits ASCII. Do not let bash discard a NUL or decode hostile bytes into a diagnostic.
    [ "$(tr -d '\11\12\15\40-\176' < "${f}" | wc -c)" = 0 ] || return 1   # check:identity-ascii
    count=0
    while IFS= read -r line || [ -n "${line}" ]; do
      [[ ${line} == *aap-guest-identity* ]] || continue
      [ "$1" != after ] || return 1   # check:identity-after-cleanup
      count=$((count + 1))
      [ "${count}" = 1 ] || return 1   # check:identity-one-record
      [[ ${line} == '# aap-guest-identity: '* ]] || return 1   # check:identity-schema
      record=$(parse_identity "${line#\# aap-guest-identity: }") && [ -n "${record}" ] || return 1   # check:identity-schema
      found=${ID}
      [ -z "${found}" ] || [ "${found}" = "${record}" ] || return 1   # check:identity-copies
      ID=${record}
    done < "${f}"
  done
  [ "$1" = after ] || [ -n "${ID}" ]   # check:identity-present
}

identity_failed() { # STATUS: fixed diagnostic only; neither malformed material nor identity fields are reflected.
  save "${ST}/identity.failed" invalid && sync -f "${ST}/identity.failed" || exit 0
  reply "$1" failed null 'identity record invalid'
  return 1
}

check_identity() {
  local bound phase=before disks
  [ ! -e "${ST}/identity.failed" ] || { reply refused failed null 'identity record invalid'; return 1; }   # check:identity-final
  if [ ! -e "${ST}/identity.json" ]; then
    [ ! -e "${ST}/identity.cleaned" ] || { identity_failed refused; return 1; }   # check:identity-no-rebind
    [ "${E_CMD}" = probe ] || { reply refused failed null 'first command must be probe'; return 1; }   # check:identity-first-probe
    read_identity before || { identity_failed error; return 1; }   # check:identity-bind
    disks=$(lsblk -dn -o TYPE 2> /dev/null) || { identity_failed error; return 1; }
    [ "$(grep -cx disk <<< "${disks}")" = 1 ] || { identity_failed error; return 1; }   # check:identity-no-scratch
    (umask 077; save "${ST}/identity.json" "${ID}") && sync -f "${ST}/identity.json" || exit 0
  else
    bound=$(cat "${ST}/identity.json" 2> /dev/null) || { identity_failed refused; return 1; }
    [ ! -e "${ST}/identity.cleaned" ] || phase=after
    read_identity "${phase}" || { identity_failed refused; return 1; }   # check:identity-reread
    [ "${phase}" = after ] || [ "${ID}" = "${bound}" ] || { identity_failed refused; return 1; }   # check:identity-unchanged
    ID=${bound}
  fi
  IFS=$'\t' read -r I_VM I_RID I_GEN < <(jq -r '[.vm_id, .reservation_id, .lease_generation] | @tsv' <<< "${ID}")
  [ "${E_VM}" = "${I_VM}" ] || { reply refused "$(current_state)" null 'refused: vm_id differs from identity'; return 1; }   # check:cmd-vm-id
  [ "${E_RID}" = "${I_RID}" ] || { reply refused "$(current_state)" null 'refused: reservation_id differs from identity'; return 1; }   # check:cmd-reservation
  [ "${E_GEN}" = "${I_GEN}" ] || { reply refused "$(current_state)" null 'refused: another lease generation'; return 1; }   # check:cmd-generation
}

# --- the runner ------------------------------------------------------------------------------------------------------
# RS: none (never started), running, exited (RX its exit code), lost (gone without an exit record).
runner_state() {
  local pid start
  RS=none; RX=null
  if [ -f "${ST}/runner.exit" ]; then
    RS=exited; RX=$(head -c 12 "${ST}/runner.exit")
    [[ ${RX} =~ ^[0-9]{1,3}$ ]] || RX=null
  elif [ -f "${ST}/runner.pid" ]; then
    read -r pid start < "${ST}/runner.pid"
    RS=lost
    [[ ${pid:-} =~ ^[0-9]+$ && -n ${start:-} && "$(proc_start "${pid}")" == "${start}" ]] || return 0   # check:runner-pid-reuse
    RS=running
  fi
}

# What the guest is doing now, for replies that report no command-specific state (refusals included).
current_state() {
  [ ! -e "${ST}/identity.failed" ] || { printf failed; return; }
  [ -e "${ST}/firstboot.done" ] || { printf booting; return; }
  runner_state
  case "${RS}" in
    none) if grep -qx deliver_registration "${ST}/shots" 2> /dev/null; then printf registered; else printf ready; fi ;;
    running) if pgrep -x Runner.Worker > /dev/null 2>&1; then printf busy; else printf listening; fi ;;
    exited) if [ "${RX}" = 0 ]; then printf job_done; else printf failed; fi ;;
    *) printf failed ;;
  esac
}

# The job's environment: what /etc/default/locale and /etc/environment give a login (pam_env's KEY=VALUE, one pair of
# surrounding quotes removed), the job user's identity, and the compile cache's variables. Nothing else is inherited, and
# no tool path is prepended (images/ubuntu-24.04/INTEGRATION.md, P15).
load_env() { # FILE
  local line k v
  [ -r "$1" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    [[ ${line} =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    k=${BASH_REMATCH[2]}; v=${BASH_REMATCH[3]}
    if [[ ${v} =~ ^\"(.*)\"$ || ${v} =~ ^\'(.*)\'$ ]]; then v=${BASH_REMATCH[1]}; fi
    export "${k}=${v}"
  done < "$1"
}
runner_env() {
  local v
  while IFS= read -r v; do [ "${v}" = PATH ] || unset "${v}"; done < <(compgen -e)   # check:launch-env-clear (PATH is set below)
  export HOME="/home/${JOB_USER}" USER="${JOB_USER}" LOGNAME="${JOB_USER}" SHELL=/bin/bash PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  load_env "${S}/etc/default/locale"
  load_env "${S}/etc/environment"
  load_env "${ST}/runner.env"
}

# Runs inside aap-runner.scope, outside the ssh connection's cgroup, with the JIT config as the one line on stdin.
# Limits are the hosted runner's (65536 open files, 16 MiB stack) with no core dumps (set at the top); the runner runs as
# the job user in its own root, and its exit code is recorded for status and collect.
launch() {
  local jit='' pid rc=97 setpriv
  IFS= read -r -n 16385 jit || [ -n "${jit}" ] || jit=''
  setpriv=$(command -v setpriv) || setpriv=/usr/bin/setpriv   # resolved before the job's PATH replaces this one
  save "${ST}/runner.pid" "$$ $(proc_start "$$")"
  [[ ${jit} =~ ${JIT_RE} && ${#jit} -le 16384 && -x "${RR}/bin/Runner.Listener" ]] || { save "${ST}/runner.exit" "${rc}"; return 1; }   # check:launch-input
  { ulimit -n 65536 && ulimit -s 16384 && cd "${RR}"; } || { save "${ST}/runner.exit" "${rc}"; return 1; }
  (
    runner_env
    printf -v ACTIONS_RUNNER_INPUT_JITCONFIG '%s' "${jit}"
    export ACTIONS_RUNNER_INPUT_JITCONFIG
    exec "${setpriv}" --reuid="${JOB_USER}" --regid="${JOB_USER}" --init-groups -- "${RR}/bin/Runner.Listener" run
  ) < /dev/null &
  pid=$!
  jit=''
  wait "${pid}"
  rc=$?
  save "${ST}/runner.exit" "${rc}"
}

# --- commands --------------------------------------------------------------------------------------------------------
# Cloud-init caches raw user-data/config and an opaque obj.pkl under instances; remove every copy without parsing cache data.
scrub_bootstrap() {
  local c="${S}/var/lib/cloud" f
  identity_material || return 1
  rm -rf "${c}/seed" || return 1
  for f in "${MATERIAL[@]}" "${CACHE_MATERIAL[@]}"; do [ ! -e "${f}" ] && [ ! -L "${f}" ] || rm -f "${f}" || return 1; done   # check:identity-cache-cleanup
  identity_material && [ "${#MATERIAL[@]}" = 0 ] && [ "${#CACHE_MATERIAL[@]}" = 0 ] || return 1
  save "${ST}/identity.cleaned" cleaned && sync -f "${ST}/identity.cleaned"
}

cmd_probe() {
  if [ -e "${ST}/firstboot.done" ]; then reply ok ready null 'first boot finished'
  elif [ -e "${ST}/firstboot.failed" ]; then reply error booting null "first boot failed at $(head -c 40 "${ST}/firstboot.failed")"
  else reply ok booting null 'first boot running'
  fi
}

# The registration goes from this process's memory into the launcher's stdin pipe (printf is a builtin: no command line),
# and from there into the runner's environment. Bootstrap material is gone before the answer.
cmd_deliver() { # JIT
  [ -e "${ST}/firstboot.done" ] || { reply error booting null 'first boot has not finished'; return; }   # check:deliver-ready
  [[ ${#1} -eq ${E_LEN} && $1 =~ ${JIT_RE} ]] || { reply error ready null 'the payload is not an encoded JIT config'; return; }   # check:deliver-shape
  scrub_bootstrap || { reply error ready null 'the seed copies could not be removed'; return; }   # check:deliver-scrub
  # Neither side keeps the agent's lock (fd 9) or the connection's stdout and stderr.
  { printf '%s\n' "$1"; } 2> /dev/null 9>&- | setsid systemd-run --scope --quiet --collect --unit=aap-runner -- /bin/bash "${SELF}" launch > /dev/null 2>&1 9>&- &
  reply ok registered null 'bootstrap material removed; registration handed to the runner'
}

cmd_start() {
  local i
  grep -qx deliver_registration "${ST}/shots" 2> /dev/null || { reply error ready null 'no registration was delivered'; return; }   # check:start-delivered
  for ((i = 0; i < START_WAIT; i++)); do
    runner_state
    [ "${RS}" = none ] || break
    sleep 1
  done
  [ "${RS}" = running ] || { reply error failed "${RX}" "the runner is not running (${RS})"; return; }   # check:start-running
  reply ok "$(current_state)" null 'runner started from its environment'
}

cmd_status() { # status | collect
  local state code diag cache
  runner_state
  state=$(current_state)
  code=${RX}
  case "${RS}" in
    running) diag='runner running' ;;
    exited) diag="runner exited ${RX}" ;;
    lost) diag='runner ended without an exit record' ;;
    *) diag='no runner was started'; state=failed ;;
  esac
  if [ "$1" = collect ]; then
    cache=unknown
    [ ! -f "${CJ}/state/config.json" ] ||
      cache=$(timeout 20 runuser -u "${JOB_USER}" -- "${ZCI}/aap-zccache.sh" state "${CJ}" 2> /dev/null | jq -r '.state // "unknown"' 2> /dev/null | head -c 20)
    [[ ${cache} =~ ^[a-z]+$ ]] || cache=unknown
    diag+="; cache ${cache}"
  fi
  reply ok "${state}" "${code}" "${diag}"
}

cmd_shutdown() {
  systemd-run --quiet --on-active=2 /bin/systemctl poweroff > /dev/null 2>&1 9>&-
  reply ok shutting_down null 'powering off'
}

serve() {
  local line last exp now good marks payload=''
  IFS= read -r -n 1028 line || [ -n "${line}" ] || exit 0
  line=${line#$'\xef\xbb\xbf'}
  [ "${#line}" -le 1024 ] || exit 0   # check:cmd-line-length
  parse_envelope "${line}" || exit 0
  [ "${E_LEN}" = 0 ] || payload=$(head -c "${E_LEN}")
  { mkdir -p "${ST}" && chmod 0700 "${ST}"; } || exit 0
  exec 9> "${ST}/lock"
  flock -w 20 9 || exit 0
  # Bind from the offline record, then verify identity and phased presence before EVERY command (replays included).
  check_identity || exit 0
  # Sequence, nonce, one-shot, expiry and payload guards are unchanged by revision 2.
  last=$(cat "${ST}/seq" 2> /dev/null) || last=0
  [[ ${last} =~ ^[0-9]+$ ]] || last=2147483647
  [ "${E_SEQ}" -gt "${last}" ] || { reply refused "$(current_state)" null 'refused: seq not above the last accepted one'; exit 0; }   # check:cmd-seq
  ! grep -qx "${E_NONCE}" "${ST}/nonces" 2> /dev/null || { reply refused "$(current_state)" null 'refused: nonce seen before'; exit 0; }   # check:cmd-nonce
  [[ ${ONE_SHOT} != *" ${E_CMD} "* ]] || ! grep -qx "${E_CMD}" "${ST}/shots" 2> /dev/null || { reply refused "$(current_state)" null "refused: ${E_CMD} already ran"; exit 0; }   # check:cmd-one-shot
  exp=$(date -u -d "${E_EXP}" +%s 2> /dev/null) || exp=0
  now=$(date -u +%s)
  [ "${exp}" -ge "${now}" ] || { reply refused "$(current_state)" null 'refused: expired'; exit 0; }   # check:cmd-expired
  if [ "${E_CMD}" = deliver_registration ]; then good=$((E_LEN > 0)); else good=$((E_LEN == 0)); fi
  [ "${good}" = 1 ] || { reply refused "$(current_state)" null 'refused: payload_bytes does not fit the command'; exit 0; }   # check:cmd-payload
  # Accepted: the marks move before the work, so a reply lost after this point leaves a gap, never a false refusal. A mark
  # that cannot be written and flushed (a full or broken state file system) stops here: the command does not run and gets
  # no reply (a failed guest), so it can never run again later under an old seq or without its one-shot mark.
  marks=1
  save "${ST}/seq" "${E_SEQ}" || marks=0
  printf '%s\n' "${E_NONCE}" >> "${ST}/nonces" || marks=0
  [[ ${ONE_SHOT} != *" ${E_CMD} "* ]] || printf '%s\n' "${E_CMD}" >> "${ST}/shots" || marks=0
  sync -f "${ST}/seq" || marks=0
  [ "${marks}" = 1 ] || exit 0   # check:cmd-marks
  case "${E_CMD}" in
    probe) cmd_probe ;;
    deliver_registration) cmd_deliver "${payload}"; payload='' ;;
    start_runner) cmd_start ;;
    status|collect) cmd_status "${E_CMD}" ;;
    shutdown) cmd_shutdown ;;
  esac
  exit 0
}

# --- first boot ------------------------------------------------------------------------------------------------------
# The guest-to-host KVP item hv_kvp_daemon serves from pool 1: records of a 512-byte key and a 2048-byte value, NUL
# padded. An earlier record with the same key is replaced; other records are kept. The new pool is built beside the old
# one and renamed over it only when every step worked and it has exactly the records it should: a failed or short copy
# leaves the old pool as it was.
kvp_publish() { # KEY VALUE
  local tmp n=0 kept=0 i k size
  mkdir -p "${KVP_POOL%/*}" || return 1
  if [ -e "${KVP_POOL}" ]; then size=$(stat -c %s "${KVP_POOL}") || return 1; n=$((size / 2560)); fi
  tmp=$(mktemp "${KVP_POOL}.XXXXXX") || return 1
  for ((i = 0; i < n; i++)); do
    k=$(dd if="${KVP_POOL}" bs=2560 skip="${i}" count=1 status=none | head -c 512 | tr -d '\0')
    [ "${k}" != "$1" ] || continue
    dd if="${KVP_POOL}" bs=2560 skip="${i}" count=1 status=none >> "${tmp}" || { rm -f "${tmp}"; return 1; }
    kept=$((kept + 1))
  done
  { printf '%s' "$1"; head -c $((512 - ${#1})) /dev/zero; printf '%s' "$2"; head -c $((2048 - ${#2})) /dev/zero; } >> "${tmp}" || { rm -f "${tmp}"; return 1; }
  [ "$(stat -c %s "${tmp}" 2> /dev/null)" = $(((kept + 1) * 2560)) ] || { rm -f "${tmp}"; return 1; }   # check:kvp-complete
  { chmod 0644 "${tmp}" && mv -f "${tmp}" "${KVP_POOL}"; } || { rm -f "${tmp}"; return 1; }
}

# The host pins this key before its first command: exactly 'ssh-ed25519 <key>', nothing else ever goes into that item.
fb_host_key() {
  local a='' b=''
  read -r a b _ < "${S}/etc/ssh/ssh_host_ed25519_key.pub" || return 1
  [[ ${a} == ssh-ed25519 && ${b} =~ ^AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/]{48}$ ]] || return 1   # check:fb-host-key-shape
  systemctl is-active --quiet hv-kvp-daemon.service || return 1   # check:fb-kvp-daemon
  kvp_publish "${HOST_KEY_ITEM}" "${a} ${b}"
}

# The seed made exactly one account, runner (uid 1001, the hosted groups, passwordless sudo); no account has uid 1000.
fb_identity() {
  local line uid home groups g
  line=$(getent passwd "${JOB_USER}") || return 1
  IFS=: read -r _ _ uid _ _ home _ <<< "${line}"
  [ "${uid}" = 1001 ] && [ "${home}" = "/home/${JOB_USER}" ] || return 1   # check:fb-job-user
  ! getent passwd | awk -F: '$3 == 1000 { found = 1 } END { exit !found }' || return 1   # check:fb-no-uid-1000
  groups=" $(id -nG "${JOB_USER}") "
  for g in adm users docker systemd-journal; do [[ ${groups} == *" ${g} "* ]] || return 1; done   # check:fb-groups
  runuser -u "${JOB_USER}" -- sudo -n true > /dev/null 2>&1 || return 1   # check:fb-sudo
}

# The image has no snakeoil pair (P07 seal); PostgreSQL does not start without it. P07's verification runs the same.
fb_tls() {
  make-ssl-cert generate-default-snakeoil --force-overwrite || return 1
  [ -s "${S}/etc/ssl/private/ssl-cert-snakeoil.key" ] && [ -s "${S}/etc/ssl/certs/ssl-cert-snakeoil.pem" ] || return 1   # check:fb-tls
}

# As hosted provisioning runs them: each script directly through bash, in find's order, as root, after the job user exists
# and before any job. Any failure fails the step (P07's run_verify does the same; keep the two in step).
fb_post_generation() {
  local pg="${S}/imagegeneration/post-generation" f rc=0
  [ -d "${pg}" ] || return 1   # check:fb-postgen-folder
  while IFS= read -r -d '' f; do bash "${f}" || rc=1; done < <(find "${pg}" -mindepth 1 -maxdepth 1 -type f -name '*.sh' -print0)   # check:fb-postgen-exit
  return "${rc}"
}

fb_linger() { loginctl enable-linger "${JOB_USER}"; }

fb_docker() { systemctl start docker.service && systemctl is-active --quiet docker.service; }

# The overlay's runner, unregistered: no registration or credential file may come with the image.
fb_runner_root() {
  local f
  [ ! -L "${RR}" ] && [ -x "${RR}/bin/Runner.Listener" ] || return 1   # check:fb-runner-binary
  for f in .runner .credentials .credentials_rsaparams .env .path; do
    [ ! -e "${RR}/${f}" ] && [ ! -L "${RR}/${f}" ] || return 1   # check:fb-runner-unregistered
  done
  chown -R "${JOB_USER}:${JOB_USER}" "${RR}"
}

# The private compile cache (guests/cache/INTEGRATION.md, P15): the job root is the job user's, 0700; init runs as that
# user from a clean environment, and only the cache's own variables, as absolute paths, reach the runner. No overlay, or
# any cache problem, means every build runs directly: never a reason to fail the clone.
fb_cache() {
  local line
  rm -f "${ST}/runner.env"
  [ -x "${ZCI}/aap-zccache.sh" ] || return 0
  mkdir -p "${CJ}" && chmod 0700 "${CJ}" && chown "${JOB_USER}:${JOB_USER}" "${CJ}" || return 0
  runuser -u "${JOB_USER}" -- env -i PATH=/usr/bin:/bin "HOME=/home/${JOB_USER}" "${ZCI}/aap-zccache.sh" init "${ZCI}" "${CJ}" "${CACHE_BUDGET}" > /dev/null 2>&1 || return 0
  while IFS= read -r line; do
    [[ ${line} =~ ^(AAP_ZC_STATE|RUSTC_WRAPPER|CMAKE_C_COMPILER_LAUNCHER|CMAKE_CXX_COMPILER_LAUNCHER)=/[A-Za-z0-9_./-]*$ ]] || continue   # check:fb-cache-env
    printf '%s\n' "${line}"
  done < <(head -c 4096 "${CJ}/state/runner.env" 2> /dev/null) > "${ST}/runner.env"
}

# Once per clone, even across a crash or a reboot: /imagegeneration is writable by everyone once a job ran, so the
# post-generation scripts must never run again. A failed or interrupted first boot stays failed; probe reports it.
firstboot() {
  local step
  { mkdir -p "${ST}" && chmod 0700 "${ST}"; } || exit 1
  [ ! -e "${ST}/firstboot.done" ] || exit 0
  [ ! -e "${ST}/firstboot.started" ] || { [ -e "${ST}/firstboot.failed" ] || save "${ST}/firstboot.failed" interrupted; exit 1; }   # check:fb-once
  : > "${ST}/firstboot.started"
  for step in host_key identity tls post_generation linger docker runner_root cache; do
    echo "aap-guest firstboot: ${step}"
    "fb_${step}" || { save "${ST}/firstboot.failed" "${step}"; echo "aap-guest firstboot: ${step} failed"; exit 1; }
  done
  : > "${ST}/firstboot.done"
}

case "${1:-}" in
  '') serve ;;
  firstboot) firstboot ;;
  launch) launch ;;
  *) exit 2 ;;
esac
