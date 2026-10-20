#!/bin/bash
# The registration broker (distro/worker-auth.sh, installed as
# /usr/local/sbin/aap-runner-broker) with GitHub faked by a curl shim and a
# throwaway App key made here: request checks against the broker contract
# fixtures and attacker-chosen fields; replay, clock skew, stale generation and
# the outstanding-lease limit under the ledger lock (two concurrent requests);
# release and status by lease id only; the sweep; unavailable and killed
# brokers; and a secret-marker run in which a synthetic JIT config and
# installation token never appear in any process's argv (/proc/*/cmdline,
# sampled at every curl, jq and openssl call and continuously), stderr, the
# audit log, the ledger, the temp dir or any other file under the test tree.
# Every response and audit line is checked with parity/contracts/validate.py.
# Needs Linux (flock, /proc), jq, openssl and python3. GitHub is never contacted.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "${here}/.." && pwd)
broker="${repo}/distro/worker-auth.sh"
validate="${repo}/parity/contracts/validate.py"
fixtures="${repo}/parity/contracts/fixtures/broker"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for tool in jq openssl python3 flock base64; do
  command -v "${tool}" >/dev/null || fail "${tool} is required"
done

# T: everything the broker and the fake GitHub write. N: the synthetic secrets,
# outside T, so a scan of T for them means something.
T=$(mktemp -d)
N=$(mktemp -d)
sampler=""
cleanup() {
  rm -f "${T}/sampling"
  if [[ -n "${sampler}" ]]; then
    kill "${sampler}" 2>/dev/null || true
    wait "${sampler}" 2>/dev/null || true
  fi
  rm -rf "${T}" "${N}"
}
trap cleanup EXIT
REAL_JQ=$(command -v jq)
REAL_OPENSSL=$(command -v openssl)
export T N REAL_JQ REAL_OPENSSL
mkdir -p "${T}/bin" "${T}/tmp"

openssl genrsa -out "${N}/app.pem" 2048 2>/dev/null
printf 'SYNTHETIC-JIT-MARKER-%s' "$(openssl rand -hex 12)" > "${N}/marker"
# The JIT value is base64 of the marker, like the contract fixture.
base64 -w0 < "${N}/marker" > "${N}/jit"
printf 'test-installation-token-%s' "$(openssl rand -hex 12)" > "${N}/token"
{
  cat "${N}/jit"
  echo
  cat "${N}/marker"
  echo
  cat "${N}/token"
  echo
  echo 'PRIVATE KEY'
} > "${N}/needles"
jit_value=$(cat "${N}/jit")

# ---- shims -----------------------------------------------------------------
# jq and openssl: record every process's argv that holds a secret, then run
# the real tool. A secret passed in any argv during a broker run lands here.
# ${T}/jq_fail holds a filter fragment: a jq call whose arguments contain it
# writes a partial document and fails (a full disk), with status 2.
cat > "${T}/bin/jq" <<'EOF'
#!/bin/bash
cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n' | grep -F -f "${N}/needles" >> "${T}/argv-hits" || true
printf x >> "${T}/snaps"
if [[ -s "${T}/jq_fail" && "$*" == *"$(cat "${T}/jq_fail")"* ]]; then
  printf '{'
  exit 2
fi
exec "${REAL_JQ}" "$@"
EOF
cat > "${T}/bin/openssl" <<'EOF'
#!/bin/bash
cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n' | grep -F -f "${N}/needles" >> "${T}/argv-hits" || true
printf x >> "${T}/snaps"
exec "${REAL_OPENSSL}" "$@"
EOF
# api.github.com. State in ${T}/gh; the JIT config and the token are read
# from ${N} and never written under ${T}.
cat > "${T}/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
gh="${T}/gh"
cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n' | grep -F -f "${N}/needles" >> "${T}/argv-hits" || true
printf x >> "${T}/snaps"
if [[ "${1:-}" != -q ]]; then
  echo "CURL WITHOUT -q" >> "${gh}/calls"
  exit 2
fi
hdr=$(cat)
method=GET data="" query="" wfmt="" fail_flag=0 timeouts=0
args=("$@")
url=${args[-1]}
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    -X) method=${args[i + 1]} ;;
    --data) data=${args[i + 1]} ;;
    --data-urlencode) query="${query}${query:+&}${args[i + 1]}" ;;
    -w) wfmt=${args[i + 1]} ;;
    --fail) fail_flag=1 ;;
    --connect-timeout | --max-time) timeouts=$((timeouts + 1)) ;;
  esac
done
token=$(cat "${N}/token")
case "${hdr}" in
  "Authorization: Bearer ${token}") auth=token ;;
  "Authorization: Bearer "?*.?*.?*) auth=jwt ;;
  *) auth=none ;;
esac
path=${url#https://api.github.com}
echo "${method} ${path}${query:+?${query}} auth=${auth} timeouts=${timeouts}" >> "${gh}/calls"

new_runner() {
  local id
  id=$(cat "${gh}/next_id")
  echo $((id + 1)) > "${gh}/next_id"
  "${REAL_JQ}" -c --argjson id "${id}" --arg n "$1" '. + [{id: $id, name: $n, status: "offline", busy: false}]' \
    "${gh}/runners.json" > "${gh}/runners.tmp"
  mv "${gh}/runners.tmp" "${gh}/runners.json"
  echo "${id}"
}

code=200 body=""
case "${method} ${path}" in
  "POST /app/installations/67890/access_tokens")
    [[ ! -e "${gh}/token_fail" ]] || exit 22
    [[ ! -f "${gh}/token_sleep" ]] || sleep "$(cat "${gh}/token_sleep")"
    body=$(printf '{"token":"%s","expires_at":"2099-01-01T00:00:00Z"}' "${token}")
    ;;
  "GET /orgs/example-org/actions/runner-groups")
    body='{"total_count":2,"runner_groups":[{"id":9,"name":"Default"},{"id":7,"name":"aap-crrr"}]}'
    ;;
  "POST /orgs/example-org/actions/runners/generate-jitconfig")
    printf '%s\n' "${data}" >> "${gh}/jit_bodies"
    mode=ok
    [[ ! -f "${gh}/jit_mode" ]] || mode=$(cat "${gh}/jit_mode")
    name=$(printf '%s' "${data}" | "${REAL_JQ}" -r .name)
    case "${mode}" in
      ok | sleep)
        [[ "${mode}" != sleep ]] || sleep 2
        id=$(new_runner "${name}")
        code=201
        body=$(printf '{"runner":{"id":%s,"name":"%s","os":"unknown","status":"offline","busy":false},"encoded_jit_config":"%s"}' \
          "${id}" "${name}" "$(cat "${N}/jit")")
        ;;
      bad-jit)
        id=$(new_runner "${name}")
        code=201
        body=$(printf '{"runner":{"id":%s,"name":"%s"},"encoded_jit_config":"not a jit config"}' "${id}" "${name}")
        ;;
      lost)
        # GitHub created the runner, the reply never arrived.
        new_runner "${name}" > /dev/null
        exit 28
        ;;
      hang)
        sleep 5
        exit 28
        ;;
      403) code=403 body='{"message":"API rate limit exceeded for installation ID 67890."}' ;;
      *) code=${mode} body='{"message":"Validation failed, or the endpoint has been spammed."}' ;;
    esac
    ;;
  "DELETE /installation/token")
    code=204
    ;;
  "GET /orgs/example-org/actions/runners")
    [[ ! -f "${gh}/list_sleep" ]] || sleep "$(cat "${gh}/list_sleep")"
    [[ ! -f "${gh}/list_code" ]] || code=$(cat "${gh}/list_code")
    body=$("${REAL_JQ}" -c --arg n "${query#name=}" '[.[] | select(.name == $n)] | {total_count: length, runners: .}' \
      "${gh}/runners.json")
    ;;
  "GET /orgs/example-org/actions/runners/"*)
    id=${path##*/}
    body=$("${REAL_JQ}" -c --argjson id "${id}" '[.[] | select(.id == $id)][0] // empty' "${gh}/runners.json")
    if [[ -z "${body}" ]]; then
      code=404 body='{"message":"Not Found"}'
    fi
    if [[ -f "${gh}/get_code" ]]; then
      code=$(cat "${gh}/get_code") body='{"message":"Server Error"}'
    fi
    ;;
  "DELETE /orgs/example-org/actions/runners/"*)
    id=${path##*/}
    if [[ -f "${gh}/delete_code" ]]; then
      code=$(cat "${gh}/delete_code") body='{"message":"Runner is still running a job"}'
      [[ "${code}" != 403 ]] || body='{"message":"You have exceeded a secondary rate limit."}'
    elif "${REAL_JQ}" -e --argjson id "${id}" 'any(.[]; .id == $id)' "${gh}/runners.json" >/dev/null; then
      "${REAL_JQ}" -c --argjson id "${id}" 'map(select(.id != $id))' "${gh}/runners.json" > "${gh}/runners.tmp"
      mv "${gh}/runners.tmp" "${gh}/runners.json"
      echo "${id}" >> "${gh}/deleted"
      code=204
    else
      code=404 body='{"message":"Not Found"}'
    fi
    ;;
  *)
    echo "UNROUTED ${method} ${path}" >> "${gh}/calls"
    code=599
    ;;
