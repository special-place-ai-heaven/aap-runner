#!/bin/bash
# Root systemd loop: one fresh Sysbox runner container per job, in
# AAP_RUNNER_COUNT parallel slots.
# The GitHub App private key stays in this process. It is never passed into
# the container and never written to a second file.
set -euo pipefail

# shellcheck source=labels.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/labels.sh"
# Exact match for AAP_RUNNER_LABELS_VERSION in labels.sh.
require_labels_version 1 || exit 1

CONFIG_PATH=/etc/aap-runner/manager.conf
WORK_MOUNT=/var/lib/ghrunner
# df -BG of an ext4 is a few GiB under the VHDX. Accept configured size -10..+4.
# AAP_WORK_DISK_GIB is 20..512, so a ~1000G distro VHD is outside the window.
# The mount must also be work-disk.uuid and not the device behind /.
WORK_DISK_MIN_GB=""
WORK_DISK_MAX_GB=""
WORK_DISK_UUID_FILE=/etc/aap-runner/work-disk.uuid
# Default shares are 1024. This only weights containers inside the WSL VM.
CPU_SHARES=512
AAP_GITHUB_ORG=""
AAP_GITHUB_APP_ID=""
AAP_GITHUB_APP_INSTALLATION_ID=""
AAP_GITHUB_APP_PRIVATE_KEY_PATH=""
AAP_RUNNER_IMAGE=""
AAP_RUNNER_LABELS=""
AAP_RUNNER_BASE_LABEL=""
AAP_RUNNER_EXTRA_LABELS=""
AAP_RUNNER_GROUP=""
AAP_WORK_DISK_GIB=""
AAP_DISK_FLOOR_GB=""
AAP_JOB_MEMORY=""
AAP_JOB_CPUS=""
AAP_JOB_PIDS_LIMIT=""
AAP_JOB_TIMEOUT_MINUTES=""
# Unset means absent (one slot). A present but empty value is refused.
unset AAP_RUNNER_COUNT
# Per-slot docker create limits, set by finish_runner_count.
SLOT_CPUS=""
SLOT_MEMORY=""
SLOT_PIDS=()
SLOT_STARTED=()
SLOT_FAILS=()
# A slot that dies this many times in a row, each within SLOT_FAST_SECONDS of
# starting, is retired. When every slot is retired the manager exits 1 and
# systemd restarts the whole pool.
SLOT_MAX_FAILS=5
SLOT_FAST_SECONDS=120
# Shared rustc cache on the work disk, bind-mounted into every job. sccache's
# local disk cache is built for concurrent readers and writers (separate
# sccache servers, one per job), so parallel slots can share it. ci.yml sets
# SCCACHE_DIR to a per-repository subdirectory; "default" is for jobs that do not.
SCCACHE_HOST_DIR=${WORK_MOUNT}/sccache
SCCACHE_CONTAINER_DIR=/var/cache/aap-sccache
SCCACHE_CACHE_SIZE=10G
# SCCACHE_CACHE_SIZE bounds one directory, and any job can create another.
# Before each job the whole tree is measured; over this cap it is wiped.
SCCACHE_TREE_MAX_MB=20480
RUNNER_UID=""

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
  [[ "${WORK_DISK_MIN_GB}" =~ ^[0-9]+$ && "${WORK_DISK_MAX_GB}" =~ ^[0-9]+$ ]] || return 1
  [[ "${size}" -ge "${WORK_DISK_MIN_GB}" && "${size}" -le "${WORK_DISK_MAX_GB}" ]]
}

