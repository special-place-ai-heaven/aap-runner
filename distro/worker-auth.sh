#!/bin/bash -p
# Registration broker for the VM runner profiles. Installed in the aap-runner
# distro as /usr/local/sbin/aap-runner-broker (root 0755) beside the manager.
# Contract: parity/contracts/broker.md, version 1. The supervisor runs
#   wsl.exe -d aap-runner -u root --exec /usr/local/sbin/aap-runner-broker
# with no arguments: one request JSON on stdin (at most 4096 bytes), one
# response JSON on stdout (at most 20 KiB), exit 0. Exit 2 means an argument,
# or stdin that is not one JSON object with a request kind and a lease id.
# Every other failure (config, key, lock, a ledger write, a tool) exits 1: the
# exit trap maps any other status to 1. Neither prints anything on stdout, and
# the supervisor treats both as an unavailable broker.
#
# Requests carry ids, numbers and enums only. The runner name, labels, group
# and work folder are derived here; no path, command, label, name, runner id or
# URL is ever taken from the caller.
#
# Secrets. The App key is used only through the installed manager's own
# load_config, check_key and mint_installation_token (sourced, not copied), so
# the JWT is signed exactly as the manager signs it. Every bearer token
# reaches curl on stdin (auth_header, -H @-). The JIT config comes from curl
# through a pipe into this process and leaves it only in the stdout response:
# printf is a builtin and jq reads it from a pipe, so it is never in argv, a
# here-string, a temp file, the ledger, the audit log or stderr.
#
# -p: BASH_ENV, ENV, SHELLOPTS, BASHOPTS, CDPATH, GLOBIGNORE and exported
# functions from the caller's environment are ignored.
set -euo pipefail
umask 077
# The token and the JIT config live in this process's memory: no core file.
ulimit -c 0
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# No ~/.jq or ~/.curlrc of whoever HOME names; curl also always gets -q.
export HOME=/nonexistent
unset CURL_HOME XDG_CONFIG_HOME

BROKER_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The distro installs the manager as aap-runner-manager beside this file; the
# repository keeps it as manager.sh (the tests source that one).
if [[ -f "${BROKER_HOME}/aap-runner-manager" ]]; then
  # shellcheck source=manager.sh
  source "${BROKER_HOME}/aap-runner-manager"
else
  # shellcheck source=manager.sh
  source "${BROKER_HOME}/manager.sh"
fi
# The manager honours AAP_MANAGER_CONF for the helper's --check-limits. The
# broker always reads the installed file.
# shellcheck disable=SC2034  # read by the manager's load_config
CONFIG_PATH=/etc/aap-runner/manager.conf

# Every curl call, the manager's token mint included, starts with -q, so no
# .curlrc is read.
curl() {
  command curl -q "$@"
}

BROKER_DIR=/var/lib/aap-runner/broker
AUDIT_LOG=/var/log/aap-runner/broker-audit.jsonl
AUDIT_MAX_BYTES=5242880
REQUEST_MAX_BYTES=4096
SKEW_SECONDS=300
LEASE_SECONDS=600
MAX_OPEN_LEASES=5
LOCK_WAIT_SECONDS=20
SWEEP_SECONDS=10
# The supervisor kills wsl.exe after 60 s. No GitHub call starts unless it can
# end within this many seconds of the run's start (curl's --max-time).
RUN_LIMIT_SECONDS=55
NONCE_KEEP_SECONDS=3600
JIT_MAX_BYTES=16384
GITHUB_API=https://api.github.com
JIT_RE='^[A-Za-z0-9+/=_-]+$'
ID_RE='^[1-9][0-9]{0,15}$'

TOKEN=""
REQ=""
RUN_START=0
BAD_INPUT=0
V="" KIND="" LEASE_ID="" RES_ID="" GEN="" SLOT="" PROFILE="" IMAGE_GEN="" NONCE="" ISSUED_AT=""
ISSUED_EPOCH=0
# The lease an audit line describes: the request's, or one loaded from the ledger.
L_RES="-" L_GEN="-" L_PROFILE="-" L_IMAGE="-"
LS="" LEXP="" LRID="" LNAME=""
P_LETTER="" P_LABELS=""

