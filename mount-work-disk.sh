#!/bin/bash
# Mount the fixed work disk at /var/lib/ghrunner by the UUID written at
# install. Missing disk, wrong size, or a failed mount exits non-zero.
# dockerd then refuses to start (ConditionPathIsMountPoint).
set -euo pipefail

UUID_FILE=/etc/aap-runner/work-disk.uuid
MOUNT=/var/lib/ghrunner
# df -BG of a 60 GiB ext4 is a few GB under 60. The distro VHD reports ~1000.
WORK_DISK_MIN_GB=50
WORK_DISK_MAX_GB=64

uuid_ok() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

size_is_work_disk() {
  local size="$1"
  [[ "${size}" =~ ^[0-9]+$ ]] || return 1
  [[ "${size}" -ge "${WORK_DISK_MIN_GB}" && "${size}" -le "${WORK_DISK_MAX_GB}" ]]
}

place_sysbox_state() {
  local link=/var/lib/sysbox dest="${MOUNT}/sysbox" current
  install -d -m 711 -o root -g root "${dest}" "${MOUNT}/docker"
  if [[ -L "${link}" ]]; then
    current=$(readlink -f "${link}")
    if [[ "${current}" != "$(readlink -f "${dest}")" ]]; then
      echo "refusing: ${link} points at ${current}" >&2
      exit 1
    fi
    return 0
  fi
  if [[ -d "${link}" ]]; then
    if [[ -n $(find "${link}" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
      find "${link}" -mindepth 1 -maxdepth 1 -exec mv {} "${dest}/" \;
    fi
    rmdir "${link}"
  fi
  ln -s "${dest}" "${link}"
}

assert_mounted() {
  local size
  if ! mountpoint -q "${MOUNT}"; then
    echo "refusing: ${MOUNT} is not a mountpoint" >&2
    exit 1
  fi
  size=$(df -BG --output=size "${MOUNT}" | awk 'NR==2 { gsub(/G/, "", $1); print $1 }')
  if ! size_is_work_disk "${size}"; then
    echo "refusing: ${MOUNT} is ${size:-unknown}G; the work disk is 60G" >&2
    exit 1
  fi
}

mount_by_uuid() {
  local uuid="$1" _
  install -d -m 755 -o root -g root "${MOUNT}"
  if mountpoint -q "${MOUNT}"; then
    return 0
  fi
  for _ in $(seq 1 60); do
    if [[ -e "/dev/disk/by-uuid/${uuid}" ]]; then
      mount -U "${uuid}" "${MOUNT}"
      return 0
    fi
    sleep 2
  done
  echo "work disk UUID ${uuid} did not appear" >&2
  exit 1
}

uuid=$(tr -d '[:space:]' < "${UUID_FILE}")
if ! uuid_ok "${uuid}"; then
  echo "refusing: ${UUID_FILE} is not a filesystem UUID" >&2
  exit 1
fi
mount_by_uuid "${uuid}"
place_sysbox_state
assert_mounted
