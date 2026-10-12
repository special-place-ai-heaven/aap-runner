#!/bin/bash
# Print the aap-runner lockdown evidence. Run as root inside the distro,
# after app.pem and manager.conf are in place:
#   wsl.exe -d aap-runner -u root -- bash /usr/local/sbin/aap-runner-evidence
# Exit status is non-zero when an observation is missing or wrong.
# --self-check only parses a route gateway and a memory limit. No Docker.
set -euo pipefail

# shellcheck source=labels.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/labels.sh"
# Exact match for AAP_RUNNER_LABELS_VERSION in labels.sh.
require_labels_version 1 || exit 1

route_gateway() {
  local gw_hex="$1"
  [[ "${gw_hex}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 1
  printf '%d.%d.%d.%d\n' \
    "0x${gw_hex:6:2}" "0x${gw_hex:4:2}" "0x${gw_hex:2:2}" "0x${gw_hex:0:2}"
}

# ponytail: same byte grammar as manager.sh AAP_JOB_MEMORY (integer plus one suffix).
memory_bytes() {
  local v="$1" n suffix
  [[ "${v}" =~ ^([1-9][0-9]*)([bBkKmMgG]?)$ ]] || return 1
  n=${BASH_REMATCH[1]}
  suffix=${BASH_REMATCH[2]}
  case "${suffix}" in
    b | B | "") printf '%s\n' "${n}" ;;
    k | K) printf '%s\n' $((n * 1024)) ;;
    m | M) printf '%s\n' $((n * 1024 * 1024)) ;;
    g | G) printf '%s\n' $((n * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac
}

cpu_nanos() {
  local v="$1"
  [[ "${v}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v n="${v}" 'BEGIN { if (!(n > 0)) exit 1; printf "%.0f\n", n * 1000000000 }'
}

default_route_hex() {
  awk '$2 == "00000000" { print $3; exit }' /proc/net/route
}

# Same sentences as bootstrap.sh. Exit status of sudo -l is not the check.
sudo_listing_grants() {
  local text="$1"
  if printf '%s\n' "${text}" | grep -q 'may run the following'; then
    return 0
  fi
  if printf '%s\n' "${text}" | grep -q 'not allowed to run sudo'; then
    return 1
  fi
  return 2
}

# findmnt -n -o FSTYPE,TARGET lines. drvfs and 9p are Windows drives.
# /mnt/wsl and /mnt/wslg are tmpfs and are not drives.
windows_drive_present() {
  local fstype _
  while read -r fstype _; do
    [[ -z "${fstype}" ]] && continue
    case "${fstype}" in
      drvfs | 9p) return 0 ;;
    esac
  done
  return 1
}

host_mounts_empty() {
  local mounts="$1" binds="$2"
  [[ "${mounts}" == "[]" || "${mounts}" == "null" || -z "${mounts}" ]] || return 1
  [[ "${binds}" == "[]" || "${binds}" == "null" || -z "${binds}" ]] || return 1
}

# Same window as the manager: configured size -10..+4. Default 60 is CRRR.
# Default shares are 1024. This only weights containers inside the WSL VM.
CPU_SHARES=512
WORK_DISK_GIB=""
WORK_DISK_MIN_GB=""
WORK_DISK_MAX_GB=""

apply_disk_window() {
  local gib="${1:-60}"
  if [[ ! "${gib}" =~ ^[1-9][0-9]*$ ]] || [[ "${gib}" -lt 20 || "${gib}" -gt 512 ]]; then
    echo "refusing: AAP_WORK_DISK_GIB=${gib} is not 20..512" >&2
    return 1
  fi
  WORK_DISK_GIB=${gib}
  WORK_DISK_MIN_GB=$((gib - 10))
  if [[ "${WORK_DISK_MIN_GB}" -lt 1 ]]; then
    WORK_DISK_MIN_GB=1
  fi
  WORK_DISK_MAX_GB=$((gib + 4))
}

read_work_disk_gib() {
  local line key val gib=""
  if [[ -r /etc/aap-runner/manager.conf ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
        '' | \#*) continue ;;
      esac
      key=${line%%=*}
      val=${line#*=}
      if [[ "${key}" == "AAP_WORK_DISK_GIB" && -n "${val}" ]]; then
        gib=${val}
      fi
    done < /etc/aap-runner/manager.conf
  fi
  [[ -z "${gib}" ]] && gib=60
  apply_disk_window "${gib}"
}

# Size is not identity. The mount's device must differ from / and its UUID
# must be the work disk written at install.
work_mount_matches() {
  local dev="$1" root_dev="$2" mount_uuid="$3" expect_uuid="$4"
  [[ -n "${dev}" && -n "${root_dev}" && "${dev}" != "${root_dev}" ]] || return 1
  [[ "${expect_uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
  [[ "${mount_uuid}" == "${expect_uuid}" ]]
}

# aap-runner has automount off, so wsl.exe and the Windows profile are
# captured by evidence-host.sh and passed in as files. Printing them is
# not a pass: the operator supplied the text and this distro did not verify it.
# A missing version file or a missing .wslconfig capture is incomplete.
# state=absent is a complete capture of a missing .wslconfig.
host_bundle_ok() {
  local version_file="$1" state="$2" config_file="$3"
  [[ -n "${version_file}" && -f "${version_file}" && -r "${version_file}" ]] || return 1
  case "${state}" in
    absent) return 0 ;;
    present) [[ -n "${config_file}" && -f "${config_file}" && -r "${config_file}" ]] ;;
    *) return 1 ;;
  esac
}

print_host_bundle() {
  local version_file="${1:-${AAP_WSL_VERSION_FILE:-}}"
  local state="${2:-${AAP_WSLCONFIG_STATE:-}}"
  local config_file="${3:-${AAP_WSLCONFIG_FILE:-}}"
  local runners_file="${4:-${AAP_GITHUB_RUNNERS_FILE:-}}"
  echo "HOST-REPORTED (operator-supplied, not verified)"
  if ! host_bundle_ok "${version_file}" "${state}" "${config_file}"; then
    bad "host P0 bundle is incomplete"
    return 1
  fi
  echo "wsl --version:"
  cat "${version_file}"
  echo "wslconfig state=${state}"
  if [[ "${state}" == "present" ]]; then
    cat "${config_file}"
  else
    echo "wslconfig: absent"
  fi
  if [[ -n "${runners_file}" && -f "${runners_file}" && -r "${runners_file}" ]]; then
    echo "GitHub registered runners:"
    cat "${runners_file}"
  else
    echo "GitHub registered runners: not supplied"
  fi
  return 0
}

self_check() {
  local got sample tmp version cfg out rc runners
  labels_self_check
  got=$(route_gateway 010011AC)
  [[ "${got}" == "172.17.0.1" ]]
  got=$(memory_bytes 12g)
  [[ "${got}" == "12884901888" ]]
  got=$(cpu_nanos 6)
  [[ "${got}" == "6000000000" ]]
  if route_gateway nothex; then
    echo "bad gateway hex was accepted" >&2
    return 1
  fi
  if memory_bytes 12gb; then
    echo "bad memory suffix was accepted" >&2
    return 1
  fi
  grant_rc=0
  sudo_listing_grants "User ghrunner is not allowed to run sudo on CRRR65734." || grant_rc=$?
  [[ "${grant_rc}" -eq 1 ]]
  grant_rc=0
  sudo_listing_grants "User ghrunner may run the following commands on CRRR65734:" || grant_rc=$?
  [[ "${grant_rc}" -eq 0 ]]
  if windows_drive_present <<'EOF'
tmpfs /mnt/wsl
tmpfs /mnt/wslg
EOF
  then
    echo "WSL tmpfs under /mnt was treated as a Windows drive" >&2
    return 1
  fi
  if ! windows_drive_present <<'EOF'
drvfs /mnt/c
EOF
  then
    echo "drvfs was not treated as a Windows drive" >&2
    return 1
  fi
  if ! windows_drive_present <<'EOF'
9p /mnt/d
EOF
  then
    echo "9p was not treated as a Windows drive" >&2
    return 1
  fi
  host_mounts_empty '[]' 'null'
  if host_mounts_empty '[{"Source":"/mnt/wsl"}]' 'null'; then
    echo "a host mount was accepted" >&2
    return 1
  fi
  apply_disk_window 60
  [[ "${WORK_DISK_MIN_GB}" == "50" && "${WORK_DISK_MAX_GB}" == "64" ]]
  apply_disk_window 100
  [[ "${WORK_DISK_GIB}" == "100" && "${WORK_DISK_MIN_GB}" == "90" && "${WORK_DISK_MAX_GB}" == "104" ]]
  if apply_disk_window 9; then
    echo "a 9 GiB work disk was accepted" >&2
    return 1
  fi
  if apply_disk_window 513; then
    echo "a 513 GiB work disk was accepted" >&2
    return 1
  fi
  apply_disk_window 512
  [[ "${WORK_DISK_MIN_GB}" == "502" && "${WORK_DISK_MAX_GB}" == "516" ]]
  sample=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
  if ! work_mount_matches /dev/sdb1 /dev/sda "${sample}" "${sample}"; then
    echo "a distinct work-disk device was rejected" >&2
    return 1
  fi
  if work_mount_matches /dev/sda /dev/sda "${sample}" "${sample}"; then
    echo "the distro root device was accepted as the work disk" >&2
    return 1
  fi
  if work_mount_matches /dev/sdb1 /dev/sda "${sample}" bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee; then
    echo "a different filesystem UUID was accepted" >&2
    return 1
  fi
  tmp=$(mktemp -d)
  version="${tmp}/version"
  cfg="${tmp}/wslconfig"
  printf 'WSL version: 2.0.0\n' > "${version}"
  if ! host_bundle_ok "${version}" absent "${cfg}"; then
    echo "an absent .wslconfig with a version file was rejected" >&2
    return 1
  fi
  printf '[wsl2]\nmemory=80GB\n' > "${cfg}"
  if ! host_bundle_ok "${version}" present "${cfg}"; then
    echo "a present .wslconfig was rejected" >&2
    return 1
  fi
  if host_bundle_ok "" present "${cfg}"; then
    echo "a missing wsl --version file was accepted" >&2
    return 1
  fi
  if host_bundle_ok "${version}" present "${tmp}/missing"; then
    echo "a missing .wslconfig was accepted as present" >&2
    return 1
  fi
  if host_bundle_ok "${version}" "" "${cfg}"; then
    echo "an empty wslconfig state was accepted" >&2
    return 1
  fi
  bad() {
    printf 'FAIL %s\n' "$1" >&2
  }
  rc=0
  out=$(print_host_bundle "" "" "" 2>&1) || rc=$?
  if [[ "${rc}" -eq 0 || "${out}" != *"host P0 bundle is incomplete"* ]]; then
    echo "a missing host P0 bundle was accepted" >&2
    return 1
  fi
  [[ "${out}" == *"HOST-REPORTED (operator-supplied, not verified)"* ]]
  rc=0
  out=$(print_host_bundle "${version}" "" "" 2>&1) || rc=$?
  if [[ "${rc}" -eq 0 || "${out}" != *"host P0 bundle is incomplete"* ]]; then
    echo "a missing .wslconfig capture was accepted" >&2
    return 1
  fi
  rc=0
  out=$(print_host_bundle "${version}" absent "${cfg}" 2>&1) || rc=$?
  if [[ "${rc}" -ne 0 || "${out}" == *"host P0 bundle is incomplete"* ]]; then
    echo "an absent .wslconfig was treated as an incomplete bundle" >&2
    return 1
  fi
  [[ "${out}" == *"HOST-REPORTED (operator-supplied, not verified)"* ]]
  [[ "${out}" == *"wslconfig: absent"* ]]
  [[ "${out}" == *"GitHub registered runners: not supplied"* ]]
  runners="${tmp}/runners"
  printf 'GET /orgs/special-place-ai-heaven/actions/runners\naap-crrr\tonline\tself-hosted,linux,crrr\n' > "${runners}"
  out=$(print_host_bundle "${version}" present "${cfg}" "${runners}")
  [[ "${out}" == *"HOST-REPORTED (operator-supplied, not verified)"* ]]
  [[ "${out}" == *"WSL version: 2.0.0"* ]]
  [[ "${out}" == *"memory=80GB"* ]]
  [[ "${out}" == *"aap-crrr"*online*self-hosted,linux,crrr* ]]
  got=$(compose_runner_labels crrr "")
  [[ "${got}" == "self-hosted,linux,crrr" ]]
  labels_line_ok "${got}" crrr
  got=$(compose_runner_labels fresh heavy)
  [[ "${got}" == "self-hosted,linux,fresh,heavy" ]]
  labels_line_ok "${got}" fresh
  if compose_runner_labels "" ""; then
    echo "an empty base label was accepted" >&2
    return 1
  fi
  if compose_runner_labels fresh "heavy,crrr"; then
    echo "extra label crrr was accepted on base fresh" >&2
    return 1
  fi
  rm -rf "${tmp}"
  echo "evidence self-check ok"
}

if [[ "${1:-}" == "--self-check" ]]; then
  self_check
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run evidence as root inside the aap-runner distro" >&2
  exit 1
fi

fail=0
bad() {
  printf 'FAIL %s\n' "$1" >&2
  fail=1
}

section() {
  printf '\n== %s ==\n' "$1"
}

section "kernel"
uname -r

section "host wsl bundle"
# bad already sets fail=1. Keep printing the rest of the evidence.
print_host_bundle || true

section "windows drives"
# WSL injects /mnt/wsl and /mnt/wslg on every distro. A Windows drive is
# drvfs or 9p. The job container's /mnt is checked separately, below.
if ! command -v findmnt >/dev/null 2>&1; then
  bad "findmnt is missing"
  drives=""
else
  drives=$(findmnt -n -o FSTYPE,TARGET -t drvfs,9p 2>/dev/null || true)
fi
printf '%s\n' "${drives:-none}"
if windows_drive_present <<< "${drives}"; then
  bad "a drvfs or 9p Windows drive is mounted"
fi

section "cmd.exe"
if command -v cmd.exe >/dev/null 2>&1; then
  echo "command -v cmd.exe: $(command -v cmd.exe)"
  bad "cmd.exe is on PATH"
else
  echo "command -v cmd.exe: not found"
fi
cmd_rc=0
cmd.exe /c exit 0 >/dev/null 2>&1 || cmd_rc=$?
echo "cmd.exe exit ${cmd_rc}"
if [[ "${cmd_rc}" -eq 0 ]]; then
  bad "cmd.exe ran"
fi

section "nft ruleset"
if ! nft list ruleset; then
  bad "nft list ruleset failed"
fi

section "networkingMode"
if command -v wslinfo >/dev/null 2>&1; then
  net_mode=$(wslinfo --networking-mode 2>&1 | tr -d '\r' || true)
  printf '%s\n' "${net_mode}"
  if printf '%s\n' "${net_mode}" | grep -Eiq '^mirrored$'; then
    bad "networkingMode is mirrored"
  elif [[ -z "${net_mode}" ]]; then
    bad "networkingMode was empty"
  fi
else
  echo "wslinfo: unavailable"
  bad "networkingMode unknown"
fi

section "dockerd ipv6"
ipv6_enabled=$(docker network inspect bridge --format '{{.EnableIPv6}}' 2>&1 || true)
echo "bridge EnableIPv6=${ipv6_enabled}"
if [[ "${ipv6_enabled}" != "false" ]]; then
  bad "dockerd IPv6 is not off"
fi

section "id ghrunner"
if id ghrunner; then
  if [[ "$(id -u ghrunner)" != "1002" ]]; then
    bad "ghrunner uid is not 1002"
  fi
  if id -nG ghrunner | tr ' ' '\n' | grep -qx docker; then
    bad "ghrunner is in the docker group"
  fi
  if id -nG ghrunner | tr ' ' '\n' | grep -qx sudo; then
    bad "ghrunner is in the sudo group"
  fi
  listing=$(sudo -n -l -U ghrunner 2>&1 || true)
  printf '%s\n' "${listing}"
  grant_rc=0
  sudo_listing_grants "${listing}" || grant_rc=$?
  if [[ "${grant_rc}" -ne 1 ]]; then
    bad "ghrunner sudo listing is not a denial"
  fi
else
  bad "ghrunner is missing"
fi

section "stat app.pem and manager.conf"
stat_mode_ok() {
  local path="$1" mode owner
  if [[ ! -e "${path}" ]]; then
    echo "${path}: MISSING"
    bad "${path} is missing"
    return 0
  fi
  stat "${path}"
  mode=$(stat -c '%a' "${path}")
  owner=$(stat -c '%u' "${path}")
  if [[ "${owner}" != "0" || "${mode}" != "400" ]]; then
    bad "${path} is mode ${mode} uid ${owner}; expected root mode 0400"
  fi
}
stat_mode_ok /etc/aap-runner/app.pem
stat_mode_ok /etc/aap-runner/manager.conf

section "runner labels"
runner_base=""
runner_extra=""
runner_configured=""
if [[ -r /etc/aap-runner/manager.conf ]]; then
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      '' | \#*) continue ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    case "${key}" in
      AAP_RUNNER_BASE_LABEL) runner_base=${val} ;;
      AAP_RUNNER_EXTRA_LABELS) runner_extra=${val} ;;
      AAP_RUNNER_LABELS) runner_configured=${val} ;;
    esac
  done < /etc/aap-runner/manager.conf
fi
runner_final=""
if ! runner_final=$(compose_runner_labels "${runner_base}" "${runner_extra}"); then
  bad "AAP_RUNNER_BASE_LABEL is missing or the label line is not self-hosted,linux,<base>[,extras]"
elif [[ -n "${runner_configured}" && "${runner_configured}" != "self-hosted,linux,${runner_base}" ]]; then
  bad "AAP_RUNNER_LABELS=${runner_configured} is not self-hosted,linux,${runner_base}"
elif ! labels_line_ok "${runner_final}" "${runner_base}"; then
  bad "runner labels ${runner_final} are not self-hosted,linux,<base>[,extras]"
else
  echo "runner labels: ${runner_final}"
fi

section "image storage"
work_dev=$(df -P /var/lib/ghrunner 2>/dev/null | awk 'NR==2 { print $1 }' || true)
work_size=$(df -BG --output=size /var/lib/ghrunner 2>/dev/null | awk 'NR==2 { gsub(/G/, "", $1); print $1 }' || true)
if ! read_work_disk_gib; then
  bad "AAP_WORK_DISK_GIB in manager.conf is not 20..512"
fi
root_dev=$(df -P / 2>/dev/null | awk 'NR==2 { print $1 }' || true)
work_uuid=$(findmnt -n -o UUID --target /var/lib/ghrunner 2>/dev/null | tr -d '[:space:]' || true)
expect_uuid=""
if [[ -r /etc/aap-runner/work-disk.uuid ]]; then
  expect_uuid=$(tr -d '[:space:]' < /etc/aap-runner/work-disk.uuid)
fi
echo "work disk dev=${work_dev:-missing} uuid=${work_uuid:-missing} root=${root_dev:-missing} expect_uuid=${expect_uuid:-missing} size=${work_size:-missing}G expect=${WORK_DISK_GIB:-unset}G (${WORK_DISK_MIN_GB:-?}-${WORK_DISK_MAX_GB:-?})"
if ! work_mount_matches "${work_dev}" "${root_dev}" "${work_uuid}" "${expect_uuid}"; then
  bad "/var/lib/ghrunner dev=${work_dev:-missing} uuid=${work_uuid:-missing} is not work-disk.uuid (${expect_uuid:-missing}) distinct from / (${root_dev:-missing})"
fi
if [[ ! "${work_size}" =~ ^[0-9]+$ || -z "${WORK_DISK_MIN_GB}" || "${work_size}" -lt "${WORK_DISK_MIN_GB}" || "${work_size}" -gt "${WORK_DISK_MAX_GB}" ]]; then
  bad "/var/lib/ghrunner is ${work_size:-missing}G; the work disk is ${WORK_DISK_GIB:-unset}G (${WORK_DISK_MIN_GB:-?}-${WORK_DISK_MAX_GB:-?})"
fi
check_on_work() {
  local path="$1" dev
  if [[ ! -e "${path}" ]]; then
    bad "${path} is missing"
    return 0
  fi
  dev=$(df -P "${path}" | awk 'NR==2 { print $1 }')
  df -hP "${path}" || true
  echo "${path} dev=${dev}"
  if [[ -z "${work_dev}" || "${dev}" != "${work_dev}" ]]; then
    bad "${path} is on ${dev:-missing}, not the work disk (${work_dev:-missing})"
  fi
}
check_on_work /var/lib/containerd
check_on_work /var/lib/ghrunner/docker
check_on_work /run/containerd
check_on_work /var/lib/sysbox
expect_bind() {
  local path="$1" expect="$2" src
  if ! mountpoint -q "${path}"; then
    bad "${path} is not a bind mount"
    return 0
  fi
  src=$(findmnt -n -o SOURCE "${path}")
  echo "${path} source=${src}"
  if [[ "${src}" != "${expect}" && "${src}" != *"[$expect]" ]]; then
    bad "${path} source is ${src}; expected ${expect}"
  fi
}
expect_bind /var/lib/containerd /var/lib/ghrunner/containerd
expect_bind /run/containerd /var/lib/ghrunner/containerd-state
expect_bind /var/lib/sysbox /var/lib/ghrunner/sysbox
rootdir=$(docker info -f '{{.DockerRootDir}}' 2>&1 || true)
echo "DockerRootDir=${rootdir}"
if [[ "${rootdir}" != "/var/lib/ghrunner/docker" ]]; then
  bad "DockerRootDir is ${rootdir}"
fi

section "docker runtimes"
runtimes=$(docker info --format '{{json .Runtimes}}' 2>&1 || true)
printf '%s\n' "${runtimes}"
if ! printf '%s\n' "${runtimes}" | grep -q 'sysbox-runc'; then
  bad "sysbox-runc is not in docker info runtimes"
fi

section "job container"
memory=12g
cpus=6
pids=4096
image=aap-crrr-runner:local
win_ip=""
if hex=$(default_route_hex); then
  win_ip=$(route_gateway "${hex}" || true)
fi
echo "AAP_WINDOWS_HOST_IP=${win_ip}"
if [[ -z "${win_ip}" ]]; then
  bad "could not read the Windows host IP from the default route"
fi
if [[ -f /etc/aap-runner/manager.conf ]]; then
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      '' | \#*) continue ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    case "${key}" in
      AAP_JOB_MEMORY) memory=${val} ;;
      AAP_JOB_CPUS) cpus=${val} ;;
      AAP_JOB_PIDS_LIMIT) pids=${val} ;;
      AAP_RUNNER_IMAGE) image=${val} ;;
    esac
  done < /etc/aap-runner/manager.conf
