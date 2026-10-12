#!/bin/bash
# Root systemd loop: one fresh Sysbox runner container per job.
# The GitHub App private key stays in this process. It is never passed into
# the container and never written to a second file.
set -euo pipefail

CONFIG_PATH=/etc/aap-runner/manager.conf
WORK_MOUNT=/var/lib/ghrunner
# df -BG of the 60 GiB ext4. The distro VHD reports about 1000G.
WORK_DISK_MIN_GB=50
WORK_DISK_MAX_GB=64
AAP_GITHUB_ORG=""
AAP_GITHUB_APP_ID=""
AAP_GITHUB_APP_INSTALLATION_ID=""
AAP_GITHUB_APP_PRIVATE_KEY_PATH=""
AAP_RUNNER_IMAGE=""
AAP_RUNNER_LABELS=""
AAP_RUNNER_GROUP=""
AAP_DISK_FLOOR_GB=""
AAP_JOB_MEMORY=""
AAP_JOB_CPUS=""
AAP_JOB_PIDS_LIMIT=""
AAP_JOB_TIMEOUT_MINUTES=""

below_floor() {
  local avail="$1" floor="$2"
  [[ "${avail}" -lt "${floor}" ]]
}

parse_df_gb() {
  awk 'NR==2 { gsub(/G/, "", $1); print $1 }'
}

size_is_work_disk() {
  local size="$1"
  [[ "${size}" =~ ^[0-9]+$ ]] || return 1
  [[ "${size}" -ge "${WORK_DISK_MIN_GB}" && "${size}" -le "${WORK_DISK_MAX_GB}" ]]
}

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

apply_config_line() {
  local line="$1" key val
  case "${line}" in
    '' | \#*) return 0 ;;
  esac
  if [[ "${line}" == *$'\r'* ]]; then
    echo "config line contains CR" >&2
    return 1
  fi
  key=${line%%=*}
  val=${line#*=}
  case "${key}" in
    AAP_GITHUB_ORG) AAP_GITHUB_ORG=${val} ;;
    AAP_GITHUB_APP_ID) AAP_GITHUB_APP_ID=${val} ;;
    AAP_GITHUB_APP_INSTALLATION_ID) AAP_GITHUB_APP_INSTALLATION_ID=${val} ;;
    AAP_GITHUB_APP_PRIVATE_KEY_PATH) AAP_GITHUB_APP_PRIVATE_KEY_PATH=${val} ;;
    AAP_RUNNER_IMAGE) AAP_RUNNER_IMAGE=${val} ;;
    AAP_RUNNER_LABELS) AAP_RUNNER_LABELS=${val} ;;
    AAP_RUNNER_GROUP) AAP_RUNNER_GROUP=${val} ;;
    AAP_DISK_FLOOR_GB) AAP_DISK_FLOOR_GB=${val} ;;
    AAP_JOB_MEMORY) AAP_JOB_MEMORY=${val} ;;
    AAP_JOB_CPUS) AAP_JOB_CPUS=${val} ;;
    AAP_JOB_PIDS_LIMIT) AAP_JOB_PIDS_LIMIT=${val} ;;
    AAP_JOB_TIMEOUT_MINUTES) AAP_JOB_TIMEOUT_MINUTES=${val} ;;
    *)
      echo "unknown config key: ${key}" >&2
      return 1
      ;;
  esac
}