esac
if ((fail_flag && code >= 400)); then
  exit 22
fi
printf '%s' "${body}"
[[ -z "${wfmt}" ]] || printf '\n%s' "${code}"
EOF
# Runs broker_run with the test's state paths, a fixed config and the shims.
# load_config and check_key are the manager's; the real ones refuse a key or
# conf not owned by root, so they are replaced and their calls recorded.
cat > "${T}/driver.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# shellcheck source=/dev/null
source "${BROKER}"
PATH="${T}/bin:${PATH}"
BROKER_DIR="${T}/state"
AUDIT_LOG="${T}/log/broker-audit.jsonl"
LOCK_WAIT_SECONDS=${TEST_LOCK_WAIT:-20}
AUDIT_MAX_BYTES=${TEST_AUDIT_MAX:-${AUDIT_MAX_BYTES}}
SWEEP_SECONDS=${TEST_SWEEP_SECONDS:-${SWEEP_SECONDS}}
RUN_LIMIT_SECONDS=${TEST_RUN_LIMIT:-${RUN_LIMIT_SECONDS}}
load_config() {
  echo load_config >> "${T}/called"
  if [[ -n "${TEST_CONF_FAIL:-}" ]]; then
    echo "refusing: test config" >&2
    exit 1
  fi
  AAP_GITHUB_ORG=example-org
  AAP_GITHUB_APP_ID=12345
  AAP_GITHUB_APP_INSTALLATION_ID=67890
  AAP_GITHUB_APP_PRIVATE_KEY_PATH=${N}/app.pem
  AAP_RUNNER_GROUP=aap-crrr
}
check_key() {
  echo check_key >> "${T}/called"
}
broker_run
EOF
chmod +x "${T}/bin/jq" "${T}/bin/openssl" "${T}/bin/curl"

# Continuous argv sampling for the whole test, beside the per-call snapshots.
: > "${T}/sampling"
(
  while [[ -e "${T}/sampling" ]]; do
    cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n' | grep -F -f "${N}/needles" >> "${T}/argv-hits" || true
    sleep 0.05
  done
) &
sampler=$!

# ---- helpers ---------------------------------------------------------------

now_iso() {
  date -u -d "@$(($(date -u +%s) + ${1:-0}))" +%Y-%m-%dT%H:%M:%SZ
}

new_lease() {
  printf 'l-%s' "$(openssl rand -hex 16)"
}

new_res() {
  printf 'r-%s' "$(openssl rand -hex 8)"
}

nonce() {
  openssl rand -hex 16
}

# LEASE_ID SLOT GENERATION RESERVATION [PROFILE] [SKEW_SECONDS]
lease_req() {
  local prof=${5:-win25-vs2026-x64}
  printf '{"schema":1,"kind":"lease_request","lease_id":"%s","reservation_id":"%s","lease_generation":%s,"slot":%s,"profile":"%s","image_generation":"%s/20261007.264.1-aap.1","nonce":"%s","issued_at":"%s"}' \
    "$1" "$4" "$3" "$2" "${prof}" "${prof}" "$(nonce)" "$(now_iso "${6:-0}")"
}

# KIND LEASE_ID [NONCE] [SKEW_SECONDS]
small_req() {
  printf '{"schema":1,"kind":"%s","lease_id":"%s","nonce":"%s","issued_at":"%s"}' \
    "$1" "$2" "${3:-$(nonce)}" "$(now_iso "${4:-0}")"
}

# run_file [ENV=VALUE...]: ${T}/req on stdin. RC, OUT (stdout, kept in memory:
# an issued response carries the JIT config); stderr is collected for the scan.
run_file() {
  RC=0
  OUT=$(env "$@" TMPDIR="${T}/tmp" BROKER="${broker}" bash "${T}/driver.sh" < "${T}/req" 2> "${T}/err") || RC=$?
  cat "${T}/err" >> "${T}/stderr.all"
}

run_broker() {
  local req=$1
  shift
  printf '%s' "${req}" > "${T}/req"
  run_file "$@"
}

out_field() {
  printf '%s' "${OUT}" | jq -r "$1"
}

# LABEL RESULT REASON: exit 0, the result and reason, and a valid contract document.
expect() {
  [[ "${RC}" -eq 0 ]] || fail "$1: exit ${RC}: $(cat "${T}/err")"
  [[ "$(out_field .result)/$(out_field .reason)" == "$2/$3" ]] \
    || fail "$1: got $(out_field .result)/$(out_field .reason); want $2/$3"
  printf '%s' "${OUT}" | python3 -B -I "${validate}" broker /dev/stdin >/dev/null \
    || fail "$1: the response is not a valid broker document"
}

# Lines of the fake GitHub's call log that contain PATTERN.
calls() {
  local c
  c=$(grep -c -F -- "$1" "${T}/gh/calls" 2>/dev/null) || true
  echo "${c:-0}"
}

ledger() {
  jq -r "$2" "${T}/state/leases/$1.json"
}

last_audit() {
  tail -n 1 "${T}/log/broker-audit.jsonl" | jq -r "$1"
}

runner_count() {
  jq length "${T}/gh/runners.json"
}

# NAME STATUS BUSY: a runner GitHub lists; prints its id.
gh_runner() {
  local id
  id=$(cat "${T}/gh/next_id")
  echo $((id + 1)) > "${T}/gh/next_id"
  jq -c --argjson id "${id}" --arg n "$1" --arg s "$2" --argjson b "$3" \
    '. + [{id: $id, name: $n, status: $s, busy: $b}]' "${T}/gh/runners.json" > "${T}/gh/runners.tmp"
  mv "${T}/gh/runners.tmp" "${T}/gh/runners.json"
  echo "${id}"
}

gh_set() {
  jq -c --argjson id "$1" --arg s "$2" --argjson b "$3" 'map(if .id == $id then .status = $s | .busy = $b else . end)' \
    "${T}/gh/runners.json" > "${T}/gh/runners.tmp"
  mv "${T}/gh/runners.tmp" "${T}/gh/runners.json"
}