# Size is not enough. The mount's device must differ from / and its UUID
# must be the one written at install. A ~1000G system disk fails this.
work_mount_matches() {
  local dev="$1" root_dev="$2" mount_uuid="$3" expect_uuid="$4"
  [[ -n "${dev}" && -n "${root_dev}" && "${dev}" != "${root_dev}" ]] || return 1
  [[ "${expect_uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
  [[ "${mount_uuid}" == "${expect_uuid}" ]]
}

assert_work_mount_device() {
  local mount="$1" uuid dev root_dev mount_uuid
  if [[ ! -r "${WORK_DISK_UUID_FILE}" ]]; then
    echo "refusing: ${WORK_DISK_UUID_FILE} is unreadable" >&2
    return 1
  fi
  uuid=$(tr -d '[:space:]' < "${WORK_DISK_UUID_FILE}")
  dev=$(df -P "${mount}" | awk 'NR==2 { print $1 }')
  root_dev=$(df -P / | awk 'NR==2 { print $1 }')
  mount_uuid=$(findmnt -n -o UUID --target "${mount}" 2>/dev/null | tr -d '[:space:]' || true)
  if ! work_mount_matches "${dev}" "${root_dev}" "${mount_uuid}" "${uuid}"; then
    echo "refusing: ${mount} dev=${dev:-missing} uuid=${mount_uuid:-missing}; / is ${root_dev:-missing}; work-disk.uuid=${uuid:-missing}" >&2
    return 1
  fi
}

# At least 55% of the disk. ceil(60 * 55%) is 33, and the 60 GiB disk stays at 35.
disk_floor_gb() {
  local gib="$1" floor
  floor=$(( (gib * 55 + 99) / 100 ))
  if [[ "${gib}" -eq 60 && "${floor}" -lt 35 ]]; then
    floor=35
  fi
  printf '%s\n' "${floor}"
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
    AAP_RUNNER_BASE_LABEL) AAP_RUNNER_BASE_LABEL=${val} ;;
    AAP_RUNNER_EXTRA_LABELS) AAP_RUNNER_EXTRA_LABELS=${val} ;;
    AAP_RUNNER_GROUP) AAP_RUNNER_GROUP=${val} ;;
    AAP_WORK_DISK_GIB) AAP_WORK_DISK_GIB=${val} ;;
    AAP_DISK_FLOOR_GB) AAP_DISK_FLOOR_GB=${val} ;;
    AAP_JOB_MEMORY) AAP_JOB_MEMORY=${val} ;;
    AAP_JOB_CPUS) AAP_JOB_CPUS=${val} ;;
    AAP_JOB_PIDS_LIMIT) AAP_JOB_PIDS_LIMIT=${val} ;;
    AAP_JOB_TIMEOUT_MINUTES) AAP_JOB_TIMEOUT_MINUTES=${val} ;;
    AAP_RUNNER_COUNT) AAP_RUNNER_COUNT=${val} ;;
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
  [[ "${AAP_RUNNER_GROUP}" == "aap-crrr" ]]
  finish_disk_bounds
  finish_job_limits
  finish_runner_count
  finish_runner_labels
}