load_config() {
  local perms owner line
  perms=$(stat -c '%a' "${CONFIG_PATH}")
  owner=$(stat -c '%u' "${CONFIG_PATH}")
  if [[ "${owner}" != "0" || "${perms}" != "400" ]]; then
    echo "refusing: ${CONFIG_PATH} must be root mode 0400 (found mode ${perms} uid ${owner})" >&2
    exit 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    apply_config_line "${line}"
  done < "${CONFIG_PATH}"
  [[ "${AAP_GITHUB_ORG}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
  [[ "${AAP_GITHUB_APP_ID}" =~ ^[0-9]+$ ]]
  [[ "${AAP_GITHUB_APP_INSTALLATION_ID}" =~ ^[0-9]+$ ]]
  [[ "${AAP_GITHUB_APP_PRIVATE_KEY_PATH}" =~ ^/etc/aap-runner/[A-Za-z0-9._/-]+$ ]]
  if [[ "${AAP_GITHUB_APP_PRIVATE_KEY_PATH}" == *..* ]]; then
    echo "refusing key path that contains .." >&2
    exit 1
  fi
  [[ "${AAP_RUNNER_IMAGE}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:/@-]*$ ]]
  [[ "${AAP_RUNNER_LABELS}" == "self-hosted,linux,crrr" ]]
  [[ "${AAP_RUNNER_GROUP}" == "aap-crrr" ]]
  [[ "${AAP_DISK_FLOOR_GB}" =~ ^[0-9]+$ ]]
  finish_job_limits
}

# Absent keys use the defaults. A present value that is not this grammar is refused.
# Memory is an integer plus one docker suffix. Timeout is 1..1440 minutes.
valid_memory() {
  [[ "$1" =~ ^[1-9][0-9]*[bBkKmMgG]?$ ]]
}

valid_cpus() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  awk -v n="$1" 'BEGIN { exit (n > 0 ? 0 : 1) }'
}

valid_pids() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

valid_timeout_minutes() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$1" -le 1440 ]]
}

finish_job_limits() {
  [[ -z "${AAP_JOB_MEMORY}" ]] && AAP_JOB_MEMORY=12g
  [[ -z "${AAP_JOB_CPUS}" ]] && AAP_JOB_CPUS=6
  [[ -z "${AAP_JOB_PIDS_LIMIT}" ]] && AAP_JOB_PIDS_LIMIT=4096
  [[ -z "${AAP_JOB_TIMEOUT_MINUTES}" ]] && AAP_JOB_TIMEOUT_MINUTES=120
  if ! valid_memory "${AAP_JOB_MEMORY}"; then
    echo "refusing: AAP_JOB_MEMORY=${AAP_JOB_MEMORY}" >&2
    return 1
  fi
  if ! valid_cpus "${AAP_JOB_CPUS}"; then
    echo "refusing: AAP_JOB_CPUS=${AAP_JOB_CPUS}" >&2
    return 1
  fi
  if ! valid_pids "${AAP_JOB_PIDS_LIMIT}"; then
    echo "refusing: AAP_JOB_PIDS_LIMIT=${AAP_JOB_PIDS_LIMIT}" >&2
    return 1
  fi
  if ! valid_timeout_minutes "${AAP_JOB_TIMEOUT_MINUTES}"; then
    echo "refusing: AAP_JOB_TIMEOUT_MINUTES=${AAP_JOB_TIMEOUT_MINUTES}" >&2
    return 1
  fi
}

# Child is a new session with a clean command, so the registration token
# (an unexported local) is not in its environment. disarm kills the sleep
# before it can stop the container.
arm_wall_clock() {
  local seconds="$1" name="$2"
  if ! command -v setsid >/dev/null 2>&1; then
    echo "refusing: setsid is required for the job wall clock" >&2
    return 1
  fi
  # Single quotes on purpose: this shell must not expand the clock's $1/$2.
  # shellcheck disable=SC2016
  setsid bash -c '
    sleep "$1"
    echo "wall clock ${1}s elapsed; stopping $2" >&2
    docker stop -t 20 "$2" || true
    docker rm -f "$2" || true
  ' _ "${seconds}" "${name}" >/dev/null &
  echo $!
}

disarm_wall_clock() {
  local pid="$1"
  if [[ -z "${pid}" ]]; then
    return 0
  fi
  kill -- "-${pid}" 2>/dev/null || kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
}

check_key() {
  local perms owner
  perms=$(stat -c '%a' "${AAP_GITHUB_APP_PRIVATE_KEY_PATH}")
  owner=$(stat -c '%u' "${AAP_GITHUB_APP_PRIVATE_KEY_PATH}")
  if [[ "${owner}" != "0" || "${perms}" != "400" ]]; then
    echo "refusing: app private key must be root mode 0400" >&2
    exit 1
  fi
}

mount_source_forbidden() {
  case "$1" in
    /mnt | /mnt/ | /mnt/*) return 0 ;;
    *) return 1 ;;
  esac
}

assert_no_mnt_mounts() {
  local name="$1" source bind
  while IFS= read -r source; do
    if [[ -n "${source}" ]] && mount_source_forbidden "${source}"; then
      echo "refusing: mount source ${source} is /mnt or under /mnt" >&2
      return 1
    fi
  done < <(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}{{range .HostConfig.Mounts}}{{println .Source}}{{end}}' "${name}")
  while IFS= read -r bind; do
    [[ -z "${bind}" ]] && continue
    source=${bind%%:*}
    if mount_source_forbidden "${source}"; then
      echo "refusing: bind ${bind} is /mnt or under /mnt" >&2
      return 1
    fi
  done < <(docker inspect --format '{{range .HostConfig.Binds}}{{println .}}{{end}}' "${name}")
}

disk_ok() {
  local avail size
  if ! mountpoint -q "${WORK_MOUNT}"; then
    echo "refusing to start a job: ${WORK_MOUNT} is not a mountpoint" >&2
    return 1
  fi
  avail=$(df -BG --output=avail "${WORK_MOUNT}" | parse_df_gb)
  size=$(df -BG --output=size "${WORK_MOUNT}" | parse_df_gb)
  if [[ ! "${avail}" =~ ^[0-9]+$ ]]; then
    echo "refusing to start a job: df avail of ${WORK_MOUNT} was not numeric" >&2
    return 1
  fi
  if ! size_is_work_disk "${size}"; then
    echo "refusing to start a job: ${WORK_MOUNT} is ${size:-unknown}G; the work disk is 60G" >&2
    return 1
  fi
  if below_floor "${avail}" "${AAP_DISK_FLOOR_GB}"; then
    echo "refusing to start a job: ${avail}G free on ${WORK_MOUNT}; floor is ${AAP_DISK_FLOOR_GB}G" >&2
    return 1
  fi
  echo "disk floor ok: ${avail}G free on ${WORK_MOUNT} (${size}G filesystem)"
}

mint_registration_token() {
  local now iat exp header payload sig jwt installation_token
  now=$(date +%s)
  iat=$((now - 30))
  exp=$((now + 480))
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "${iat}" "${exp}" "${AAP_GITHUB_APP_ID}" | b64url)
  sig=$(printf '%s' "${header}.${payload}" | openssl dgst -binary -sha256 -sign "${AAP_GITHUB_APP_PRIVATE_KEY_PATH}" | b64url)
  jwt="${header}.${payload}.${sig}"
  installation_token=$(
    curl --silent --show-error --fail \
      -X POST \
      -H "Authorization: Bearer ${jwt}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/app/installations/${AAP_GITHUB_APP_INSTALLATION_ID}/access_tokens" \
      | jq -er '.token'
  )
  curl --silent --show-error --fail \
    -X POST \
    -H "Authorization: Bearer ${installation_token}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${AAP_GITHUB_ORG}/actions/runners/registration-token" \
    | jq -er '.token'
}

cleanup_job() {
  local name="$1" net="$2"
  docker rm -f "${name}" || true
  docker network rm "${net}" || true
  docker volume prune -f --filter label=aap-crrr-job=1 >/dev/null || true
  docker network prune -f --filter label=aap-crrr-job=1 >/dev/null || true
}

run_one() {
  local token="" name net rc=1 killer="" seconds=0
  name="aap-crrr-$(date +%s)-$$"
  net="${name}"
  # set -e does not apply inside this function: the loop calls it from `if`.
  if ! docker network create --label aap-crrr-job=1 "${net}"; then
    return 1
  fi
  # No -v, no --mount, no /mnt. assert_no_mnt_mounts rejects a source under /mnt
  # even if the daemon adds one. /mnt/wsl is the shared docker-desktop tmpfs.
  if ! docker create \
    --runtime=sysbox-runc \
    --interactive \
    --name "${name}" \
    --network "${net}" \
    --memory "${AAP_JOB_MEMORY}" \
    --cpus "${AAP_JOB_CPUS}" \
    --pids-limit "${AAP_JOB_PIDS_LIMIT}" \
    --label aap-crrr-job=1 \
    --env "AAP_GITHUB_ORG=${AAP_GITHUB_ORG}" \
    --env "AAP_RUNNER_LABELS=${AAP_RUNNER_LABELS}" \
    --env "AAP_RUNNER_GROUP=${AAP_RUNNER_GROUP}" \
    "${AAP_RUNNER_IMAGE}"; then
    docker network rm "${net}" || true
    return 1
  fi
  if ! assert_no_mnt_mounts "${name}"; then
    cleanup_job "${name}" "${net}"
    return 1
  fi
  if ! token="$(mint_registration_token)"; then
    cleanup_job "${name}" "${net}"
    return 1
  fi
  seconds=$((AAP_JOB_TIMEOUT_MINUTES * 60))
  if ! killer=$(arm_wall_clock "${seconds}" "${name}") || ! kill -0 "${killer}" 2>/dev/null; then
    token=""
    unset token
    cleanup_job "${name}" "${net}"
    return 1
  fi
  set +e
  printf '%s\n' "${token}" | docker start --attach --interactive "${name}"
  rc=$?
  set -e
  token=""
  unset token
  disarm_wall_clock "${killer}"
  cleanup_job "${name}" "${net}"
  return "${rc}"
}

self_check() {
  local got killer=""
  if ! below_floor 34 35; then
    echo "34G should be under a 35G floor" >&2
    return 1
  fi
  if below_floor 35 35 || below_floor 36 35; then
    echo "floor comparison accepted a value that is not under the floor" >&2
    return 1
  fi
  got=$(printf 'Avail\n  35G\n' | parse_df_gb)
  [[ "${got}" == "35" ]]
  got=$(printf '1G-blocks\n     60G\n' | parse_df_gb)
  [[ "${got}" == "60" ]]
  if ! size_is_work_disk 60 || ! size_is_work_disk 59; then
    echo "60G work disk was rejected" >&2
    return 1
  fi
  if size_is_work_disk 49 || size_is_work_disk 65 || size_is_work_disk 1000; then
    echo "a filesystem that is not the 60G work disk was accepted" >&2
    return 1
  fi
  if ! mount_source_forbidden /mnt || ! mount_source_forbidden /mnt/ || ! mount_source_forbidden /mnt/wsl; then
    echo "mounts under /mnt were allowed" >&2
    return 1
  fi
  if mount_source_forbidden /var/lib/docker || mount_source_forbidden /mntfoo; then
    echo "a non-/mnt source was forbidden" >&2
    return 1
  fi
  AAP_GITHUB_ORG=""
  apply_config_line "AAP_GITHUB_ORG=special-place-ai-heaven"
  [[ "${AAP_GITHUB_ORG}" == "special-place-ai-heaven" ]]
  if apply_config_line "NOT_A_KEY=1"; then
    echo "unknown config key was accepted" >&2
    return 1
  fi
  AAP_JOB_MEMORY=""
  AAP_JOB_CPUS=""
  AAP_JOB_PIDS_LIMIT=""
  AAP_JOB_TIMEOUT_MINUTES=""
  finish_job_limits
  [[ "${AAP_JOB_MEMORY}" == "12g" ]]
  [[ "${AAP_JOB_CPUS}" == "6" ]]
  [[ "${AAP_JOB_PIDS_LIMIT}" == "4096" ]]
  [[ "${AAP_JOB_TIMEOUT_MINUTES}" == "120" ]]
  [[ $((AAP_JOB_TIMEOUT_MINUTES * 60)) -eq 7200 ]]
  AAP_JOB_MEMORY="12gb"
  if finish_job_limits; then
    echo "bad memory limit was accepted" >&2
    return 1
  fi
  AAP_JOB_MEMORY="12g"
  AAP_JOB_CPUS="0"
  if finish_job_limits; then
    echo "zero cpus was accepted" >&2
    return 1
  fi
  AAP_JOB_CPUS="6"
  AAP_JOB_PIDS_LIMIT="4096"
  AAP_JOB_TIMEOUT_MINUTES="1441"
  if finish_job_limits; then
    echo "timeout above 1440 minutes was accepted" >&2
    return 1
  fi
  killer=$(arm_wall_clock 30 "aap-self-check-no-such-container")
  if ! kill -0 "${killer}" 2>/dev/null; then
    disarm_wall_clock "${killer}"
    echo "wall clock did not stay up" >&2
    return 1
  fi
  disarm_wall_clock "${killer}"
  # The signal is asynchronous, and the sleeper is not this shell's child
  # (arm runs inside a command substitution), so wait cannot reap it.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "${killer}" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "${killer}" 2>/dev/null; then
    echo "wall clock was still running after disarm" >&2
    return 1
  fi
  echo "disk floor self-check ok"
}

if [[ "${1:-}" == "--self-check" ]]; then
  self_check
  exit 0
fi

if [[ "${1:-}" == "--assert-mounts" ]]; then
  assert_no_mnt_mounts "${2:?container name}"
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "aap-runner-manager must run as root" >&2
  exit 1
fi

load_config
check_key

while IFS= read -r stale; do
  if [[ -n "${stale}" ]]; then
    docker rm -f "${stale}" || true
  fi
done < <(docker ps -aq --filter label=aap-crrr-job=1)

while true; do
  if ! disk_ok; then
    sleep 60
    continue
  fi
  if ! run_one; then
    echo "runner container exited non-zero; workspace was removed with the container" >&2
    sleep 5
  fi
done