gh_forget() {
  jq -c --argjson id "$1" 'map(select(.id != $id))' "${T}/gh/runners.json" > "${T}/gh/runners.tmp"
  mv "${T}/gh/runners.tmp" "${T}/gh/runners.json"
}

# A ledger record as the broker writes it: LEASE_ID STATE NAME RUNNER_ID|- EXPIRES_EPOCH
seed() {
  mkdir -p "${T}/state/leases" "${T}/state/open"
  jq -nc --arg lid "$1" --arg s "$2" --arg n "$3" --arg rid "$4" --argjson exp "$5" '
    {schema: 1, lease_id: $lid, reservation_id: "r-0123456789abcdef", lease_generation: 1, slot: 1,
     profile: "win25-vs2026-x64", image_generation: "win25-vs2026-x64/20261007.264.1-aap.1",
     runner_name: $n, runner_id: (if $rid == "-" then null else ($rid | tonumber) end), state: $s,
     outcome: "ok", created_at: "2026-10-19T18:00:00Z", expires_at: "2026-10-19T18:10:00Z",
     expires_epoch: $exp, nonces: []}' > "${T}/state/leases/$1.json"
  : > "${T}/state/open/$1"
}

# LEASE_ID: its expiry moves a minute into the past.
age_lease() {
  jq -c --argjson e "$(($(date -u +%s) - 60))" '.expires_epoch = $e' "${T}/state/leases/$1.json" > "${T}/state/age.tmp"
  mv "${T}/state/age.tmp" "${T}/state/leases/$1.json"
}

# Every audit line (and the rotated file) is a valid contract audit record.
audit_ok() {
  local f line i=0
  rm -rf "${T}/auditcheck"
  mkdir -p "${T}/auditcheck"
  for f in "${T}/log/broker-audit.jsonl.1" "${T}/log/broker-audit.jsonl"; do
    [[ -f "${f}" ]] || continue
    [[ "$(stat -c %a "${f}")" == 600 ]] || fail "${f##*/} is mode $(stat -c %a "${f}"), not 0600"
    while IFS= read -r line; do
      i=$((i + 1))
      printf '%s\n' "${line}" > "${T}/auditcheck/${i}.json"
    done < "${f}"
  done
  ((i > 0)) || return 0
  python3 -B -I "${validate}" broker "${T}/auditcheck"/*.json > "${T}/auditcheck.out" \
    || fail "an audit line is not a valid audit record: $(grep FAIL "${T}/auditcheck.out")"
}

# No secret in any file under T (ledger, audit, stderr, the fake's logs, the
# argv hits), no temp file left, every audit line valid.
scan_secrets() {
  local hits
  hits=$(grep -r -l -F -f "${N}/needles" "${T}" 2>/dev/null) || true
  [[ -z "${hits}" ]] || fail "a synthetic secret was found in: ${hits}"
  [[ -z "$(find "${T}/tmp" -mindepth 1 -print -quit)" ]] || fail "the broker left a file in TMPDIR"
  audit_ok
}

reset() {
  scan_secrets
  rm -rf "${T}/state" "${T}/log" "${T}/gh" "${T}/called"
  mkdir -p "${T}/gh"
  echo '[]' > "${T}/gh/runners.json"
  echo 100 > "${T}/gh/next_id"
  : > "${T}/gh/calls"
}

reset

# ---- requests: the contract fixtures and attacker-chosen fields ----------------

python3 -B -I "${validate}" > "${T}/validate.out" || fail "validate.py: $(tail -n 5 "${T}/validate.out")"

# The broker's verdict for one request document: bad, malformed, unknown_profile or ok.
verdict() {
  (
    # shellcheck source=SCRIPTDIR/../distro/worker-auth.sh
    source "${broker}"
    REQ=$1
    parse_request
    printf '%s' "${V}"
  )
}

for f in "${fixtures}"/valid/*.json; do
  kind=$(jq -r .kind "${f}")
  got=$(verdict "$(cat "${f}")")
  case "${kind}" in
    *_request) [[ "${got}" == ok ]] || fail "valid fixture ${f##*/} was refused (${got})" ;;
    *) [[ "${got}" == bad ]] || fail "the ${kind} fixture ${f##*/} was taken as a request (${got})" ;;
  esac
done
for f in "${fixtures}"/invalid/*.json; do
  kind=$(jq -r .instance.kind "${f}")
  got=$(verdict "$(jq -c .instance "${f}")")
  case "${kind}" in
    *_request) [[ "${got}" == malformed || "${got}" == unknown_profile ]] || fail "invalid fixture ${f##*/} was accepted (${got})" ;;
    *) [[ "${got}" == bad ]] || fail "the ${kind} fixture ${f##*/} was taken as a request (${got})" ;;
  esac
done
[[ "$(verdict "$(jq -c .instance "${fixtures}/invalid/unknown-profile.json")")" == unknown_profile ]] \
  || fail "an unknown profile is not refused as unknown_profile"
echo "contract fixtures ok"

base=$(jq -c . "${fixtures}/valid/lease-request.json")
release_base=$(jq -c . "${fixtures}/valid/release-request.json")
for edit in '.command = "id"' '.path = "/etc/aap-runner/app.pem"' '.work_folder = "_work"' \
  '.labels = ["self-hosted"]' '.runner_id = 7' '.runner_name = "aap-w-4-3-1a2b3c4d"' \
  '.url = "https://api.github.com"' '.org = "other-org"' '.runner_group_id = 1' '.slot = 6' '.slot = 0' \
  '.lease_generation = 0' '.lease_generation = 1000000000' '.lease_generation = "3"' '.schema = 2' \
  '.schema = "1"' '.nonce = "7777777777777777777777777777777G"' '.reservation_id = "r-1a2b3c4d"' \
  '.image_generation = "ubuntu-24.04-x64/20261007.264.1-aap.1"' '.image_generation = "win25-vs2026-x64/latest"' \
  'del(.nonce)' 'del(.schema)' '.issued_at = "2026-10-19 18:00:00"' '.issued_at = "2026-19-45T99:99:99Z"' \
  '.issued_at += "\n"' '.nonce += "\n"' '.profile = 7'; do
  [[ "$(verdict "$(jq -c "${edit}" <<< "${base}")")" == malformed ]] || fail "a lease request with ${edit} was not malformed"
done
for edit in '.runner_id = 99' '.runner_name = "x"' '.reservation_id = "r-1a2b3c4d000000b1"' '.slot = 1' \
  '.command = "id"' 'del(.issued_at)'; do
  [[ "$(verdict "$(jq -c "${edit}" <<< "${release_base}")")" == malformed ]] || fail "a release request with ${edit} was not malformed"
done
# jq 1.7 keeps a number's literal form, so 3.0 is not an integer (as in validate.py).
if [[ "$(jq -cn '[3.0] | .[0] | tostring')" == '"3.0"' ]]; then
  [[ "$(verdict "$(sed 's/"lease_generation":3/"lease_generation":3.0/' <<< "${base}")")" == malformed ]] \
    || fail "a lease_generation of 3.0 was taken as an integer"
fi
# No response is possible without a request kind and a valid lease id.
for doc in '' 'null' '[]' '"lease_request"' '{}' "${base} ${base}" "[${base}]" "${base}x" \
  "$(jq -c '.kind = "lease"' <<< "${base}")" "$(jq -c '.kind = "lease_response"' <<< "${base}")" \
  "$(jq -c 'del(.lease_id)' <<< "${base}")" "$(jq -c '.lease_id = "L-55555555555555555555555555555555"' <<< "${base}")" \
  "$(jq -c '.lease_id += "\n"' <<< "${base}")" "$(jq -c '.lease_id = "l-5555/../../etc/passwd"' <<< "${base}")"; do
  [[ "$(verdict "${doc}")" == bad ]] || fail "a document without a usable kind and lease id got a verdict: ${doc}"