# One request, checked like broker.schema.json: exactly the kind's keys, each
# id, number and enum in its pattern or range. Strings must be printable ASCII
# so a pattern's $ cannot match before a trailing newline. Prints one tab
# separated line: verdict (bad, malformed, unknown_profile, ok), kind, then the
# fields, "-" where a field is absent or invalid.
JQ_REQUEST='
def printable: type == "string" and (explode | all(. > 32 and . < 127));
def pat($re): printable and test($re);
def num($max): type == "number" and (tostring | test("^[1-9][0-9]*$")) and . <= $max;
def opt(f): if f then tostring else "-" end;
def fields: {
  lease_id: (.lease_id | opt(pat("^l-[0-9a-f]{32}$"))),
  reservation_id: (.reservation_id | opt(pat("^r-[0-9a-f]{16}$"))),
  lease_generation: (.lease_generation | opt(num(999999999))),
  slot: (.slot | opt(num(5))),
  profile: (.profile | opt(. == "win25-vs2026-x64" or . == "ubuntu-24.04-x64")),
  image_generation: (.image_generation
    | opt(pat("^(win25-vs2026-x64|ubuntu-24[.]04-x64)/[0-9]{8}[.][0-9]+[.][0-9]+-aap[.][0-9]+$"))),
  nonce: (.nonce | opt(pat("^[0-9a-f]{32}$"))),
  issued_at: (.issued_at | opt(pat("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
};
def want($k):
  if $k == "lease_request" then
    ["schema", "kind", "lease_id", "reservation_id", "lease_generation", "slot", "profile",
     "image_generation", "nonce", "issued_at"]
  else ["schema", "kind", "lease_id", "nonce", "issued_at"] end;
if length != 1 or (.[0] | type) != "object" then ["bad"]
else
  .[0] as $r
  | ($r.kind | if . == "lease_request" or . == "release_request" or . == "status_request"
      then . else "-" end) as $k
  | ($r | fields) as $f
  | if $k == "-" or $f.lease_id == "-" then ["bad"]
    else
      want($k) as $w
      | ($r | keys) as $have
      | (if ($have - $w | length) > 0 or ($w - $have | length) > 0 or $r.schema != 1 then "malformed"
         elif $k == "lease_request" and ($r.profile | type) == "string" and $f.profile == "-"
           then "unknown_profile"
         elif [$w[] | select(. != "schema" and . != "kind") | $f[.]] | any(. == "-") then "malformed"
         elif $k == "lease_request" and ($f.image_generation | startswith($f.profile + "/") | not)
           then "malformed"
         else "ok" end) as $v
      | [$v, $k, $f.lease_id, $f.reservation_id, $f.lease_generation, $f.slot, $f.profile,
         $f.image_generation, $f.nonce, $f.issued_at]
    end
end
| @tsv'

# A GitHub runner object as "found ID STATUS BUSY", or an error when GitHub
# answered something this broker does not understand.
JQ_RUNNER='def runner_line:
  if (.id | type) == "number" and (.status == "online" or .status == "offline")
    and (.busy | type) == "boolean"
  then ["found", (.id | tostring), .status, (.busy | tostring)] | join(" ")
  else "error github_error" end;'

utc_now() {
  date -u +%s
}

die() {
  echo "aap-runner-broker: $*" >&2
  exit 1
}

# True while a call that takes at most SECONDS still ends within the run limit.
room_for() {
  ((RUN_START + RUN_LIMIT_SECONDS - $(now_s) > $1))
}

iso_of() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

# Root-only profile table (broker.md; owner decision 2026-10-19). A request
# names a profile; the labels and the runner-name letter come from here.
set_profile() {
  case "$1" in
    win25-vs2026-x64) P_LETTER=w P_LABELS='"self-hosted","Windows","X64","aap-win25-vs2026"' ;;
    ubuntu-24.04-x64) P_LETTER=l P_LABELS='"self-hosted","Linux","X64","aap-ubuntu-24.04"' ;;
    *) return 1 ;;
  esac
}

