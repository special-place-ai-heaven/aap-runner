#!/bin/bash
# Print the aap-runner lockdown evidence. Run as root inside the distro,
# after app.pem and manager.conf are in place:
#   wsl.exe -d aap-runner -u root -- bash /usr/local/sbin/aap-runner-evidence
# Exit status is non-zero when an observation is missing or wrong.
# --self-check only parses a route gateway and a memory limit. No Docker.
set -euo pipefail

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

self_check() {
  local got
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

section "/mnt"
mnt_entries=$(find /mnt -mindepth 1 -print 2>/dev/null || true)
if [[ -n "${mnt_entries}" ]]; then
  printf '%s\n' "${mnt_entries}"
  bad "/mnt is not empty"
else
  echo "/mnt empty"
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

section "job container"
memory=12g
cpus=6
pids=4096
image=aap-crrr-runner:local
win_ip=""
if hex=$(default_route_hex); then
  win_ip=$(route_gateway "${hex}" || true)
fi
echo "windows_host_ip=${win_ip:-unknown}"
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
echo "WINDOWS_HOST=${AAP_WINDOWS_HOST_IP:-}"
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
exit "${fail}"
EOF
  )
  if ! docker create \
    --runtime=sysbox-runc \
    --interactive \
    --name "${name}" \
    --network "${net}" \
    --memory "${memory}" \
    --cpus "${cpus}" \
    --pids-limit "${pids}" \
    --label aap-crrr-evidence=1 \
    --env "AAP_WINDOWS_HOST_IP=${win_ip}" \
    --entrypoint bash \
    "${image}" -s; then
    bad "docker create of the evidence container failed"
  else
    inspect=$(docker inspect --format 'memory={{.HostConfig.Memory}} nano_cpus={{.HostConfig.NanoCpus}} pids={{.HostConfig.PidsLimit}}' "${name}")
    echo "${inspect}"
    got_mem=${inspect#memory=}
    got_mem=${got_mem%% *}
    got_cpu=${inspect#*nano_cpus=}
    got_cpu=${got_cpu%% *}
    got_pids=${inspect#*pids=}
    if [[ "${got_mem}" != "${expect_mem}" || "${got_cpu}" != "${expect_cpu}" || "${got_pids}" != "${pids}" ]]; then
      bad "container limits are ${inspect}; expected memory=${expect_mem} nano_cpus=${expect_cpu} pids=${pids}"
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