done
echo "attacker-chosen fields refused ok"

# End to end: no ledger write, no GitHub call, a refused response of the kind.
lid=$(new_lease)
run_broker "$(jq -c --arg l "${lid}" '.lease_id = $l | .command = "rm -rf /"' <<< "${base}")"
expect "request with a command" refused malformed
[[ "$(calls ' ')" -eq 0 && ! -e "${T}/state/leases/${lid}.json" ]] || fail "a malformed request touched the ledger or GitHub"
[[ "$(last_audit '[.op, .outcome, .reason, .lease_id] | join(" ")')" == "lease refused malformed ${lid}" ]] \
  || fail "malformed request audit: $(tail -n 1 "${T}/log/broker-audit.jsonl")"
run_broker "$(jq -c --arg l "${lid}" '.lease_id = $l | .profile = "windows-latest"' <<< "${base}")"
expect "unknown profile" refused unknown_profile
run_broker "$(jq -c --arg l "${lid}" '.lease_id = $l | .runner_id = 99' <<< "${release_base}")"
expect "release naming a runner id" refused malformed
[[ "$(out_field .kind)" == release_response ]] || fail "a refused release is not a release_response"
run_broker "$(jq -c --arg l "${lid}" '.lease_id = $l | .kind = "status_request" | .path = "/tmp"' <<< "${release_base}")"
expect "status with a path" refused malformed
[[ "$(out_field '.runner')" == null ]] || fail "a refused status carries runner state"
[[ "$(calls ' ')" -eq 0 && ! -e "${T}/state/leases/${lid}.json" ]] || fail "a malformed request touched the ledger or GitHub"
# Oversized, two documents, a NUL byte: no stdout at all, exit 2, nothing loaded.
{
  lease_req "${lid}" 1 1 "$(new_res)"
  printf '%4100s' ''
} > "${T}/req"
run_file
[[ "${RC}" -eq 2 && -z "${OUT}" ]] || fail "an oversized request gave exit ${RC} and output ${OUT}"
{
  lease_req "${lid}" 1 1 "$(new_res)"
  printf '\0'
} > "${T}/req"
run_file
[[ "${RC}" -eq 2 && -z "${OUT}" ]] || fail "a request with a NUL byte gave exit ${RC} and output ${OUT}"
run_broker "$(lease_req "${lid}" 1 1 "$(new_res)") $(lease_req "${lid}" 1 1 "$(new_res)")"
[[ "${RC}" -eq 2 && -z "${OUT}" ]] || fail "two requests gave exit ${RC}"
[[ ! -e "${T}/state/leases/${lid}.json" && "$(calls ' ')" -eq 0 ]] || fail "an unparseable request touched the ledger or GitHub"
# The program takes no argument, and refuses to run as anyone but root.
RC=0
bash "${broker}" --self-check < /dev/null > "${T}/argout" 2>> "${T}/stderr.all" || RC=$?
[[ "${RC}" -eq 2 && ! -s "${T}/argout" ]] || fail "an argument was accepted (exit ${RC})"
if [[ "$(id -u)" -ne 0 ]]; then
  RC=0
  bash "${broker}" < /dev/null > "${T}/argout" 2> "${T}/err" || RC=$?
  cat "${T}/err" >> "${T}/stderr.all"
  [[ "${RC}" -eq 1 && ! -s "${T}/argout" ]] && grep -q 'must run as root' "${T}/err" \
    || fail "the broker ran as a non-root user (exit ${RC})"
fi
echo "malformed, oversized and unparseable requests ok"

# ---- lease -----------------------------------------------------------------
reset
res=$(new_res)
lid=$(new_lease)
req1=$(lease_req "${lid}" 4 3 "${res}")
t0=$(date -u +%s)
run_broker "${req1}"
t1=$(date -u +%s)
expect "lease" issued ok
name="aap-w-4-3-${res:2:8}"
[[ "$(out_field .runner_name)" == "${name}" && "$(out_field .runner_id)" == 100 && "$(out_field .lease_id)" == "${lid}" ]] \
  || fail "issued lease names $(out_field .runner_name) id $(out_field .runner_id)"
got=$(out_field .jit_config)
[[ "${got}" == "${jit_value}" ]] || fail "the response does not carry the JIT config GitHub returned"
got=""
exp=$(date -u -d "$(out_field .expires_at)" +%s)
((exp >= t0 + 600 && exp <= t1 + 600)) || fail "expires_at is not 10 minutes after issue"
jq -e --arg n "${name}" '.name == $n and .runner_group_id == 7 and .work_folder == "_work"
  and .labels == ["self-hosted", "Windows", "X64", "aap-win25-vs2026"]
  and keys == ["labels", "name", "runner_group_id", "work_folder"]' "${T}/gh/jit_bodies" >/dev/null \
  || fail "generate-jitconfig body: $(cat "${T}/gh/jit_bodies")"
[[ "$(calls 'POST /app/installations/67890/access_tokens auth=jwt timeouts=2')" -eq 1 ]] || fail "the installation token was not minted from a JWT on stdin: $(cat "${T}/gh/calls")"
[[ "$(calls 'GET /orgs/example-org/actions/runner-groups?per_page=100 auth=token timeouts=2')" -eq 1 ]] || fail "the runner group was not resolved by name"
[[ "$(calls 'POST /orgs/example-org/actions/runners/generate-jitconfig auth=token timeouts=2')" -eq 1 ]] || fail "generate-jitconfig was not called once with the token on stdin"
[[ "$(calls 'DELETE /installation/token auth=token timeouts=2')" -eq 1 ]] || fail "the installation token was not revoked at exit"
[[ "$(calls ' ')" -eq 4 ]] || fail "unexpected GitHub calls: $(cat "${T}/gh/calls")"
[[ "$(sort "${T}/called" | tr '\n' ' ')" == "check_key load_config " ]] || fail "the manager's load_config and check_key were not each called once"
[[ "$(ledger "${lid}" '[.state, .runner_id, .runner_name, .slot, .lease_generation, .reservation_id] | join(" ")')" == "issued 100 ${name} 4 3 ${res}" ]] \
  || fail "ledger: $(cat "${T}/state/leases/${lid}.json")"
[[ "$(ledger "${lid}" 'keys | join(",")')" == "created_at,expires_at,expires_epoch,image_generation,lease_generation,lease_id,nonces,outcome,profile,reservation_id,runner_id,runner_name,schema,slot,state" ]] \
  || fail "ledger fields: $(ledger "${lid}" 'keys | join(",")')"
[[ "$(stat -c %a "${T}/state/leases/${lid}.json")" == 600 && "$(stat -c %a "${T}/state")" == 700 && "$(stat -c %a "${T}/state/leases")" == 700 \
  && "$(stat -c %a "${T}/log")" == 700 ]] || fail "ledger or audit log is not root-only (0600 files, 0700 dirs)"
[[ -e "${T}/state/open/${lid}" && "$(cat "${T}/state/slots/4")" == 3 && "$(cat "${T}/state/group-id")" == 7 ]] \
  || fail "open marker, slot generation or group cache missing"