# stdin, at most REQUEST_MAX_BYTES, read within 10 s. A NUL becomes \x01 so
# the shell keeps every byte and jq refuses the document; the trailing x keeps
# trailing newlines in the count.
read_request() {
  local raw
  raw=$(timeout 10 head -c "$((REQUEST_MAX_BYTES + 1))" | tr '\000' '\001'; printf x)
  REQ=${raw%x}
  ((${#REQ} <= REQUEST_MAX_BYTES))
}

parse_request() {
  local line
  line=$(printf '%s' "${REQ}" | jq -r -s "${JQ_REQUEST}" 2>/dev/null) || line=bad
  IFS=$'\t' read -r V KIND LEASE_ID RES_ID GEN SLOT PROFILE IMAGE_GEN NONCE ISSUED_AT <<< "${line:-bad}"
  # The lease id becomes a file name and the slot a file name: check them here
  # too, where they are used.
  [[ "${V}" == bad || "${LEASE_ID}" =~ ^l-[0-9a-f]{32}$ ]] || V=bad
  [[ "${V}" != ok ]] && return 0
  if [[ "${KIND}" == lease_request ]] \
    && ! [[ "${SLOT}" =~ ^[1-5]$ && "${GEN}" =~ ^[1-9][0-9]{0,8}$ && "${RES_ID}" =~ ^r-[0-9a-f]{16}$ ]]; then
    V=malformed
    return 0
  fi
  ISSUED_EPOCH=$(date -u -d "${ISSUED_AT}" +%s 2>/dev/null) || V=malformed
  return 0
}

# ---- GitHub ----------------------------------------------------------------

# gh_api METHOD PATH [curl args...]: the body, a newline, then the HTTP status
# (000 when curl itself failed). The token reaches curl on stdin, never argv.
gh_api() {
  local method=$1 path=$2 out
  shift 2
  if ! room_for 10; then
    printf '\n000'
    return 0
  fi
  out=$(auth_header "${TOKEN}" | curl --silent --show-error --connect-timeout 5 --max-time 10 \
    -X "${method}" -H @- -H "Accept: application/vnd.github+json" -w '\n%{http_code}' "$@" \
    "${GITHUB_API}${path}") || out=$'\n000'
  printf '%s' "${out}"
}

# CODE BODY: rate_limited for 429 and a rate-limit 403, else github_error.
gh_reason() {
  if [[ "$1" == 429 ]]; then
    echo rate_limited
  elif [[ "$1" == 403 ]] && printf '%s' "$2" \
    | jq -e '(.message // "") | ascii_downcase | contains("rate limit")' >/dev/null 2>&1; then
    echo rate_limited
  else
    echo github_error
  fi
}

# One installation token per run, minted by the manager's own code.
mint_token() {
  [[ -z "${TOKEN}" ]] || return 0
  room_for 15 || return 1
  TOKEN=$(mint_installation_token) || TOKEN=""
  [[ -n "${TOKEN}" ]]
}

# "ok ID" or "error REASON". The id of the configured group (aap-crrr), cached
# in the state directory; a JIT 404 or 422 drops the cache.
runner_group_id() {
  local cache="${BROKER_DIR}/group-id" id="" resp code
  { read -r id < "${cache}"; } 2>/dev/null || id=""
  if [[ "${id}" =~ ${ID_RE} ]]; then
    echo "ok ${id}"
    return 0
  fi
  # ponytail: first page of 100 groups only; page when an org has more.
  resp=$(gh_api GET "/orgs/${AAP_GITHUB_ORG}/actions/runner-groups" -G --data-urlencode "per_page=100")
  code=${resp##*$'\n'}
  resp=${resp%$'\n'*}
  if [[ "${code}" != 200 ]]; then
    echo "error $(gh_reason "${code}" "${resp}")"
    return 0
  fi
  id=$(printf '%s' "${resp}" | jq -r --arg g "${AAP_RUNNER_GROUP}" \
    '[.runner_groups[]? | select(.name == $g) | .id | select(type == "number")][0] // empty' 2>/dev/null) || id=""
  if ! [[ "${id}" =~ ${ID_RE} ]]; then
    echo "error github_error"
    return 0
  fi
  { printf '%s\n' "${id}" > "${cache}.tmp" && mv -f "${cache}.tmp" "${cache}"; } 2>/dev/null \
    || rm -f "${cache}.tmp"
  echo "ok ${id}"
}

# "absent", "found ID STATUS BUSY" or "error REASON" for the runner with
# exactly this name.
runner_by_name() {
  local resp code
  resp=$(gh_api GET "/orgs/${AAP_GITHUB_ORG}/actions/runners" -G --data-urlencode "name=$1")
  code=${resp##*$'\n'}
  resp=${resp%$'\n'*}
  if [[ "${code}" != 200 ]]; then
    echo "error $(gh_reason "${code}" "${resp}")"
    return 0
  fi
  printf '%s' "${resp}" | jq -r --arg n "$1" "${JQ_RUNNER}"'
    if (.runners | type) != "array" then "error github_error"
    else ([.runners[] | select(.name == $n)][0] // null)
      | if . == null then "absent" else runner_line end
    end' 2>/dev/null || echo "error github_error"
}

# Same answers for one runner id.
runner_by_id() {
  local resp code
  if ! [[ "$1" =~ ${ID_RE} ]]; then
    echo "error github_error"
    return 0
  fi
  resp=$(gh_api GET "/orgs/${AAP_GITHUB_ORG}/actions/runners/$1")
  code=${resp##*$'\n'}
  resp=${resp%$'\n'*}
  case "${code}" in
    200) printf '%s' "${resp}" | jq -r "${JQ_RUNNER} runner_line" 2>/dev/null || echo "error github_error" ;;
    404) echo absent ;;
    *) echo "error $(gh_reason "${code}" "${resp}")" ;;
  esac
}

# "deregistered" (204), "already_gone" (404) or "error REASON".
delete_runner() {
  local resp code
  if ! [[ "$1" =~ ${ID_RE} ]]; then
    echo "error github_error"
    return 0
  fi
  resp=$(gh_api DELETE "/orgs/${AAP_GITHUB_ORG}/actions/runners/$1")
  code=${resp##*$'\n'}
  case "${code}" in
    204) echo deregistered ;;
    404) echo already_gone ;;
    *) echo "error $(gh_reason "${code}" "${resp%$'\n'*}")" ;;
  esac
}

# ---- ledger and audit ------------------------------------------------------
# leases/<lease_id>.json, root 0600, never holds a JIT config, token, JWT or a
# hash of one. open/<lease_id> marks a lease that is pending or issued, so the
# outstanding count and the sweep never read closed leases. slots/<slot> holds
# the highest lease_generation leased in that slot. Every read and write runs
# under the flock taken in broker_run. A write that fails leaves the file as it
# was and ends the run with exit 1 and no response.

ledger_update() {
  local file="${BROKER_DIR}/leases/$1.json"
  shift
  if ! { jq -c "$@" "${file}" > "${file}.tmp" && [[ -s "${file}.tmp" ]] && mv -f "${file}.tmp" "${file}"; }; then
    rm -f "${file}.tmp"
    die "the lease ledger could not be written"
  fi
}

# LEASE_ID: loads LS, LEXP, LRID, LNAME and the L_* audit fields.
ledger_read() {
  local line
  line=$(jq -r '[.state, .expires_epoch, .runner_id, .runner_name, .reservation_id,
      .lease_generation, .profile, .image_generation]
    | map(if . == null then "-" else tostring end) | @tsv' "${BROKER_DIR}/leases/$1.json" 2>/dev/null) || return 1
  IFS=$'\t' read -r LS LEXP LRID LNAME L_RES L_GEN L_PROFILE L_IMAGE <<< "${line}"
  [[ "${LS}" =~ ^(pending|issued|refused|released)$ && "${LEXP}" =~ ^[0-9]+$ ]]
}

# LEASE_ID STATE OUTCOME: the ledger first, then the marker, so a crash in
# between leaves a stale marker that open_leases drops.
close_lease() {
  ledger_update "$1" --arg s "$2" --arg o "$3" --arg at "$(iso_of "$(utc_now)")" \
    '.state = $s | .outcome = $o | .closed_at = $at'
  rm -f "${BROKER_DIR}/open/$1"
}

# Lease ids that are pending or issued.
open_leases() {
  local f id state
  for f in "${BROKER_DIR}"/open/l-*; do
    [[ -e "${f}" ]] || continue
    id=${f##*/}
    [[ "${id}" =~ ^l-[0-9a-f]{32}$ ]] || continue
    state=$(jq -r '.state' "${BROKER_DIR}/leases/${id}.json" 2>/dev/null) || state=""
    case "${state}" in
      pending | issued) printf '%s\n' "${id}" ;;
      *) rm -f "${f}" ;;
    esac
  done
}

# Refuses a nonce this lease has already seen, records it otherwise. Entries
# older than an hour are dropped: a request that old fails the clock check.
nonce_add() {
  local now rc=0
  jq -e --arg n "${NONCE}" 'any(.nonces[]?; .n == $n)' \
    "${BROKER_DIR}/leases/${LEASE_ID}.json" >/dev/null 2>&1 || rc=$?
  case "${rc}" in
    0) return 1 ;;
    1) ;;
    *) die "the lease ledger could not be read" ;;
  esac
  now=$(utc_now)
  ledger_update "${LEASE_ID}" --arg n "${NONCE}" --argjson t "${now}" \
    --argjson keep "$((now - NONCE_KEEP_SECONDS))" \
    '.nonces = ([.nonces[]? | select(.t >= $keep)] + [{n: $n, t: $t}])'
}

