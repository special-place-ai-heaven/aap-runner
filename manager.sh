#!/bin/bash
# Root systemd loop: one fresh Sysbox runner container per job.
# The GitHub App private key stays in this process. It is never passed into
# the container and never written to a second file.
set -euo pipefail

CONFIG_PATH=/etc/aap-runner/manager.conf
C_FREE_PATH=/run/aap-runner/c-free-gb
# The SYSTEM task rewrites the file every minute. Older than this, refuse.
C_FREE_MAX_AGE_S=180
AAP_GITHUB_ORG=""
AAP_GITHUB_APP_ID=""
AAP_GITHUB_APP_INSTALLATION_ID=""
AAP_GITHUB_APP_PRIVATE_KEY_PATH=""
AAP_RUNNER_IMAGE=""
AAP_RUNNER_LABELS=""
AAP_RUNNER_GROUP=""
AAP_DISK_FLOOR_GB=""

below_floor() {
  local avail="$1" floor="$2"
  [[ "${avail}" -lt "${floor}" ]]
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

# 0 = start, 3 = stale, 4 = under floor, 2 = malformed.
c_free_verdict() {
  local epoch="$1" gb="$2" now="$3" floor="$4" max_age="$5"
  if [[ ! "${epoch}" =~ ^[0-9]+$ || ! "${gb}" =~ ^[0-9]+$ ]]; then
    return 2
  fi
  if ((now + 30 < epoch || now - epoch > max_age)); then
    return 3
  fi
  if below_floor "${gb}" "${floor}"; then
    return 4
  fi
  return 0
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
  local perms owner line epoch gb now verdict
  if [[ ! -f "${C_FREE_PATH}" ]]; then
    echo "refusing to start a job: ${C_FREE_PATH} is missing (scheduled task has not reported C: free space)" >&2
    return 1
  fi
  perms=$(stat -c '%a' "${C_FREE_PATH}")
  owner=$(stat -c '%u' "${C_FREE_PATH}")
  if [[ "${owner}" != "0" || "${perms}" != "400" ]]; then
    echo "refusing to start a job: ${C_FREE_PATH} must be root mode 0400" >&2
    return 1
  fi
  line=""
  IFS= read -r line < "${C_FREE_PATH}" || true
  epoch=${line%% *}
  gb=${line#* }
  now=$(date +%s)
  verdict=0
  c_free_verdict "${epoch}" "${gb}" "${now}" "${AAP_DISK_FLOOR_GB}" "${C_FREE_MAX_AGE_S}" || verdict=$?
  case "${verdict}" in
    0) ;;
    3)
      echo "refusing to start a job: C: free-space reading is stale or in the future (epoch ${epoch}, now ${now})" >&2
      return 1
      ;;
    4)
      echo "refusing to start a job: ${gb}G free on C:; floor is ${AAP_DISK_FLOOR_GB}G" >&2
      return 1
      ;;
    *)
      echo "refusing to start a job: ${C_FREE_PATH} is not 'epoch gb'" >&2
      return 1
      ;;
  esac
  echo "disk floor ok: ${gb}G free on C: (reading age $((now - epoch))s)"
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
  local token="" name net rc=1
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
  set +e
  printf '%s\n' "${token}" | docker start --attach --interactive "${name}"
  rc=$?
  set -e
  token=""
  unset token
  cleanup_job "${name}" "${net}"
  return "${rc}"
}

self_check() {
  local now=100000 verdict
  if ! below_floor 39 40; then
    echo "39G should be under a 40G floor" >&2
    return 1
  fi
  if below_floor 40 40 || below_floor 41 40; then
    echo "floor comparison accepted a value that is not under the floor" >&2
    return 1
  fi
  verdict=0
  c_free_verdict 99900 65 "${now}" 40 180 || verdict=$?
  [[ "${verdict}" -eq 0 ]]
  verdict=0
  c_free_verdict 99900 39 "${now}" 40 180 || verdict=$?
  [[ "${verdict}" -eq 4 ]]
  verdict=0
  c_free_verdict 90000 65 "${now}" 40 180 || verdict=$?
  [[ "${verdict}" -eq 3 ]]
  verdict=0
  c_free_verdict $((now + 31)) 65 "${now}" 40 180 || verdict=$?
  [[ "${verdict}" -eq 3 ]]
  verdict=0
  c_free_verdict abc 65 "${now}" 40 180 || verdict=$?
  [[ "${verdict}" -eq 2 ]]
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