[[ "$(last_audit '[.op, .outcome, .reason, .runner_id, .runner_name, .lease_generation, .profile] | join(" ")')" == "lease issued ok 100 ${name} 3 win25-vs2026-x64" ]] \
  || fail "issue audit: $(tail -n 1 "${T}/log/broker-audit.jsonl")"
res2=$(new_res)
run_broker "$(lease_req "$(new_lease)" 2 1 "${res2}" ubuntu-24.04-x64)"
expect "ubuntu lease" issued ok
[[ "$(out_field .runner_name)" == "aap-l-2-1-${res2:2:8}" ]] || fail "ubuntu runner name $(out_field .runner_name)"
tail -n 1 "${T}/gh/jit_bodies" | jq -e '.labels == ["self-hosted", "Linux", "X64", "aap-ubuntu-24.04"] and .runner_group_id == 7' >/dev/null \
  || fail "ubuntu labels: $(tail -n 1 "${T}/gh/jit_bodies")"
[[ "$(calls 'runner-groups')" -eq 1 ]] || fail "the cached group id was not reused"
# HOME is the caller's: its ~/.jq (a jq library jq loads by itself) is never read.
mkdir -p "${T}/home"
printf 'def broken: ;;;\n' > "${T}/home/.jq"
hl=$(new_lease)
run_broker "$(lease_req "${hl}" 5 1 "$(new_res)")" HOME="${T}/home"
expect "lease with a hostile HOME" issued ok
rm -rf "${T}/home"
run_broker "$(small_req release_request "${hl}")"
expect "release of the hostile-HOME lease" deregistered ok
[[ "$(calls 'WITHOUT -q')" -eq 0 ]] || fail "a curl call did not start with -q"
echo "issued lease ok"

# Replay: the same bytes, and the same lease id from another reservation.
sum=$(sha256sum < "${T}/state/leases/${lid}.json")
before=$(calls ' ')
run_broker "${req1}"
expect "replayed lease" refused replay
run_broker "$(lease_req "${lid}" 5 9 "$(new_res)")"
expect "lease id of another reservation" refused replay
[[ "$(sha256sum < "${T}/state/leases/${lid}.json")" == "${sum}" ]] || fail "a replay changed the ledger"
[[ "$(calls ' ')" -eq "${before}" && "$(runner_count)" -eq 2 ]] || fail "a replay reached GitHub"
echo "replay ok"

# Clock: more than 300 s either way; the lease id is spent.
lid2=$(new_lease)
run_broker "$(lease_req "${lid2}" 1 5 "$(new_res)" win25-vs2026-x64 -400)"
expect "lease issued 400 s ago" refused clock_skew
[[ "$(ledger "${lid2}" '.state + " " + .outcome')" == "refused clock_skew" && ! -e "${T}/state/open/${lid2}" ]] \
  || fail "a skewed lease is not recorded as refused"
run_broker "$(lease_req "${lid2}" 1 5 "$(new_res)")"
expect "fresh request with a spent lease id" refused replay
run_broker "$(lease_req "$(new_lease)" 1 5 "$(new_res)" win25-vs2026-x64 400)"
expect "lease issued 400 s ahead" refused clock_skew
[[ "$(calls ' ')" -eq "${before}" ]] || fail "a skewed request reached GitHub"
echo "clock skew ok"

# Stale generation, per slot: slot 4 holds 3.
run_broker "$(lease_req "$(new_lease)" 4 2 "$(new_res)")"
expect "lower generation" refused stale_generation
run_broker "$(lease_req "$(new_lease)" 4 3 "${res}")"
expect "same generation again" refused stale_generation
[[ "$(calls ' ')" -eq "${before}" ]] || fail "a stale request reached GitHub"
run_broker "$(lease_req "$(new_lease)" 4 4 "$(new_res)")"
expect "next generation" issued ok
run_broker "$(lease_req "$(new_lease)" 3 1 "$(new_res)")"
expect "another slot" issued ok
# A slot file that exists but holds no generation refuses the slot; a
# generation without a newline still counts.
for content in '' 'garbage' '3x'; do
  printf '%s' "${content}" > "${T}/state/slots/2"
  run_broker "$(lease_req "$(new_lease)" 2 7 "$(new_res)")"
  expect "slot file '${content}'" refused stale_generation
done
printf '7' > "${T}/state/slots/2"
run_broker "$(lease_req "$(new_lease)" 2 7 "$(new_res)")"
expect "slot generation without a newline" refused stale_generation
run_broker "$(lease_req "$(new_lease)" 2 8 "$(new_res)")"
expect "next generation after a bare one" issued ok
echo "stale generation ok"

# ---- outstanding limit -----------------------------------------------------
reset
declare -a slot_lease=()
for s in 1 2 3 4 5; do
  slot_lease[s]=$(new_lease)
  run_broker "$(lease_req "${slot_lease[s]}" "${s}" 1 "$(new_res)")"
  expect "lease in slot ${s}" issued ok
done
lid6=$(new_lease)
run_broker "$(lease_req "${lid6}" 1 2 "$(new_res)")"
expect "sixth outstanding lease" refused lease_limit
[[ "$(ledger "${lid6}" .state)" == refused && "$(find "${T}/state/open" -type f | wc -l)" -eq 5 ]] \
  || fail "the refused sixth lease is counted"
run_broker "$(small_req release_request "${slot_lease[1]}")"
expect "release slot 1" deregistered ok
# Four outstanding; two requests at once: exactly one gets the fifth lease.
# This shows the outcome, not the lock (without it the two runs usually still
# serialize); the busy-lock block below is the proof that the lock is held.
echo sleep > "${T}/gh/jit_mode"
lease_req "$(new_lease)" 1 2 "$(new_res)" > "${T}/req.a"
lease_req "$(new_lease)" 2 2 "$(new_res)" > "${T}/req.b"
env TMPDIR="${T}/tmp" BROKER="${broker}" bash "${T}/driver.sh" < "${T}/req.a" > "${N}/out.a" 2>> "${T}/stderr.all" &
pa=$!
env TMPDIR="${T}/tmp" BROKER="${broker}" bash "${T}/driver.sh" < "${T}/req.b" > "${N}/out.b" 2>> "${T}/stderr.all" &
pb=$!
wait "${pa}" || fail "concurrent request a exited non-zero"
wait "${pb}" || fail "concurrent request b exited non-zero"
rm -f "${T}/gh/jit_mode"
got=$(jq -r '.result + "/" + .reason' "${N}/out.a" "${N}/out.b" | sort | tr '\n' ' ')
rm -f "${N}/out.a" "${N}/out.b"
[[ "${got}" == "issued/ok refused/lease_limit " ]] || fail "two concurrent requests with four outstanding gave ${got}"
[[ "$(find "${T}/state/open" -type f | wc -l)" -eq 5 ]] || fail "more than five leases are outstanding"
echo "outstanding limit under the lock ok"

# ---- release ---------------------------------------------------------------
reset
foreign=$(gh_runner someone-elses-runner offline false)
lookalike=$(gh_runner aap-w-1-9-deadbeef offline false)
l1=$(new_lease)
run_broker "$(lease_req "${l1}" 1 1 "$(new_res)")"
expect "lease 1" issued ok
r1=$(out_field .runner_id)
n1=$(nonce)
run_broker "$(small_req release_request "${l1}" "${n1}")"
expect "release" deregistered ok
[[ "$(cat "${T}/gh/deleted")" == "${r1}" ]] || fail "release deleted $(cat "${T}/gh/deleted"); want ${r1}"
[[ "$(ledger "${l1}" '.state + " " + .outcome')" == "released deregistered" && ! -e "${T}/state/open/${l1}" ]] \
  || fail "release did not close the lease"