fresh() {
  local now
  now=$(utc_now)
  ((ISSUED_EPOCH <= now + SKEW_SECONDS && ISSUED_EPOCH >= now - SKEW_SECONDS))
}

# OP LEASE_ID OUTCOME REASON RUNNER_ID RUNNER_NAME; the reservation, generation,
# profile and image come from L_*. Exactly the schema's audit fields, "-" = null.
audit() {
  local line
  line=$(jq -nc --arg at "$(iso_of "$(utc_now)")" --arg op "$1" --arg lid "$2" --arg out "$3" \
    --arg why "$4" --arg runner "$5" --arg name "$6" --arg rid "${L_RES}" --arg gen "${L_GEN}" \
    --arg prof "${L_PROFILE}" --arg img "${L_IMAGE}" '
    def opt: if . == "-" or . == "" then null else . end;
    def num: opt | if . == null then null else tonumber end;
    {schema: 1, kind: "audit", at: $at, op: $op, lease_id: $lid,
     reservation_id: ($rid | opt), lease_generation: ($gen | num), profile: ($prof | opt),
     image_generation: ($img | opt), outcome: $out, reason: $why,
     runner_id: ($runner | num), runner_name: ($name | opt)}')
  if [[ -f "${AUDIT_LOG}" ]] && (($(stat -c %s "${AUDIT_LOG}") >= AUDIT_MAX_BYTES)); then
    mv -f "${AUDIT_LOG}" "${AUDIT_LOG}.1"
  fi
  printf '%s\n' "${line}" >> "${AUDIT_LOG}"
}

# ---- responses -------------------------------------------------------------
# Every value printed below is a checked id, enum, number or time; the JIT
# config matched JIT_RE. Nothing needs JSON escaping.

lease_refused() {
  audit lease "${LEASE_ID}" refused "$1" - "$2"
  printf '{"schema":1,"kind":"lease_response","lease_id":"%s","result":"refused","reason":"%s","runner_id":null,"runner_name":null,"expires_at":null,"jit_config":null}\n' \
    "${LEASE_ID}" "$1"
}

# REASON NAME: the lease is closed; no runner exists for it.
lease_close() {
  close_lease "${LEASE_ID}" refused "$1"
  lease_refused "$1" "$2"
}

release_answer() {
  audit release "${LEASE_ID}" "$1" "$2" "$3" "$4"
  printf '{"schema":1,"kind":"release_response","lease_id":"%s","result":"%s","reason":"%s"}\n' \
    "${LEASE_ID}" "$1" "$2"
}

status_ok() {
  audit status "${LEASE_ID}" "$1" ok "$3" "$4"
  printf '{"schema":1,"kind":"status_response","lease_id":"%s","result":"ok","reason":"ok","runner":{"status":"%s","busy":%s}}\n' \
    "${LEASE_ID}" "$1" "$2"
}

status_refused() {
  audit status "${LEASE_ID}" refused "$1" "$2" "$3"
  printf '{"schema":1,"kind":"status_response","lease_id":"%s","result":"refused","reason":"%s","runner":null}\n' \
    "${LEASE_ID}" "$1"
}

# malformed or unknown_profile, before any ledger or GitHub access.
refuse_request() {
  case "${KIND}" in
    lease_request)
      L_RES=${RES_ID:--} L_GEN=${GEN:--} L_PROFILE=${PROFILE:--} L_IMAGE=${IMAGE_GEN:--}
      lease_refused "$1" -
      ;;
    release_request) release_answer refused "$1" - - ;;
    status_request) status_refused "$1" - - ;;
  esac
}