fi
echo "limits memory=${memory} cpus=${cpus} pids=${pids} image=${image}"
limits_ok=0
if expect_mem=$(memory_bytes "${memory}") && expect_cpu=$(cpu_nanos "${cpus}") && [[ "${pids}" =~ ^[1-9][0-9]*$ ]]; then
  limits_ok=1
else
  bad "job limits are not usable"
  expect_mem=""
  expect_cpu=""
fi

name="aap-crrr-evidence-$$"
net="${name}"
cleanup_evidence() {
  docker rm -f "${name}" >/dev/null 2>&1 || true
  docker network rm "${net}" >/dev/null 2>&1 || true
}
trap cleanup_evidence EXIT

if [[ "${limits_ok}" -ne 1 ]]; then
  bad "skipped the job container because the limits are not usable"
elif ! docker network create --label aap-crrr-evidence=1 "${net}"; then
  bad "could not create the evidence network"
else
  inner=$(
    declare -f route_gateway
    cat <<'EOF'
set -u
fail=0
hex=$(awk '$2 == "00000000" { print $3; exit }' /proc/net/route)
echo "GATEWAY_HEX=${hex}"
gw=""
if [[ -n "${hex}" ]]; then
  gw=$(route_gateway "${hex}" || true)
fi
echo "GATEWAY=${gw}"
echo "AAP_WINDOWS_HOST_IP=${AAP_WINDOWS_HOST_IP:-}"
probe_url() {
  local pname="$1" url="$2" expect="$3" max_time="$4" rc=0 err
  err=$(curl -g --silent --show-error --output /dev/null \
    --connect-timeout 3 --max-time "${max_time}" "${url}" 2>&1) || rc=$?
  err=${err//$'\n'/ }
  if [[ "${expect}" == "open" && "${rc}" -eq 0 ]]; then
    echo "PROBE ${pname} open rc=0"
    return 0
  fi
  if [[ "${expect}" == "blocked" && "${rc}" -ne 0 ]]; then
    echo "PROBE ${pname} blocked rc=${rc} ${err}"
    return 0
  fi
  echo "PROBE ${pname} unexpected expect=${expect} rc=${rc} ${err}"
  return 1
}
if [[ -z "${gw}" ]]; then
  echo "PROBE gateway unexpected empty gateway"
  fail=1
else
  probe_url gateway "http://${gw}/" blocked 5 || fail=1
fi
if [[ -z "${AAP_WINDOWS_HOST_IP:-}" ]]; then
  echo "PROBE windows_host unexpected empty host ip"
  fail=1
else
  probe_url windows_host "http://${AAP_WINDOWS_HOST_IP}/" blocked 5 || fail=1
fi
probe_url lan "http://192.168.1.1/" blocked 5 || fail=1
probe_url ula "http://[fd00:aaaa::1]/" blocked 5 || fail=1
probe_url public_https "https://github.com/" open 20 || fail=1
mnt_hit=$(find /mnt -mindepth 1 -print -quit 2>/dev/null || true)
if [[ -n "${mnt_hit}" ]]; then
  echo "PROBE mnt unexpected ${mnt_hit}"
  fail=1
else
  echo "PROBE mnt empty"
fi
exit "${fail}"
EOF
  )
  if ! docker create \
    --runtime=sysbox-runc \
    --interactive \
    --name "${name}" \
    --network "${net}" \
    --memory "${memory}" \
    --memory-swap "${memory}" \
    --cpus "${cpus}" \
    --cpu-shares "${CPU_SHARES}" \
    --pids-limit "${pids}" \
    --label aap-crrr-evidence=1 \
    --env "AAP_WINDOWS_HOST_IP=${win_ip}" \
    --entrypoint bash \
    "${image}" -s; then
    bad "docker create of the evidence container failed"
  else
    inspect=$(docker inspect --format 'memory={{.HostConfig.Memory}} memory_swap={{.HostConfig.MemorySwap}} cpu_shares={{.HostConfig.CpuShares}} nano_cpus={{.HostConfig.NanoCpus}} pids={{.HostConfig.PidsLimit}}' "${name}")
    mounts=$(docker inspect --format '{{json .Mounts}}' "${name}")
    binds=$(docker inspect --format '{{json .HostConfig.Binds}}' "${name}")
    echo "Mounts=${mounts}"
    echo "Binds=${binds}"
    if ! host_mounts_empty "${mounts}" "${binds}"; then
      bad "job container has a host mount"
    fi
    echo "${inspect}"
    got_mem=${inspect#memory=}
    got_mem=${got_mem%% *}
    got_swap=${inspect#*memory_swap=}
    got_swap=${got_swap%% *}
    got_shares=${inspect#*cpu_shares=}
    got_shares=${got_shares%% *}
    got_cpu=${inspect#*nano_cpus=}
    got_cpu=${got_cpu%% *}
    got_pids=${inspect#*pids=}
    if [[ "${got_mem}" != "${expect_mem}" || "${got_swap}" != "${expect_mem}" || "${got_shares}" != "${CPU_SHARES}" || "${got_cpu}" != "${expect_cpu}" || "${got_pids}" != "${pids}" ]]; then
      bad "container limits are ${inspect}; expected memory=${expect_mem} memory_swap=${expect_mem} cpu_shares=${CPU_SHARES} nano_cpus=${expect_cpu} pids=${pids}"
    fi
    probe_rc=0
    printf '%s\n' "${inner}" | docker start --attach --interactive "${name}" || probe_rc=$?
    echo "container exit ${probe_rc}"
    if [[ "${probe_rc}" -ne 0 ]]; then
      bad "job-container probes failed"
    fi
  fi
fi

echo
if [[ "${fail}" -ne 0 ]]; then
  echo "evidence FAILED"
  exit 1
fi
echo "evidence ok"