[[ "$(last_audit '[.op, .outcome, .reason, .runner_id] | join(" ")')" == "release deregistered ok ${r1}" ]] || fail "release audit"
before=$(calls ' ')
run_broker "$(small_req release_request "${l1}")"
expect "second release" already_gone ok
[[ "$(calls ' ')" -eq "${before}" ]] || fail "a release of a released lease called GitHub"
run_broker "$(small_req release_request "${l1}" "${n1}")"
expect "release with a used nonce" refused replay
run_broker "$(small_req release_request "$(new_lease)")"
expect "release of an unknown lease" refused not_found
run_broker "$(small_req release_request "${l1}" "" -400)"
expect "skewed release" refused clock_skew
# GitHub removed the runner itself (an ephemeral runner after its job).
l2=$(new_lease)
run_broker "$(lease_req "${l2}" 2 1 "$(new_res)")"
expect "lease 2" issued ok
gh_forget "$(out_field .runner_id)"
run_broker "$(small_req release_request "${l2}")"
expect "release of a runner GitHub removed" already_gone ok
[[ "$(ledger "${l2}" .state)" == released ]] || fail "already_gone did not close the lease"
# DELETE refused (a running job), then accepted with a new nonce.
l3=$(new_lease)
run_broker "$(lease_req "${l3}" 3 1 "$(new_res)")"
expect "lease 3" issued ok
r3=$(out_field .runner_id)
echo 422 > "${T}/gh/delete_code"
run_broker "$(small_req release_request "${l3}")"
expect "release GitHub refused" retry github_error
echo 403 > "${T}/gh/delete_code"
run_broker "$(small_req release_request "${l3}")"
expect "release rate limited" retry rate_limited
[[ "$(ledger "${l3}" .state)" == issued && -e "${T}/state/open/${l3}" ]] || fail "a failed release closed the lease"
rm -f "${T}/gh/delete_code"
run_broker "$(small_req release_request "${l3}")"
expect "release retried" deregistered ok
[[ "$(tail -n 1 "${T}/gh/deleted")" == "${r3}" ]] || fail "the retried release deleted another runner"
jq -e --argjson a "${foreign}" --argjson b "${lookalike}" '[.[].id] | index($a) != null and index($b) != null' \
  "${T}/gh/runners.json" >/dev/null || fail "a runner the ledger does not name was deleted"
[[ "$(grep -c . "${T}/gh/deleted")" -eq 2 ]] || fail "unexpected deletes: $(cat "${T}/gh/deleted")"
echo "release by lease id only ok"

# ---- ledger writes that fail -------------------------------------------------
# The nonce check, the nonce write and the close each fail once: exit 1, no
# response, the lease still issued and open, no temp file left.
reset
lid=$(new_lease)
run_broker "$(lease_req "${lid}" 1 1 "$(new_res)")"
expect "lease for the write failures" issued ok
sum=$(sha256sum < "${T}/state/leases/${lid}.json")
for filter in 'any(.nonces' '.nonces = (' '.closed_at = $at'; do
  printf '%s' "${filter}" > "${T}/jq_fail"
  run_broker "$(small_req release_request "${lid}")"
  rm -f "${T}/jq_fail"
  [[ "${RC}" -eq 1 && -z "${OUT}" ]] || fail "a failed ledger write (${filter}) gave exit ${RC} and output ${OUT}"
  # The close runs after the nonce write, so only the nonce cases keep every byte.
  [[ "${filter}" == '.closed_at = $at' || "$(sha256sum < "${T}/state/leases/${lid}.json")" == "${sum}" ]] \
    || fail "a failed ledger write (${filter}) changed the lease: $(cat "${T}/state/leases/${lid}.json")"
  [[ "$(ledger "${lid}" .state)" == issued && -e "${T}/state/open/${lid}" ]] \
    || fail "a failed ledger write (${filter}) lost the lease: $(cat "${T}/state/leases/${lid}.json")"
  [[ -z "$(find "${T}/state" -name '*.tmp' -print -quit)" ]] || fail "a failed ledger write (${filter}) left a temp file"
done
# The failed close came after GitHub deleted the runner: the next release closes it.
run_broker "$(small_req release_request "${lid}")"
expect "release after a failed close" already_gone ok
[[ "$(ledger "${lid}" .state)" == released ]] || fail "the release after a failed close did not close the lease"
# Any unexpected tool failure exits 1, never a status a caller could read as a bad request.
printf '%s' 'kind: "audit"' > "${T}/jq_fail"
run_broker "$(small_req status_request "$(new_lease)")"
rm -f "${T}/jq_fail"
[[ "${RC}" -eq 1 && -z "${OUT}" ]] || fail "a failed audit write gave exit ${RC} and output ${OUT}"
echo "failed ledger writes ok"

# ---- status ----------------------------------------------------------------
reset
s1=$(new_lease)
run_broker "$(lease_req "${s1}" 1 1 "$(new_res)")"
expect "status lease" issued ok
sr=$(out_field .runner_id)
gh_set "${sr}" online true
n1=$(nonce)
run_broker "$(small_req status_request "${s1}" "${n1}")"
expect "status busy" ok ok
[[ "$(out_field '.runner | [.status, .busy] | map(tostring) | join(" ")')" == "online true" ]] || fail "status: ${OUT}"
[[ "$(last_audit '[.op, .outcome, .runner_id] | map(tostring) | join(" ")')" == "status online ${sr}" ]] || fail "status audit"
run_broker "$(small_req status_request "${s1}" "${n1}")"
expect "status with a used nonce" refused replay
gh_set "${sr}" offline false
run_broker "$(small_req status_request "${s1}")"
expect "status idle" ok ok
[[ "$(out_field '.runner | [.status, .busy] | map(tostring) | join(" ")')" == "offline false" ]] || fail "status: ${OUT}"
echo 500 > "${T}/gh/get_code"
run_broker "$(small_req status_request "${s1}")"
expect "status while GitHub fails" refused github_error
[[ "$(out_field .runner)" == null ]] || fail "a refused status carries runner state"
rm -f "${T}/gh/get_code"
[[ "$(ledger "${s1}" .state)" == issued && "$(runner_count)" -eq 1 ]] || fail "status changed the lease or a runner"
run_broker "$(small_req status_request "$(new_lease)")"
expect "status of an unknown lease" refused not_found
run_broker "$(small_req release_request "${s1}")"
expect "release after status" deregistered ok
before=$(calls ' ')
run_broker "$(small_req status_request "${s1}")"
expect "status after release" ok ok
[[ "$(out_field '.runner | [.status, .busy] | map(tostring) | join(" ")')" == "absent false" && "$(calls ' ')" -eq "${before}" ]] \
  || fail "status of a released lease: ${OUT}"
# A lease still pending (crash before issued) is looked up by its derived name.
seed l-00000000000000000000000000000001 pending aap-w-1-7-00000001 - $(($(date -u +%s) + 600))
pr=$(gh_runner aap-w-1-7-00000001 online false)
run_broker "$(small_req status_request l-00000000000000000000000000000001)"
expect "status of a pending lease" ok ok
[[ "$(out_field .runner.status)" == online ]] || fail "pending status: ${OUT}"
[[ "$(calls 'GET /orgs/example-org/actions/runners?name=aap-w-1-7-00000001')" -eq 1 ]] || fail "the pending runner was not looked up by name"
gh_forget "${pr}"
echo "status ok"