# ---- sweep -----------------------------------------------------------------
# Leases past expires_at (the delivery deadline) that are not released. Only
# two cases are acted on: a lease still pending (never confirmed issued, so
# never delivered; its runner is found by the derived name), or a runner
# GitHub reports offline and not busy. A runner GitHub reports busy or online
# is never touched; its lease waits for the supervisor's release_request. A
# runner GitHub no longer lists closes its lease. No GitHub call starts after
# SWEEP_SECONDS.
sweep() {
  local id now stop r fid fstatus fbusy
  local -a ids=()
  mapfile -t ids < <(open_leases)
  ((${#ids[@]} > 0)) || return 0
  now=$(utc_now)
  stop=$(($(now_s) + SWEEP_SECONDS))
  for id in "${ids[@]}"; do
    ledger_read "${id}" || continue
    ((now > LEXP)) || continue
    (($(now_s) < stop)) || break
    mint_token || return 0
    (($(now_s) < stop)) || break
    if [[ "${LS}" == pending ]]; then
      r=$(runner_by_name "${LNAME}")
    else
      r=$(runner_by_id "${LRID}")
    fi
    case "${r}" in
      absent)
        close_lease "${id}" released already_gone
        audit expire "${id}" already_gone ok "${LRID}" "${LNAME}"
        ;;
      "found "*)
        read -r _ fid fstatus fbusy <<< "${r}"
        [[ "${fstatus}" == offline && "${fbusy}" == false ]] || continue
        (($(now_s) < stop)) || break
        r=$(delete_runner "${fid}")
        case "${r}" in
          deregistered | already_gone)
            close_lease "${id}" released "${r}"
            audit expire "${id}" "${r}" ok "${fid}" "${LNAME}"
            ;;
          *) audit expire "${id}" retry "${r#error }" "${fid}" "${LNAME}" ;;
        esac
        ;;
      *) audit expire "${id}" retry "${r#error }" "${LRID}" "${LNAME}" ;;
    esac
  done
}

