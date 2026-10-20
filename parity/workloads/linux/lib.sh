# shellcheck shell=bash
# Shared helpers for the P18 Linux, Actions and xwin workloads. A workload's run.sh sources this file, calls
# wl_start "$@", does its work and calls wl_end. Every tool line goes to stdout (the harness log) with the work and
# repository paths replaced by <work> and <repo> and ANSI colours removed, so logs and first causal errors compare
# across machines. Observed facts go to $PARITY_OBS_DIR (or the work folder), never into the hashed artifacts.
#
#   wl_start --work DIR --id ID [--sabotage NAME] [--<name> VALUE]...   sets WORK ID SABOTAGE ARG_<name> REPO
#   oracle KEY / oracle_list KEY / oracle_keys PREFIX                   cited oracle values (wl.py flat)
#   fact NAME OBSERVED EXPECTED / fact_re NAME OBSERVED REGEX / observe NAME VALUE
#   run TOOL ARG...       logs and runs a tool; dies on a nonzero exit. try_run returns the code instead.
#                         Both leave the normalized output in OUT and the exit code in RC.
#   die MESSAGE           'error: MESSAGE', counted as a failure, ends the workload
#   report LINE...        writes report.txt (the hashed artifact: no versions, paths or times)
#   wl_cleanup            if the workload defines it, wl_end calls it first (also after die)
# run, try_run, die and fact change this shell's state: never call them inside $(...). The helpers themselves need
# nothing from PATH once wl_start ran, so a sabotage may empty PATH.

set -uo pipefail
shopt -s extglob

WL_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "${WL_LIB_DIR}/../../.." && pwd)
WORK='' ID='' SABOTAGE='' OUT='' RC=0
WL_FAILS=()
WL_ESC=$'\x1b'
WL_PY=$(command -v python3)
WL_AWK=$(command -v awk)
# a failing tool's output line that names the cause, for the error line run writes
WL_CAUSE='error|fail|cannot|can.t|not found|unable|denied|refused|invalid|no such|problem|certificate'

line() { printf '%s\n' "$1"; }