# AAP_WORK_DISK_GIB is this host's VHDX size. Absent means 60, which is CRRR.
# A floor below 55% of that size is raised. 60 GiB stays at 35 GB free.
finish_disk_bounds() {
  local min_floor
  [[ -z "${AAP_WORK_DISK_GIB}" ]] && AAP_WORK_DISK_GIB=60
  if [[ ! "${AAP_WORK_DISK_GIB}" =~ ^[1-9][0-9]*$ ]] || [[ "${AAP_WORK_DISK_GIB}" -lt 20 || "${AAP_WORK_DISK_GIB}" -gt 512 ]]; then
    echo "refusing: AAP_WORK_DISK_GIB=${AAP_WORK_DISK_GIB} is not 20..512" >&2
    return 1
  fi
  min_floor=$(disk_floor_gb "${AAP_WORK_DISK_GIB}")
  if [[ -z "${AAP_DISK_FLOOR_GB}" ]]; then
    AAP_DISK_FLOOR_GB=${min_floor}
  fi
  if [[ ! "${AAP_DISK_FLOOR_GB}" =~ ^[0-9]+$ ]]; then
    echo "refusing: AAP_DISK_FLOOR_GB=${AAP_DISK_FLOOR_GB}" >&2
    return 1
  fi
  if [[ "${AAP_DISK_FLOOR_GB}" -lt "${min_floor}" ]]; then
    echo "raising AAP_DISK_FLOOR_GB from ${AAP_DISK_FLOOR_GB} to ${min_floor} (55% of ${AAP_WORK_DISK_GIB} GiB; 60 GiB stays 35)" >&2
    AAP_DISK_FLOOR_GB=${min_floor}
  fi
  WORK_DISK_MIN_GB=$((AAP_WORK_DISK_GIB - 10))
  if [[ "${WORK_DISK_MIN_GB}" -lt 1 ]]; then
    WORK_DISK_MIN_GB=1
  fi
  WORK_DISK_MAX_GB=$((AAP_WORK_DISK_GIB + 4))
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

# AAP_RUNNER_BASE_LABEL is required. crrr or fresh only. There is no default.
# labels.sh checks the lowercase charset before reserved labels and duplicates.
finish_runner_labels() {
  local extra="${AAP_RUNNER_EXTRA_LABELS}" part seen="" expect
  local -a parts=()
  validate_base_label "${AAP_RUNNER_BASE_LABEL}" || return 1
  expect="self-hosted,linux,${AAP_RUNNER_BASE_LABEL}"
  if [[ -z "${AAP_RUNNER_LABELS}" ]]; then
    AAP_RUNNER_LABELS="${expect}"
  elif [[ "${AAP_RUNNER_LABELS}" != "${expect}" ]]; then
    echo "refusing: AAP_RUNNER_LABELS must be ${expect}" >&2
    return 1
  fi
  if [[ -z "${extra}" ]]; then
    return 0
  fi
  IFS=',' read -ra parts <<< "${extra}"
  if [[ "${#parts[@]}" -eq 0 ]]; then
    echo "refusing: AAP_RUNNER_EXTRA_LABELS has no label" >&2
    return 1
  fi
  for part in "${parts[@]}"; do
    extra_label_ok "${part}" "${seen}" || return 1
    seen="${seen:+${seen},}${part}"
  done
  AAP_RUNNER_LABELS="${expect},${seen}"
}

log_runner_labels() {
  echo "runner labels: ${AAP_RUNNER_LABELS}"
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

# AAP_RUNNER_COUNT is 1..4 parallel job containers. AAP_JOB_CPUS and
# AAP_JOB_MEMORY are the pool total, split evenly and rounded down to whole
# cpus and whole MiB. A slot under 1 cpu or 1g is refused. One slot keeps the
# configured values verbatim. Runs after finish_job_limits validated them.
finish_runner_count() {
  local num unit mult mib cpus
  [[ -z "${AAP_RUNNER_COUNT+x}" ]] && AAP_RUNNER_COUNT=1
  if [[ ! "${AAP_RUNNER_COUNT}" =~ ^[1-4]$ ]]; then
    echo "refusing: AAP_RUNNER_COUNT=${AAP_RUNNER_COUNT} is not 1..4" >&2
    return 1
  fi
  if [[ "${AAP_RUNNER_COUNT}" -eq 1 ]]; then
    SLOT_CPUS=${AAP_JOB_CPUS}
    SLOT_MEMORY=${AAP_JOB_MEMORY}
    return 0
  fi
  cpus=$(awk -v n="${AAP_JOB_CPUS}" -v c="${AAP_RUNNER_COUNT}" 'BEGIN { print int(n / c) }')
  num=${AAP_JOB_MEMORY%[bBkKmMgG]}
  unit=${AAP_JOB_MEMORY#"${num}"}
  case "${unit}" in
    k | K) mult=1024 ;;
    m | M) mult=$((1024 * 1024)) ;;
    g | G) mult=$((1024 * 1024 * 1024)) ;;
    *) mult=1 ;;
  esac
  # Bash integers are 64-bit. Refuse before num * mult can wrap.
  if [[ "${#num}" -gt 18 ]] || ((num > (1 << 62) / mult)); then
    echo "refusing: AAP_JOB_MEMORY=${AAP_JOB_MEMORY} is too large to split" >&2
    return 1
  fi
  mib=$((num * mult / AAP_RUNNER_COUNT / (1024 * 1024)))
  if [[ "${cpus}" -lt 1 || "${mib}" -lt 1024 ]]; then
    echo "refusing: AAP_RUNNER_COUNT=${AAP_RUNNER_COUNT} splits ${AAP_JOB_CPUS} cpus and ${AAP_JOB_MEMORY} into ${cpus} cpus and ${mib}m per slot; each slot needs 1 cpu and 1g" >&2
    return 1
  fi
  SLOT_CPUS=${cpus}
  if ((mib % 1024 == 0)); then
    SLOT_MEMORY="$((mib / 1024))g"
  else
    SLOT_MEMORY="${mib}m"
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
  if ! assert_work_mount_device "${WORK_MOUNT}"; then
    return 1
  fi
  avail=$(df -BG --output=avail "${WORK_MOUNT}" | parse_df_gb)
  size=$(df -BG --output=size "${WORK_MOUNT}" | parse_df_gb)
  if [[ ! "${avail}" =~ ^[0-9]+$ ]]; then
    echo "refusing to start a job: df avail of ${WORK_MOUNT} was not numeric" >&2
    return 1
  fi
  if ! size_is_work_disk "${size}"; then
    echo "refusing to start a job: ${WORK_MOUNT} is ${size:-unknown}G; the work disk is ${AAP_WORK_DISK_GIB}G (${WORK_DISK_MIN_GB}-${WORK_DISK_MAX_GB})" >&2
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