# ---- requests --------------------------------------------------------------

# GitHub may have created the runner: delete it before answering. Only a
# delete closes the lease. A runner that is not listed (yet) proves nothing,
# since GitHub may still finish the create: the lease stays pending and open,
# and the supervisor's release_request or the sweep looks again by name.
lease_abandon() {
  local r id
  if [[ "$3" =~ ${ID_RE} ]]; then
    r=$(delete_runner "$3")
  else
    r=$(runner_by_name "$2")
    if [[ "${r}" == "found "* ]]; then
      read -r _ id _ _ <<< "${r}"
      r=$(delete_runner "${id}")
    fi
  fi
  case "${r}" in
    deregistered | already_gone) lease_close "$1" "$2" ;;
    *) lease_refused "$1" "$2" ;;
  esac
}

handle_lease() {
  local now seen=0 verdict=ok state name expires rec r gid body resp code meta rid named jit
  local lease_file="${BROKER_DIR}/leases/${LEASE_ID}.json" slot_file="${BROKER_DIR}/slots/${SLOT}"
  L_RES=${RES_ID} L_GEN=${GEN} L_PROFILE=${PROFILE} L_IMAGE=${IMAGE_GEN}
  set_profile "${PROFILE}"
  # The VM name: aap-<w|l>-<slot>-<lease_generation>-<first 8 hex of the reservation>.
  name="aap-${P_LETTER}-${SLOT}-${GEN}-${RES_ID:2:8}"
  now=$(utc_now)
  if ! fresh; then
    verdict=clock_skew
  else
    # One lease per slot generation: a lower or equal generation is stale, so a
    # runner name is never leased twice. No slot file is generation 0; a slot
    # file that exists but holds no generation refuses the slot.
    if [[ -e "${slot_file}" || -L "${slot_file}" ]]; then
      seen=$(cat "${slot_file}" 2>/dev/null) || seen=""
      [[ "${seen}" =~ ^[0-9]{1,9}$ ]] || seen=999999999
    fi
    if ((GEN <= 10#${seen})); then
      verdict=stale_generation
    elif (($(open_leases | wc -l) >= MAX_OPEN_LEASES)); then
      verdict=lease_limit
    fi
  fi
  state=pending
  [[ "${verdict}" == ok ]] || state=refused
  expires=$((now + LEASE_SECONDS))
  rec=$(jq -nc --arg lid "${LEASE_ID}" --arg rid "${RES_ID}" --argjson gen "${GEN}" \
    --argjson slot "${SLOT}" --arg prof "${PROFILE}" --arg img "${IMAGE_GEN}" --arg name "${name}" \
    --arg state "${state}" --arg why "${verdict}" --arg nonce "${NONCE}" --argjson now "${now}" \
    --argjson exp "${expires}" --arg created "$(iso_of "${now}")" --arg expires "$(iso_of "${expires}")" '
    {schema: 1, lease_id: $lid, reservation_id: $rid, lease_generation: $gen, slot: $slot,
     profile: $prof, image_generation: $img, runner_name: $name, runner_id: null, state: $state,
     outcome: $why, created_at: $created, expires_at: $expires, expires_epoch: $exp,
     nonces: [{n: $nonce, t: $now}]}')
  # The replay check: a lease id whose file exists, in any state, is refused
  # and the file is left as it is.
  if [[ -e "${lease_file}" || -L "${lease_file}" ]]; then
    lease_refused replay "${name}"
    return 0
  fi
  # The open marker before the lease file: a crash in between leaves a marker
  # that open_leases drops, never a pending lease the sweep cannot see.
  if [[ "${verdict}" == ok ]]; then
    : > "${BROKER_DIR}/open/${LEASE_ID}" || die "the lease ledger could not be written"
  fi
  # noclobber: O_CREAT|O_EXCL. A failed write leaves no lease file; nothing was
  # answered, so the lease id is not spent.
  if ! (set -C && printf '%s\n' "${rec}" > "${lease_file}") 2>/dev/null; then
    rm -f "${lease_file}"
    die "the lease ledger could not be written"
  fi
  if [[ "${verdict}" != ok ]]; then
    lease_refused "${verdict}" "${name}"
    return 0
  fi
  { printf '%s\n' "${GEN}" > "${slot_file}.tmp" && mv -f "${slot_file}.tmp" "${slot_file}"; } \
    || { rm -f "${slot_file}.tmp"; die "the slot generation could not be written"; }
  if ! mint_token; then
    lease_close github_error "${name}"
    return 0
  fi
  r=$(runner_group_id)
  if [[ "${r}" != "ok "* ]]; then
    lease_close "${r#error }" "${name}"
    return 0
  fi
  gid=${r#ok }
  body=$(printf '{"name":"%s","runner_group_id":%s,"labels":[%s],"work_folder":"_work"}' \
    "${name}" "${gid}" "${P_LABELS}")
  # No create starts unless its reply can arrive within the run limit; nothing
  # was created, so the lease closes.
  if ! room_for 10; then
    lease_close github_error "${name}"
    return 0
  fi
  resp=$(gh_api POST "/orgs/${AAP_GITHUB_ORG}/actions/runners/generate-jitconfig" \
    -H "Content-Type: application/json" --data "${body}")
  code=${resp##*$'\n'}
  resp=${resp%$'\n'*}
  case "${code}" in
    201)
      meta=$(printf '%s' "${resp}" | jq -r --arg n "${name}" \
        '[(.runner.id | if type == "number" then tostring else "-" end), (.runner.name == $n | tostring)]
         | join(" ")' 2>/dev/null) || meta="- false"
      jit=$(printf '%s' "${resp}" | jq -r '.encoded_jit_config | select(type == "string")' 2>/dev/null) || jit=""
      resp=""
      read -r rid named <<< "${meta}"
      [[ "${rid}" =~ ${ID_RE} ]] || rid=""
      if [[ -n "${rid}" && "${named}" == true ]] && ((rid <= 9007199254740991 && ${#jit} <= JIT_MAX_BYTES)) \
        && [[ "${jit}" =~ ${JIT_RE} ]]; then
        ledger_update "${LEASE_ID}" --argjson id "${rid}" '.state = "issued" | .runner_id = $id'
        audit lease "${LEASE_ID}" issued ok "${rid}" "${name}"
        printf '{"schema":1,"kind":"lease_response","lease_id":"%s","result":"issued","reason":"ok","runner_id":%s,"runner_name":"%s","expires_at":"%s","jit_config":"%s"}\n' \
          "${LEASE_ID}" "${rid}" "${name}" "$(iso_of "${expires}")" "${jit}"
        jit=""
        return 0
      fi
      jit=""
      lease_abandon github_error "${name}" "${rid}"
      ;;
    4[0-9][0-9])
      # GitHub refused (404, 409, 422, rate limit): no runner was created.
      [[ "${code}" != 404 && "${code}" != 422 ]] || rm -f "${BROKER_DIR}/group-id"
      lease_close "$(gh_reason "${code}" "${resp}")" "${name}"
      ;;
    *)
      # Timeout, server error or an unexpected status: a runner may exist.
      lease_abandon github_error "${name}" ""
      ;;
  esac
}

# Mandatory at every teardown. Deletes only the runner the ledger names: the
# recorded id, or for a lease still pending the runner with the derived name.
handle_release() {
  local r id
  L_RES=- L_GEN=- L_PROFILE=- L_IMAGE=-
  if ! ledger_read "${LEASE_ID}"; then
    release_answer refused not_found - -
    return 0
  fi
  if ! fresh; then
    release_answer refused clock_skew "${LRID}" "${LNAME}"
    return 0
  fi
  if ! nonce_add; then
    release_answer refused replay "${LRID}" "${LNAME}"
    return 0
  fi
  if [[ "${LS}" == released || "${LS}" == refused ]]; then
    release_answer already_gone ok "${LRID}" "${LNAME}"
    return 0
  fi
  if ! mint_token; then
    release_answer retry github_error "${LRID}" "${LNAME}"
    return 0
  fi
  if [[ "${LS}" == issued ]]; then
    r=$(delete_runner "${LRID}")
  else
    r=$(runner_by_name "${LNAME}")
    if [[ "${r}" == "found "* ]]; then
      read -r _ id _ _ <<< "${r}"
      LRID=${id}
      r=$(delete_runner "${id}")
    fi
  fi
  case "${r}" in
    absent | already_gone)
      # Until expires_at a pending lease's create may still finish at GitHub,
      # so a runner that is not listed is no proof yet.
      if [[ "${r}" == absent ]] && (($(utc_now) <= LEXP)); then
        release_answer retry github_error "${LRID}" "${LNAME}"
        return 0
      fi
      close_lease "${LEASE_ID}" released already_gone
      release_answer already_gone ok "${LRID}" "${LNAME}"
      ;;
    deregistered)
      close_lease "${LEASE_ID}" released deregistered
      release_answer deregistered ok "${LRID}" "${LNAME}"
      ;;
    *) release_answer retry "${r#error }" "${LRID}" "${LNAME}" ;;
  esac
}

# Read-only for the lease and GitHub: the ledger's runner, online or offline
# and busy, or absent.
handle_status() {
  local r rstatus rbusy
  L_RES=- L_GEN=- L_PROFILE=- L_IMAGE=-
  if ! ledger_read "${LEASE_ID}"; then
    status_refused not_found - -
    return 0
  fi
  if ! fresh; then
    status_refused clock_skew "${LRID}" "${LNAME}"
    return 0
  fi
  if ! nonce_add; then
    status_refused replay "${LRID}" "${LNAME}"
    return 0
  fi
  if [[ "${LS}" == released || "${LS}" == refused ]]; then
    status_ok absent false "${LRID}" "${LNAME}"
    return 0
  fi
  if ! mint_token; then
    status_refused github_error "${LRID}" "${LNAME}"
    return 0
  fi
  if [[ "${LS}" == issued ]]; then
    r=$(runner_by_id "${LRID}")
  else
    r=$(runner_by_name "${LNAME}")
  fi
  case "${r}" in
    absent) status_ok absent false "${LRID}" "${LNAME}" ;;
    "found "*)
      read -r _ _ rstatus rbusy <<< "${r}"
      status_ok "${rstatus}" "${rbusy}" "${LRID}" "${LNAME}"
      ;;
    *) status_refused "${r#error }" "${LRID}" "${LNAME}" ;;
  esac
}