norm() {
  local s=$1
  [ -n "${WORK}" ] && s=${s//"${WORK}"/<work>}
  s=${s//"${REPO}"/<repo>}
  s=${s//"${WL_ESC}"\[*([0-9;?])[A-Za-z]/}
  printf '%s' "${s}"
}

oracle() {
  # usually called inside $(...): a missing key is recorded in a file that wl_end counts as a failure
  "${WL_AWK}" -F '\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); printf "%s", $0; f = 1; exit } END { exit !f }' "${WL_ORACLE}" || {
    echo "$1" >> "${WORK}/tmp/oracle-missing"
    echo "error: oracle has no key $1" >&2
  }
}

oracle_list() { "${WL_AWK}" -F '\t' -v k="$1[]" '$1 == k { sub(/^[^\t]*\t/, ""); print }' "${WL_ORACLE}"; }

# member names under PREFIX/ (one level)
oracle_keys() {
  "${WL_AWK}" -F '\t' -v p="$1/" 'index($1, p) == 1 { k = substr($1, length(p) + 1); sub(/\[\]$/, "", k); if (k !~ /\// && !s[k]++) print k }' "${WL_ORACLE}"
}

_record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3//$'\t'/ }" "${4//$'\t'/ }" >> "${WL_FACTS}"; }

fact() {
  local name=$1 obs=$2 exp=$3
  obs=${obs//$'\n'/,} exp=${exp//$'\n'/,}
  if [ "${obs}" = "${exp}" ]; then
    _record "${name}" 1 "${exp}" "${obs}"
    line "ok   ${name} = $(norm "${obs}")"
  else
    _record "${name}" 0 "${exp}" "${obs}"
    WL_FAILS+=("${name}")
    line "error: oracle ${name} expected '${exp}' observed '$(norm "${obs}")'"
  fi
}

fact_re() {
  local name=$1 obs=$2 re=$3
  obs=${obs//$'\n'/,}
  if [[ ${obs} =~ ${re} ]]; then
    _record "${name}" 1 "${re}" "${obs}"
    line "ok   ${name} = $(norm "${obs}")"
  else
    _record "${name}" 0 "${re}" "${obs}"
    WL_FAILS+=("${name}")
    line "error: oracle ${name} expected /${re}/ observed '$(norm "${obs}")'"
  fi
}

observe() { _record "$1" '' '' "${2//$'\n'/,}"; line "obs  $1 = $(norm "${2//$'\n'/,}")"; }

die() {
  WL_FAILS+=(exception)
  line "error: $(norm "$1")"
  wl_end
}

try_run() {
  line "> $(norm "${1##*/}${2+ ${*:2}}")"
  if [[ $1 != */* ]] && ! command -v "$1" > /dev/null; then
    OUT="$1: not found on PATH" RC=127
    return 127
  fi
  "$@" > "${WORK}/tmp/out.txt" 2>&1 < /dev/null
  RC=$?
  OUT=$(norm "$(< "${WORK}/tmp/out.txt")")
  [ -z "${OUT}" ] || printf '%s\n' "${OUT}"
  return "${RC}"
}

run() {
  try_run "$@" && return 0
  local l cause='' last=''
  while IFS= read -r l; do
    [[ ${l} =~ [^[:space:]] ]] || continue
    last=${l}
    [ -n "${cause}" ] || [[ ! ${l,,} =~ ${WL_CAUSE} ]] || cause=${l}
  done <<< "${OUT}"
  cause=${cause:-${last}}
  die "${1##*/} exited with code ${RC}${cause:+: ${cause}}"
}

report() {
  printf '%s\n' "$@" > "${WORK}/report.txt"
  local l
  for l in "$@"; do line "report ${l}"; done
}

# require_actions: the workload changes or queries machine state (docker, systemd, sudo) and only runs in a job
require_actions() { [ "${GITHUB_ACTIONS:-}" = true ] || die 'not inside a GitHub Actions job (GITHUB_ACTIONS is not true)'; }

wl_start() {
  while [ $# -gt 0 ]; do
    case $1 in
      --work) WORK=$2 ;;
      --id) ID=$2 ;;
      --sabotage) SABOTAGE=$2 ;;
      --*) local n=${1#--}; declare -g "ARG_${n//-/_}=$2" ;;
      *) echo "error: unexpected argument $1" >&2; exit 2 ;;
    esac
    shift 2
  done
  [ -d "${WORK}" ] && [ -n "${ID}" ] || { echo 'error: --work DIR and --id ID are required' >&2; exit 2; }
  WORK=$(cd "${WORK}" && pwd -P)
  WL_OBS_DIR=${PARITY_OBS_DIR:-${WORK}}
  mkdir -p "${WORK}/tmp" "${WL_OBS_DIR}"
  export TMPDIR="${WORK}/tmp" XDG_CACHE_HOME="${WORK}/tmp/cache"
  WL_PROFILE=${PARITY_PROFILE:-ubuntu-24.04}
  WL_FACTS="${WORK}/tmp/facts.tsv"
  WL_ORACLE="${WORK}/tmp/oracle.tsv"
  : > "${WL_FACTS}"
  "${WL_PY}" -B -I "${WL_LIB_DIR}/wl.py" flat "${WL_LIB_DIR}/oracle/${WL_PROFILE}.json" > "${WL_ORACLE}" \
    || { echo "error: cannot read the oracle for profile ${WL_PROFILE}" >&2; exit 2; }
  line "workload ${ID} profile=${WL_PROFILE} sabotage=${SABOTAGE:-none}"
  cd "${WORK}" || exit 2
}

wl_end() {
  local code=1 k
  if declare -F wl_cleanup > /dev/null; then wl_cleanup; fi
  if [ -f "${WORK}/tmp/oracle-missing" ]; then
    while read -r k; do WL_FAILS+=("oracle-key:${k}"); done < "${WORK}/tmp/oracle-missing"
  fi
  if [ "${#WL_FAILS[@]}" -eq 0 ]; then
    code=0
    line "workload ${ID}: all oracle checks met"
  else
    line "workload ${ID}: ${#WL_FAILS[@]} oracle check(s) not met"
  fi
  "${WL_PY}" -B -I "${WL_LIB_DIR}/wl.py" observed "${WL_FACTS}" "${WL_OBS_DIR}/${ID//\//__}.observed.json" "${ID}" \
    "${WL_PROFILE}" "${SABOTAGE}" "${WORK}" "$(printf '%s\n' "${WL_FAILS[@]}")"
  exit "${code}"
}