# Removes only this job's container, its anonymous volumes, and its network.
# No label-wide prune here: another slot's network has no endpoints between
# docker create and docker start, and a prune would delete it.
# remove_job_containers prunes at startup and stop, when no slot is running.
cleanup_job() {
  local name="$1" net="$2"
  docker rm -f -v "${name}" || true
  docker network rm "${net}" || true
}

# du rounds up to whole MiB. rm keeps the top directory and its owner.
bound_sccache_tree() {
  local used
  [[ -d "${SCCACHE_HOST_DIR}" ]] || return 0
  used=$(du -sm "${SCCACHE_HOST_DIR}" 2>/dev/null | awk '{ print $1 }')
  if [[ "${used}" =~ ^[0-9]+$ && "${used}" -gt "${SCCACHE_TREE_MAX_MB}" ]]; then
    echo "sccache tree ${SCCACHE_HOST_DIR} is ${used} MiB, over ${SCCACHE_TREE_MAX_MB}; wiping it" >&2
    rm -rf "${SCCACHE_HOST_DIR:?}"/*
  fi
}

# Slots start in the same second under one manager PID, so the slot index
# keeps container and network names unique.
job_name() {
  printf 'aap-crrr-%s-%s-%s\n' "$1" "$(date +%s)" "$$"
}

run_one() {
  local slot="$1" token="" name net rc=1 killer="" seconds=0
  name=$(job_name "${slot}")
  net="${name}"
  # set -e does not apply inside this function: the loop calls it from `if`.
  # disk_ok passed just before this, so the cache dir is on the work disk.
  bound_sccache_tree
  if ! install -d -o "${RUNNER_UID}" -m 0700 "${SCCACHE_HOST_DIR}"; then
    echo "refusing to start a job: could not create ${SCCACHE_HOST_DIR}" >&2
    return 1
  fi
  if ! docker network create --label aap-crrr-job=1 "${net}"; then
    return 1
  fi
  # One bind mount, the sccache dir on the work disk. No -v, no /mnt.
  # assert_no_mnt_mounts rejects a source under /mnt even if the daemon adds
  # one. /mnt/wsl is the shared docker-desktop tmpfs.
  if ! docker create \
    --runtime=sysbox-runc \
    --interactive \
    --name "${name}" \
    --network "${net}" \
    --memory "${SLOT_MEMORY}" \
    --memory-swap "${SLOT_MEMORY}" \
    --cpus "${SLOT_CPUS}" \
    --cpu-shares "${CPU_SHARES}" \
    --pids-limit "${AAP_JOB_PIDS_LIMIT}" \
    --label aap-crrr-job=1 \
    --label "aap-crrr-slot=${slot}" \
    --env "AAP_GITHUB_ORG=${AAP_GITHUB_ORG}" \
    --env "AAP_RUNNER_LABELS=${AAP_RUNNER_LABELS}" \
    --env "AAP_RUNNER_GROUP=${AAP_RUNNER_GROUP}" \
    --env "AAP_WORK_DISK_GIB=${AAP_WORK_DISK_GIB}" \
    --env "AAP_DISK_FLOOR_GB=${AAP_DISK_FLOOR_GB}" \
    --mount "type=bind,source=${SCCACHE_HOST_DIR},target=${SCCACHE_CONTAINER_DIR}" \
    --env "RUSTC_WRAPPER=sccache" \
    --env "SCCACHE_DIR=${SCCACHE_CONTAINER_DIR}/default" \
    --env "SCCACHE_CACHE_SIZE=${SCCACHE_CACHE_SIZE}" \
    "${AAP_RUNNER_IMAGE}"; then
    docker network rm "${net}" || true
    return 1
  fi
  if ! assert_no_mnt_mounts "${name}"; then
    cleanup_job "${name}" "${net}"
    return 1
  fi
  log_runner_labels
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
  local got killer="" sample
  labels_self_check
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
  [[ "$(disk_floor_gb 60)" == "35" ]]
  [[ "$(disk_floor_gb 100)" == "55" ]]
  AAP_WORK_DISK_GIB=""
  AAP_DISK_FLOOR_GB=""
  finish_disk_bounds
  [[ "${AAP_WORK_DISK_GIB}" == "60" && "${AAP_DISK_FLOOR_GB}" == "35" ]]
  [[ "${WORK_DISK_MIN_GB}" == "50" && "${WORK_DISK_MAX_GB}" == "64" ]]
  if ! size_is_work_disk 60 || ! size_is_work_disk 50 || ! size_is_work_disk 64; then
    echo "60G work disk was rejected" >&2
    return 1
  fi
  if size_is_work_disk 49 || size_is_work_disk 65 || size_is_work_disk 1000; then
    echo "a filesystem that is not the 60G work disk was accepted" >&2
    return 1
  fi
  AAP_WORK_DISK_GIB=100
  AAP_DISK_FLOOR_GB=""
  finish_disk_bounds
  [[ "${AAP_DISK_FLOOR_GB}" == "55" ]]
  [[ "${WORK_DISK_MIN_GB}" == "90" && "${WORK_DISK_MAX_GB}" == "104" ]]
  if ! size_is_work_disk 100 || ! size_is_work_disk 90 || ! size_is_work_disk 104; then
    echo "100G work disk was rejected" >&2
    return 1
  fi
  if size_is_work_disk 89 || size_is_work_disk 105 || size_is_work_disk 1000; then
    echo "a filesystem that is not the 100G work disk was accepted" >&2
    return 1
  fi
  AAP_WORK_DISK_GIB=100
  AAP_DISK_FLOOR_GB=35
  finish_disk_bounds
  [[ "${AAP_DISK_FLOOR_GB}" == "55" ]]
  AAP_WORK_DISK_GIB=100
  AAP_DISK_FLOOR_GB=60
  finish_disk_bounds
  [[ "${AAP_DISK_FLOOR_GB}" == "60" ]]
  AAP_WORK_DISK_GIB=9
  if finish_disk_bounds; then
    echo "a 9 GiB work disk was accepted" >&2
    return 1
  fi
  AAP_WORK_DISK_GIB=513
  if finish_disk_bounds; then
    echo "a 513 GiB work disk was accepted" >&2
    return 1
  fi
  AAP_WORK_DISK_GIB=512
  AAP_DISK_FLOOR_GB=""
  finish_disk_bounds
  [[ "${WORK_DISK_MIN_GB}" == "502" && "${WORK_DISK_MAX_GB}" == "516" ]]
  [[ "${AAP_DISK_FLOOR_GB}" == "282" ]]
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
  AAP_WORK_DISK_GIB=60
  AAP_DISK_FLOOR_GB=35
  finish_disk_bounds
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
  AAP_RUNNER_BASE_LABEL=""
  AAP_RUNNER_LABELS="self-hosted,linux,crrr"
  AAP_RUNNER_EXTRA_LABELS=""
  if finish_runner_labels; then
    echo "an empty base label was accepted" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="crrr"
  AAP_RUNNER_LABELS="self-hosted,linux,crrr"
  AAP_RUNNER_EXTRA_LABELS=""
  finish_runner_labels
  [[ "${AAP_RUNNER_LABELS}" == "self-hosted,linux,crrr" ]]
  got=$(log_runner_labels)
  [[ "${got}" == "runner labels: self-hosted,linux,crrr" ]]
  AAP_RUNNER_BASE_LABEL="fresh"
  AAP_RUNNER_LABELS="self-hosted,linux,fresh"
  AAP_RUNNER_EXTRA_LABELS="heavy"
  finish_runner_labels
  [[ "${AAP_RUNNER_LABELS}" == "self-hosted,linux,fresh,heavy" ]]
  got=$(log_runner_labels)
  [[ "${got}" == "runner labels: self-hosted,linux,fresh,heavy" ]]
  AAP_RUNNER_BASE_LABEL="fresh"
  AAP_RUNNER_LABELS="self-hosted,linux,fresh"
  AAP_RUNNER_EXTRA_LABELS="heavy,crrr"
  if finish_runner_labels; then
    echo "extra label crrr was accepted on base fresh" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="fresh"
  AAP_RUNNER_LABELS=""
  AAP_RUNNER_EXTRA_LABELS="heavy"
  finish_runner_labels
  [[ "${AAP_RUNNER_LABELS}" == "self-hosted,linux,fresh,heavy" ]]
  AAP_RUNNER_BASE_LABEL="fresh"
  AAP_RUNNER_LABELS="self-hosted,linux,crrr"
  AAP_RUNNER_EXTRA_LABELS="heavy"
  if finish_runner_labels; then
    echo "crrr labels were accepted for base fresh" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="fresh"
  AAP_RUNNER_LABELS="self-hosted,linux,fresh"
  AAP_RUNNER_EXTRA_LABELS="fresh"
  if finish_runner_labels; then
    echo "the base label was accepted again as an extra" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="self-hosted"
  AAP_RUNNER_LABELS=""
  AAP_RUNNER_EXTRA_LABELS=""
  if finish_runner_labels; then
    echo "base label self-hosted was accepted" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="crrr"
  AAP_RUNNER_LABELS="self-hosted,linux,crrr"
  AAP_RUNNER_EXTRA_LABELS="self-hosted"
  if finish_runner_labels; then
    echo "baseline label was accepted as an extra label" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="crrr"
  AAP_RUNNER_LABELS="self-hosted,linux,crrr"
  AAP_RUNNER_EXTRA_LABELS="fresh fresh"
  if finish_runner_labels; then
    echo "a label with a space was accepted" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="not a label"
  AAP_RUNNER_LABELS=""
  AAP_RUNNER_EXTRA_LABELS=""
  if finish_runner_labels; then
    echo "a base label with a space was accepted" >&2
    return 1
  fi
  AAP_RUNNER_BASE_LABEL="crrr"
  AAP_RUNNER_LABELS="linux,crrr"
  AAP_RUNNER_EXTRA_LABELS=""
  if finish_runner_labels; then
    echo "a label line other than self-hosted,linux,crrr was accepted" >&2
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

runner_uid_ok() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# The cache dir is owned by the image's runner uid, mode 0700. Sysbox mounts
# host binds ID-mapped, so that host uid is the same uid inside the job.
# Mode 1777 would let any distro account, ghrunner included, plant cache
# objects, and so would a runner uid that a distro account also has.
# Read once at startup with the default runtime and no network.
resolve_runner_uid() {
  local out="" account
  out=$(docker run --rm --pull never --network none --entrypoint id "${AAP_RUNNER_IMAGE}" -u runner 2>/dev/null) || out=""
  if ! runner_uid_ok "${out}"; then
    echo "refusing: runner uid in ${AAP_RUNNER_IMAGE} is '${out}', not a plain non-zero integer" >&2
    return 1
  fi
  account=$(getent passwd "${out}" | cut -d: -f1 || true)
  if [[ -n "${account}" ]]; then
    echo "refusing: runner uid ${out} is distro account ${account}; the cache would be writable from the distro" >&2
    return 1
  fi
  RUNNER_UID=${out}
}

# A dead slot's job container keeps running and holds its cpus and memory.
# Remove it, and its network (named after the container), before the slot
# restarts or retires.
remove_slot_containers() {
  local id name
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    name=$(docker inspect --format '{{.Name}}' "${id}" 2>/dev/null || true)
    name=${name#/}
    docker rm -f -v "${id}" >/dev/null || true
    if [[ -n "${name}" ]]; then
      docker network rm "${name}" >/dev/null 2>&1 || true
    fi
  done < <(docker ps -aq --filter label=aap-crrr-job=1 --filter "label=aap-crrr-slot=$1")
}

remove_job_containers() {
  local stale
  while IFS= read -r stale; do
    if [[ -n "${stale}" ]]; then
      docker rm -f "${stale}" || true
    fi
  done < <(docker ps -aq --filter label=aap-crrr-job=1)
  docker network prune -f --filter label=aap-crrr-job=1 >/dev/null || true
}

# One slot runs one job at a time, forever. A job that exits non-zero is the
# normal path: the slot logs it and takes the next job. The slot drops the
# parent's traps so only the parent cleans up the pool.
slot_loop() {
  local slot="$1"
  trap - EXIT TERM INT
  while true; do
    if ! disk_ok; then
      sleep 60
      continue
    fi
    if ! run_one "${slot}"; then
      echo "slot ${slot}: runner container exited non-zero; workspace was removed with the container" >&2
      sleep 5
    fi
  done
}

# Seconds to wait before restarting a slot that has died $1 times in a row.
slot_restart_delay() {
  local delay=$((10 * $1))
  if [[ "${delay}" -gt 60 ]]; then
    delay=60
  fi
  printf '%s\n' "${delay}"
}

start_slot() {
  local slot="$1" delay="$2"
  SLOT_STARTED[slot]=$(($(date +%s) + delay))
  {
    sleep "${delay}"
    slot_loop "${slot}"
  } &
  SLOT_PIDS[slot]=$!
}

# SIGTERM, SIGINT, or exit: stop every slot, remove every job container by
# label, prune job networks, and reap the slots.
stop_pool() {
  local pid
  trap - EXIT TERM INT
  for pid in "${SLOT_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  remove_job_containers
  wait 2>/dev/null || true
}

# A dead slot is restarted alone; the other slots' jobs keep running. A
# retired slot leaves SLOT_PIDS, so wait only sees live slots and never
# matches a retired PID again. wait -n -p needs bash 5.1. Ubuntu 24.04 ships 5.2.
run_pool() {
  local slot i died now
  trap 'stop_pool; exit 143' TERM INT
  trap stop_pool EXIT
  for ((slot = 1; slot <= AAP_RUNNER_COUNT; slot++)); do
    SLOT_FAILS[slot]=0
    start_slot "${slot}" 0
  done
  while true; do
    if [[ "${#SLOT_PIDS[@]}" -eq 0 ]]; then
      echo "all ${AAP_RUNNER_COUNT} slots retired; stopping the manager" >&2
      exit 1
    fi
    died=""
    wait -n -p died "${SLOT_PIDS[@]}" || true
    slot=""
    for i in "${!SLOT_PIDS[@]}"; do
      if [[ "${SLOT_PIDS[i]}" == "${died}" ]]; then
        slot=${i}
      fi
    done
    if [[ -z "${slot}" ]]; then
      sleep 1
      continue
    fi
    now=$(date +%s)
    if [[ $((now - SLOT_STARTED[slot])) -lt "${SLOT_FAST_SECONDS}" ]]; then
      SLOT_FAILS[slot]=$((SLOT_FAILS[slot] + 1))
    else
      SLOT_FAILS[slot]=1
    fi
    remove_slot_containers "${slot}"
    if [[ "${SLOT_FAILS[slot]}" -ge "${SLOT_MAX_FAILS}" ]]; then
      echo "slot ${slot} retired after ${SLOT_FAILS[slot]} fast deaths; other slots keep running" >&2
      unset "SLOT_PIDS[${slot}]"
      continue
    fi
    echo "slot ${slot} exited; restarting it" >&2
    start_slot "${slot}" "$(slot_restart_delay "${SLOT_FAILS[slot]}")"
  done
}

main() {
  if [[ "${BASH_VERSINFO[0]}" -lt 5 || ("${BASH_VERSINFO[0]}" -eq 5 && "${BASH_VERSINFO[1]}" -lt 1) ]]; then
    echo "refusing: bash ${BASH_VERSION} is older than 5.1; the slot supervisor needs wait -n -p" >&2
    exit 1
  fi

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
  resolve_runner_uid
  remove_job_containers
  echo "runner pool: ${AAP_RUNNER_COUNT} slot(s), each --cpus ${SLOT_CPUS} --memory ${SLOT_MEMORY} --pids-limit ${AAP_JOB_PIDS_LIMIT}"
  run_pool
}

# Runs only when executed. tests/ source this file for its functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
