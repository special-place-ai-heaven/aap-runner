#!/bin/bash
# Mount the fixed work disk at /var/lib/ghrunner by the UUID written at
# install, then bind containerd and sysbox state onto that disk.
# Missing disk, wrong size, or a failed mount exits non-zero.
# dockerd and sysbox refuse to start until this unit has finished.
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

dir_has_child() {
  [[ -n $(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]
}

# Move a real directory's children onto dest and leave link as an empty
# directory ready for mount --bind. A symlink is removed. Does not mount.
stage_bind_dirs() {
  local dest="$1" link="$2"
  install -d -m 0711 "${dest}"
  if [[ -L "${link}" ]]; then
    rm -f "${link}"
  fi
  if [[ -e "${link}" && ! -d "${link}" ]]; then
    echo "refusing: ${link} exists and is not a directory" >&2
    return 1
  fi
  install -d -m 0711 "${link}"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown root:root "${dest}" "${link}"
  fi
  if dir_has_child "${link}" && dir_has_child "${dest}"; then
    echo "refusing: both ${link} and ${dest} have files; not merging them" >&2
    return 1
  fi
  if dir_has_child "${link}"; then
    find "${link}" -mindepth 1 -maxdepth 1 -exec mv {} "${dest}/" \;
  fi
}

bind_source_ok() {
  local src="$1" expect="$2"
  [[ "${src}" == "${expect}" || "${src}" == *"[$expect]" ]]
}

bind_work_dir() {
  local dest="$1" link="$2" src
  if mountpoint -q "${link}"; then
    src=$(findmnt -n -o SOURCE "${link}")
    if ! bind_source_ok "${src}" "${dest}"; then
      echo "refusing: ${link} is mounted from ${src}, not ${dest}" >&2
      exit 1
    fi
    return 0
  fi
  stage_bind_dirs "${dest}" "${link}"
  mount --bind "${dest}" "${link}"
}

clear_stale_containerd_state() {
  local pid
  pid=$(pidof containerd 2>/dev/null || true)
  if [[ -n "${pid}" ]]; then
    return 0
  fi
  find /run/containerd -name '*.sock' -delete 2>/dev/null || true
  rm -f /run/containerd/containerd.pid
}

place_state_mounts() {
  install -d -m 0711 -o root -g root "${MOUNT}/docker" "${MOUNT}/containerd" \
    "${MOUNT}/containerd-state" "${MOUNT}/sysbox"
  # Docker 29 stores images in containerd's root (/var/lib/containerd), not
  # under data-root. The bind is the path every snapshotter writes.
  bind_work_dir "${MOUNT}/containerd" /var/lib/containerd
  bind_work_dir "${MOUNT}/containerd-state" /run/containerd
  clear_stale_containerd_state
  # sysbox-mgr postinst replaces a symlink with a directory. A bind survives
  # that, and the boot unit runs it again before sysbox starts.
  bind_work_dir "${MOUNT}/sysbox" /var/lib/sysbox
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

self_check() {
  local tmp link dest
  tmp=$(mktemp -d)
  link="${tmp}/link"
  dest="${tmp}/dest"
  install -d "${link}" "${dest}"
  printf 'kept\n' > "${link}/from-root"
  stage_bind_dirs "${dest}" "${link}"
  [[ -f "${dest}/from-root" ]]
  [[ ! -e "${link}/from-root" ]]
  rm -rf "${link}"
  ln -s "${dest}" "${link}"
  stage_bind_dirs "${dest}" "${link}"
  [[ -d "${link}" && ! -L "${link}" ]]
  printf 'on-disk\n' > "${dest}/already"
  install -d "${link}"
  printf 'on-root\n' > "${link}/other"
  if stage_bind_dirs "${dest}" "${link}"; then
    echo "two non-empty directories were merged" >&2
    exit 1
  fi
  bind_source_ok "/var/lib/ghrunner/sysbox" "/var/lib/ghrunner/sysbox"
  bind_source_ok "/dev/sdb[/var/lib/ghrunner/sysbox]" "/var/lib/ghrunner/sysbox"
  if bind_source_ok "/var/lib/sysbox" "/var/lib/ghrunner/sysbox"; then
    echo "a different bind source was accepted" >&2
    exit 1
  fi
  rm -rf "${tmp}"
  echo "mount self-check ok"
}

if [[ "${1:-}" == "--self-check" ]]; then
  self_check
  exit 0
fi

uuid=$(tr -d '[:space:]' < "${UUID_FILE}")
if ! uuid_ok "${uuid}"; then
  echo "refusing: ${UUID_FILE} is not a filesystem UUID" >&2
  exit 1
fi
mount_by_uuid "${uuid}"
assert_mounted
place_state_mounts