# ---- sweep -----------------------------------------------------------------
reset
past=$(($(date -u +%s) - 60))
future=$(($(date -u +%s) + 600))
x1=$(gh_runner aap-w-1-1-11111111 offline false)
seed l-11111111111111111111111111111111 pending aap-w-1-1-11111111 - "${past}"
seed l-22222222222222222222222222222222 pending aap-w-2-1-22222222 - "${past}"
x3=$(gh_runner aap-w-3-1-33333333 offline false)
seed l-33333333333333333333333333333333 issued aap-w-3-1-33333333 "${x3}" "${past}"
x4=$(gh_runner aap-w-4-1-44444444 online true)
seed l-44444444444444444444444444444444 issued aap-w-4-1-44444444 "${x4}" "${past}"
x5=$(gh_runner aap-w-5-1-55555555 offline true)
seed l-55555555555555555555555555555555 issued aap-w-5-1-55555555 "${x5}" "${past}"
x6=$(gh_runner aap-w-1-2-66666666 online false)
seed l-66666666666666666666666666666666 issued aap-w-1-2-66666666 "${x6}" "${past}"
x7=$(gh_runner aap-w-2-2-77777777 offline false)
seed l-77777777777777777777777777777777 issued aap-w-2-2-77777777 "${x7}" "${future}"
seed l-88888888888888888888888888888888 issued aap-w-3-2-88888888 999 "${past}"
# A malformed request does not sweep, and a spent budget stops it.
run_broker "$(jq -c '.issued_at = "now"' <<< "${release_base}")"
expect "malformed request" refused malformed
run_broker "$(small_req status_request "$(new_lease)")" TEST_SWEEP_SECONDS=0
expect "status with no sweep budget left" refused not_found
[[ "$(calls ' ')" -eq 0 && ! -e "${T}/gh/deleted" ]] || fail "a malformed request or a spent budget swept"
# The budgets here only keep a slow machine from cutting the run short.
run_broker "$(small_req status_request "$(new_lease)")" TEST_SWEEP_SECONDS=120 TEST_RUN_LIMIT=600
expect "status that triggers the sweep" refused not_found
[[ "$(sort -n "${T}/gh/deleted" | tr '\n' ' ')" == "${x1} ${x3} " ]] || fail "the sweep deleted $(tr '\n' ' ' < "${T}/gh/deleted"); want ${x1} ${x3}"
for lid in l-11111111111111111111111111111111 l-22222222222222222222222222222222 \
  l-33333333333333333333333333333333 l-88888888888888888888888888888888; do
  [[ "$(ledger "${lid}" .state)" == released && ! -e "${T}/state/open/${lid}" ]] || fail "the sweep did not close ${lid}"
done
for lid in l-44444444444444444444444444444444 l-55555555555555555555555555555555 \
  l-66666666666666666666666666666666 l-77777777777777777777777777777777; do
  [[ "$(ledger "${lid}" .state)" == issued && -e "${T}/state/open/${lid}" ]] || fail "the sweep touched ${lid}"
done
jq -e --argjson a "${x4}" --argjson b "${x5}" --argjson c "${x6}" --argjson d "${x7}" \
  '[.[].id] | (index($a) and index($b) and index($c) and index($d)) != null' "${T}/gh/runners.json" >/dev/null \
  || fail "the sweep deleted a busy, online or unexpired runner"
[[ "$(grep -c '"op":"expire"' "${T}/log/broker-audit.jsonl")" -eq 4 ]] || fail "expected 4 expire audit lines"
grep -q "\"op\":\"expire\".*\"outcome\":\"deregistered\".*\"runner_id\":${x1}" "${T}/log/broker-audit.jsonl" || fail "no expire audit for ${x1}"
# Lookup fails: the pending lease stays open for the next run.
seed l-99999999999999999999999999999999 pending aap-w-4-2-99999999 - "${past}"
echo 500 > "${T}/gh/list_code"
run_broker "$(small_req status_request "$(new_lease)")" TEST_SWEEP_SECONDS=120 TEST_RUN_LIMIT=600
expect "status while the runner list fails" refused not_found
[[ "$(ledger l-99999999999999999999999999999999 .state)" == pending ]] || fail "a failed lookup closed a lease"
[[ "$(last_audit '[.op, .outcome, .reason] | join(" ")')" == "status refused not_found" ]] || fail "status audit after sweep"
grep -q '"op":"expire".*"outcome":"retry","reason":"github_error"' "${T}/log/broker-audit.jsonl" || fail "no retry audit for a failed sweep"
rm -f "${T}/gh/list_code"
# The budget is checked before every GitHub call: a lookup that uses it up
# stops the sweep before the delete. A 9 s lookup outlasts the 8 s budget; the
# token mint before it may take up to 7 s on a slow machine.
reset
seed l-12121212121212121212121212121212 pending aap-w-1-3-12121212 - "${past}"
xs=$(gh_runner aap-w-1-3-12121212 offline false)
echo 9 > "${T}/gh/list_sleep"
run_broker "$(small_req status_request "$(new_lease)")" TEST_SWEEP_SECONDS=8
rm -f "${T}/gh/list_sleep"
expect "status after a slow sweep lookup" refused not_found
[[ "$(calls 'runners?name=aap-w-1-3-12121212')" -eq 1 && ! -e "${T}/gh/deleted" ]] \
  || fail "the sweep called GitHub after its budget ran out: $(tr '\n' ';' < "${T}/gh/calls")"
[[ "$(ledger l-12121212121212121212121212121212 .state)" == pending ]] || fail "the cut sweep closed the lease"
gh_forget "${xs}"
echo "sweep ok"

# ---- unavailable and failing brokers ---------------------------------------
reset
lid=$(new_lease)
run_broker "$(lease_req "${lid}" 1 1 "$(new_res)")" TEST_CONF_FAIL=1
[[ "${RC}" -eq 1 && -z "${OUT}" && ! -e "${T}/state" && "$(calls ' ')" -eq 0 ]] \
  || fail "an invalid config gave exit ${RC}, output, state or GitHub calls"
# The ledger lock is held past the wait: exit 1, no output, no lease recorded.
mkdir -p "${T}/state"
flock "${T}/state/lock" sleep 3 &
holder=$!
for _ in {1..100}; do
  flock -n "${T}/state/lock" true || break
  sleep 0.05
done
run_broker "$(lease_req "${lid}" 1 1 "$(new_res)")" TEST_LOCK_WAIT=1
[[ "${RC}" -eq 1 && -z "${OUT}" && ! -e "${T}/state/leases/${lid}.json" && "$(calls ' ')" -eq 0 ]] \
  || fail "a busy lock gave exit ${RC}, output, a lease or GitHub calls"
wait "${holder}"
# No installation token: refused and closed; nothing was created.
touch "${T}/gh/token_fail"
lid=$(new_lease)
run_broker "$(lease_req "${lid}" 1 1 "$(new_res)")"
expect "no installation token" refused github_error
rm -f "${T}/gh/token_fail"
[[ "$(ledger "${lid}" .state)" == refused && ! -e "${T}/state/open/${lid}" && "$(calls generate-jitconfig)" -eq 0 ]] \
  || fail "a failed token mint left an open lease or called generate-jitconfig"
# GitHub refusals: closed, no runner, no delete. Each takes the next slot 2
# generation, since a refused lease still used its generation.
gen=1
for mode in 404:github_error 409:github_error 422:github_error 429:rate_limited 403:rate_limited; do
  echo "${mode%%:*}" > "${T}/gh/jit_mode"
  lid=$(new_lease)
  run_broker "$(lease_req "${lid}" 2 "${gen}" "$(new_res)")"
  gen=$((gen + 1))
  expect "generate-jitconfig ${mode%%:*}" refused "${mode#*:}"
  [[ "$(ledger "${lid}" .state)" == refused && ! -e "${T}/state/open/${lid}" ]] || fail "${mode}: the lease stayed open"
  case "${mode%%:*}" in
    404 | 422) [[ ! -e "${T}/state/group-id" ]] || fail "${mode}: the group cache was kept" ;;
    *) [[ "$(cat "${T}/state/group-id")" == 7 ]] || fail "${mode}: the group cache was dropped" ;;
  esac