# Exit trap: the installation token is revoked (best effort, its answer is
# dropped), and every failure but the bad-input exit 2 leaves with status 1.
on_exit() {
  local rc=$?
  if [[ -n "${TOKEN}" ]] && room_for 3; then
    auth_header "${TOKEN}" | curl --silent --connect-timeout 2 --max-time 3 -X DELETE -H @- \
      -H "Accept: application/vnd.github+json" "${GITHUB_API}/installation/token" >/dev/null 2>&1 || true
  fi
  TOKEN=""
  ((rc == 0 || (rc == 2 && BAD_INPUT == 1))) || rc=1
  exit "${rc}"
}

broker_run() {
  local d
  RUN_START=$(now_s)
  trap on_exit EXIT
  if read_request; then
    parse_request
  else
    V=bad
  fi
  if [[ "${V}" == bad ]]; then
    echo "aap-runner-broker: refused: stdin is not one request with a kind and a lease id" >&2
    BAD_INPUT=1
    exit 2
  fi
  load_config >&2
  check_key >&2
  # Directories owned by root (this user), mode 0700, never through a symlink.
  for d in "${BROKER_DIR}" "${BROKER_DIR}/leases" "${BROKER_DIR}/open" "${BROKER_DIR}/slots" "${AUDIT_LOG%/*}"; do
    if [[ -L "${d}" ]] || ! install -d -m 0700 "${d}" || [[ -L "${d}" || ! -O "${d}" ]]; then
      die "refusing ${d}: not a directory owned by this user"
    fi
  done
  exec 9>> "${BROKER_DIR}/lock"
  if ! flock -w "${LOCK_WAIT_SECONDS}" 9; then
    echo "aap-runner-broker: the ledger lock stayed busy for ${LOCK_WAIT_SECONDS} s" >&2
    exit 1
  fi
  if [[ "${V}" != ok ]]; then
    refuse_request "${V}"
    return 0
  fi
  sweep
  case "${KIND}" in
    lease_request) handle_lease ;;
    release_request) handle_release ;;
    status_request) handle_status ;;
  esac
}

main() {
  if [[ $# -ne 0 ]]; then
    echo "aap-runner-broker: takes no arguments; the request is on stdin" >&2
    exit 2
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "aap-runner-broker must run as root" >&2
    exit 1
  fi
  broker_run
}

# Runs only when executed. tests/ source this file for its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