done
[[ ! -e "${T}/gh/deleted" && "$(runner_count)" -eq 0 ]] || fail "a refused generate-jitconfig left or deleted a runner"
# A server error and no runner listed: GitHub may still finish the create, so
# the lease stays pending and open. Release answers retry until expires_at,
# then closes it.
echo 502 > "${T}/gh/jit_mode"
lid=$(new_lease)
run_broker "$(lease_req "${lid}" 3 1 "$(new_res)")"
expect "generate-jitconfig 502" refused github_error
[[ "$(ledger "${lid}" .state)" == pending && -e "${T}/state/open/${lid}" ]] || fail "an uncertain create closed its lease"
run_broker "$(small_req release_request "${lid}")"
expect "release of an uncertain create before expiry" retry github_error
[[ "$(ledger "${lid}" .state)" == pending && -e "${T}/state/open/${lid}" ]] || fail "a release before expiry closed an uncertain create"
age_lease "${lid}"
run_broker "$(small_req release_request "${lid}")"
expect "release of an uncertain create after expiry" already_gone ok
[[ "$(ledger "${lid}" .state)" == released ]] || fail "an expired uncertain create stayed open"
# Created, but the reply is unusable: deleted by id before answering.
echo bad-jit > "${T}/gh/jit_mode"
lid=$(new_lease)
run_broker "$(lease_req "${lid}" 3 2 "$(new_res)")"
expect "unusable generate-jitconfig reply" refused github_error
[[ "$(runner_count)" -eq 0 && "$(ledger "${lid}" .state)" == refused ]] || fail "the runner of an unusable reply was kept"
# Created, but the reply was lost: found by the derived name, deleted.
echo lost > "${T}/gh/jit_mode"
lid=$(new_lease)
res=$(new_res)
run_broker "$(lease_req "${lid}" 4 1 "${res}")"
expect "lost generate-jitconfig reply" refused github_error
[[ "$(runner_count)" -eq 0 && "$(ledger "${lid}" .state)" == refused ]] || fail "the runner of a lost reply was kept"
[[ "$(calls "GET /orgs/example-org/actions/runners?name=aap-w-4-1-${res:2:8}")" -eq 1 ]] || fail "the lost runner was not looked up by its derived name"
# Lost reply and the lookup fails: the lease stays open and the next
# release_request deletes the runner by its derived name.
echo 500 > "${T}/gh/list_code"
lid=$(new_lease)
res=$(new_res)
run_broker "$(lease_req "${lid}" 5 1 "${res}")"
expect "lost reply, lookup failed" refused github_error
[[ "$(ledger "${lid}" .state)" == pending && -e "${T}/state/open/${lid}" && "$(runner_count)" -eq 1 ]] \
  || fail "an unconfirmed runner did not keep its lease open"
rm -f "${T}/gh/list_code" "${T}/gh/jit_mode"
run_broker "$(small_req release_request "${lid}")"
expect "release of the pending lease" deregistered ok
[[ "$(runner_count)" -eq 0 && "$(ledger "${lid}" .state)" == released ]] || fail "the pending lease's runner was not deleted"
# The broker is killed while GitHub hangs (wsl.exe timed out): nothing on
# stdout, the lease stays pending, and its release closes it.
echo hang > "${T}/gh/jit_mode"
lid=$(new_lease)
lease_req "${lid}" 1 2 "$(new_res)" > "${T}/req"
before=$(calls 'generate-jitconfig')
env TMPDIR="${T}/tmp" BROKER="${broker}" bash "${T}/driver.sh" < "${T}/req" > "${N}/killed.out" 2>> "${T}/stderr.all" &
victim=$!
for _ in {1..200}; do
  [[ "$(calls 'generate-jitconfig')" -le "${before}" ]] || break
  sleep 0.05
done
[[ "$(calls 'generate-jitconfig')" -gt "${before}" ]] || fail "the broker never reached generate-jitconfig"
kill -9 "${victim}"
wait "${victim}" 2>/dev/null || true
[[ ! -s "${N}/killed.out" ]] || fail "a killed broker printed a response"
rm -f "${N}/killed.out" "${T}/gh/jit_mode"
[[ "$(ledger "${lid}" .state)" == pending && -e "${T}/state/open/${lid}" ]] || fail "the killed broker's lease is not pending"
run_broker "$(small_req release_request "${lid}")"
expect "release after a killed broker, before expiry" retry github_error
age_lease "${lid}"
run_broker "$(small_req release_request "${lid}")"
expect "release after a killed broker" already_gone ok
[[ "$(ledger "${lid}" .state)" == released && ! -e "${T}/state/open/${lid}" ]] || fail "the killed broker's lease stayed open"
# Past the run's time budget no create starts: refused and closed, and
# generate-jitconfig is never called (the token mint takes 15 s of a 25 s limit).
echo 15 > "${T}/gh/token_sleep"
printf '7\n' > "${T}/state/group-id"
lid=$(new_lease)
before=$(calls generate-jitconfig)
run_broker "$(lease_req "${lid}" 2 50 "$(new_res)")" TEST_RUN_LIMIT=25
rm -f "${T}/gh/token_sleep"
expect "lease past the time budget" refused github_error
[[ "$(calls generate-jitconfig)" -eq "${before}" && "$(ledger "${lid}" .state)" == refused && ! -e "${T}/state/open/${lid}" ]] \
  || fail "a lease past the time budget called generate-jitconfig or stayed open"
# A state or log directory that is a symlink: exit 1, nothing written through it.
reset
mkdir -p "${T}/elsewhere"
ln -s "${T}/elsewhere" "${T}/log"
run_broker "$(lease_req "$(new_lease)" 1 1 "$(new_res)")"
[[ "${RC}" -eq 1 && -z "${OUT}" && -z "$(ls -A "${T}/elsewhere")" && "$(calls ' ')" -eq 0 ]] \
  || fail "a symlinked log directory gave exit ${RC}, output, files or GitHub calls"
rm -f "${T}/log"
rm -rf "${T}/elsewhere"
echo "unavailable and failing brokers ok"

# ---- audit rotation ---------------------------------------------------------
reset
for _ in 1 2 3 4; do
  run_broker "$(small_req status_request "$(new_lease)")" TEST_AUDIT_MAX=600
  expect "status for rotation" refused not_found
done
[[ -f "${T}/log/broker-audit.jsonl.1" && "$(stat -c %a "${T}/log/broker-audit.jsonl.1")" == 600 ]] || fail "the audit log was not rotated to .1"
[[ ! -e "${T}/log/broker-audit.jsonl.2" ]] || fail "more than one rotated audit log"
echo "audit rotation ok"

# ---- secrets ---------------------------------------------------------------
rm -f "${T}/sampling"
kill "${sampler}" 2>/dev/null || true
wait "${sampler}" 2>/dev/null || true
sampler=""
scan_secrets
[[ ! -s "${T}/argv-hits" ]] || fail "a synthetic secret was in a process's argv"
[[ "$(wc -c < "${T}/snaps")" -gt 100 ]] || fail "argv was sampled only $(wc -c < "${T}/snaps") times"
echo "secret marker absent from argv, stderr, audit, ledger and temp files ok"
echo "worker_auth_test ok"
