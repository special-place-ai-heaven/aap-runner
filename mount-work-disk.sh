#!/bin/bash
# Mount the fixed work disk at /var/lib/ghrunner by the UUID written at
# install, then bind containerd and sysbox state onto that disk.
# Missing disk, wrong size, or a failed mount exits non-zero.
# dockerd and sysbox refuse to start until this unit has finished.
set -euo pipefail

UUID_FILE=/etc/aap-runner/work-disk.uuid
CONFIG_PATH=/etc/aap-runner/manager.conf
MOUNT=/var/lib/ghrunner
BY_UUID_DIR=/dev/disk/by-uuid
# df -BG of an ext4 is a few GiB under the VHDX. Accept configured size -10..+4.
# AAP_WORK_DISK_GIB is 20..512, and the mount UUID must not be the distro root.
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

# Read only the size key. The manager parser also requires App ids, which
# this unit does not have when it runs before the first job.
read_work_disk_gib() {
  local line key val gib=""
  if [[ -r "${CONFIG_PATH}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      case "${line}" in
        '' | \#*) continue ;;
      esac
      key=${line%%=*}
      val=${line#*=}
      if [[ "${key}" == "AAP_WORK_DISK_GIB" && -n "${val}" ]]; then
        gib=${val}
      fi
    done < "${CONFIG_PATH}"
  fi
  [[ -z "${gib}" ]] && gib=60
  apply_disk_window "${gib}"
}

uuid_ok() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# The size window is not identity. The mount's device must differ from /
# and its UUID must be the work disk written at install.
work_mount_matches() {
  local dev="$1" root_dev="$2" mount_uuid="$3" expect_uuid="$4"
  [[ -n "${dev}" && -n "${root_dev}" && "${dev}" != "${root_dev}" ]] || return 1
  uuid_ok "${expect_uuid}" || return 1
  [[ "${mount_uuid}" == "${expect_uuid}" ]]
}

assert_work_mount_device() {
  local mount="$1" expect="$2" dev root_dev mount_uuid
  dev=$(df -P "${mount}" | awk 'NR==2 { print $1 }')
  root_dev=$(df -P / | awk 'NR==2 { print $1 }')
  mount_uuid=$(findmnt -n -o UUID --target "${mount}" 2>/dev/null | tr -d '[:space:]' || true)
  if ! work_mount_matches "${dev}" "${root_dev}" "${mount_uuid}" "${expect}"; then
    echo "refusing: ${mount} dev=${dev:-missing} uuid=${mount_uuid:-missing}; / is ${root_dev:-missing}; work-disk.uuid=${expect:-missing}" >&2
    return 1
  fi
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

# findmnt prints a bind's SOURCE as device[path inside that filesystem].
# On Fresh: /dev/sde[/containerd] for ${MOUNT}/containerd, so the path is
# relative to the work disk's root. disk_dev is the SOURCE of ${MOUNT}.
bind_source_ok() {
  local src="$1" expect="$2" disk_dev="${3:-}" rel=""
  if [[ "${src}" == "${expect}" || "${src}" == *"[$expect]" ]]; then
    return 0
  fi
  [[ -n "${disk_dev}" && "${expect}" == "${MOUNT}/"* ]] || return 1
  rel=${expect#"${MOUNT}"}
  [[ "${src}" == "${disk_dev}[${rel}]" ]]
}

bind_work_dir() {
  local dest="$1" link="$2" src
  if mountpoint -q "${link}"; then
    src=$(findmnt -n -o SOURCE "${link}")
    if ! bind_source_ok "${src}" "${dest}" "$(findmnt -n -o SOURCE "${MOUNT}" 2>/dev/null || true)"; then
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
  local size expect
  if ! mountpoint -q "${MOUNT}"; then
    echo "refusing: ${MOUNT} is not a mountpoint" >&2
    exit 1
  fi
  expect=$(tr -d '[:space:]' < "${UUID_FILE}")
  if ! assert_work_mount_device "${MOUNT}" "${expect}"; then
    exit 1
  fi
  size=$(df -BG --output=size "${MOUNT}" | awk 'NR==2 { gsub(/G/, "", $1); print $1 }')
  if ! size_is_work_disk "${size}"; then
    echo "refusing: ${MOUNT} is ${size:-unknown}G; the work disk is ${WORK_DISK_GIB}G (${WORK_DISK_MIN_GB}-${WORK_DISK_MAX_GB})" >&2
    exit 1
  fi
}

# bootstrap also writes an fstab line for ${MOUNT}, so systemd has a
# var-lib-ghrunner.mount unit, and installed hosts keep that line. That unit
# mounts the disk at boot and again when the device appears late, so either
# mounter may win. An existing mount is accepted here; assert_mounted then
# requires work-disk.uuid, a device that is not /, and the size window.
mount_by_uuid() {
  local uuid="$1" _
  install -d -m 755 -o root -g root "${MOUNT}"
  if mountpoint -q "${MOUNT}"; then
    return 0
  fi
  for _ in $(seq 1 60); do
    if [[ -e "${BY_UUID_DIR}/${uuid}" ]]; then
      if mount -U "${uuid}" "${MOUNT}"; then
        return 0
      fi
      # The fstab unit mounted it between mountpoint and mount -U, so mount -U
      # failed with "already mounted". Seen on Fresh, 2026-10-12.
      if mountpoint -q "${MOUNT}"; then
        echo "${MOUNT} was mounted by another unit during mount -U; checking it" >&2
        return 0
      fi
      echo "mount -U ${uuid} ${MOUNT} failed" >&2
      exit 1
    fi
    sleep 2
  done
  echo "work disk UUID ${uuid} did not appear" >&2
  exit 1
}

# mount_by_uuid then assert_mounted, as the unit runs them, against mocks.
# before: yes (the fstab unit mounted first), race (it mounts while mount -U
# runs), fail (mount -U fails and nothing is mounted). found: findmnt's UUID.
# A new bash, so set -e acts as in the unit. Inside `if` it would be ignored.
mount_case() {
  local dir rc=0
  dir=$(mktemp -d)
  # shellcheck disable=SC2016
  bash -c "set -euo pipefail
$(declare -f apply_disk_window uuid_ok work_mount_matches assert_work_mount_device size_is_work_disk assert_mounted mount_by_uuid)"'
    before=$1 found=$2 want=$3 dir=$4
    MOUNT="${dir}/mnt"
    UUID_FILE="${dir}/work-disk.uuid"
    BY_UUID_DIR="${dir}/by-uuid"
    mkdir -p "${BY_UUID_DIR}"
    printf "%s\n" "${want}" > "${UUID_FILE}"
    : > "${BY_UUID_DIR}/${want}"
    install() { :; }
    sleep() { :; }
    mountpoint() { [[ "${before}" == yes || -e "${dir}/mounted" ]]; }
    mount() {
      if [[ "${before}" == race ]]; then
        : > "${dir}/mounted"
      fi
      echo "mount: ${MOUNT}: already mounted" >&2
      return 32
    }
    findmnt() { printf "%s\n" "${found}"; }
    df() {
      case "$*" in
        "-P /") printf "Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/sdc 1 1 1 1%% /\n" ;;
        -P*) printf "Filesystem 1K-blocks Used Available Use%% Mounted on\n/dev/sde 1 1 1 1%% /x\n" ;;
        *) printf "1G-blocks\n      98G\n" ;;
      esac
    }
    apply_disk_window 100
    mount_by_uuid "${want}"
    assert_mounted
  ' _ "$1" "$2" "$3" "${dir}" >/dev/null 2>&1 || rc=$?
  rm -rf "${dir}"
  return "${rc}"
}

self_check() {
  local tmp link dest sample
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
  # Recorded on Fresh: findmnt -n -o SOURCE /var/lib/containerd.
  if ! MOUNT=/var/lib/ghrunner bind_source_ok "/dev/sde[/containerd]" "/var/lib/ghrunner/containerd" /dev/sde; then
    echo "the Fresh bind source /dev/sde[/containerd] was refused" >&2
    exit 1
  fi
  if MOUNT=/var/lib/ghrunner bind_source_ok "/dev/sdd[/containerd]" "/var/lib/ghrunner/containerd" /dev/sde; then
    echo "a bind from another disk was accepted" >&2
    exit 1
  fi
  if MOUNT=/var/lib/ghrunner bind_source_ok "/dev/sde[/sysbox]" "/var/lib/ghrunner/containerd" /dev/sde; then
    echo "a bind of another directory was accepted" >&2
    exit 1
  fi
  rm -rf "${tmp}"
  apply_disk_window 60
  [[ "${WORK_DISK_MIN_GB}" == "50" && "${WORK_DISK_MAX_GB}" == "64" ]]
  if ! size_is_work_disk 60 || ! size_is_work_disk 50 || ! size_is_work_disk 64; then
    echo "60G work disk was rejected" >&2
    exit 1
  fi
  if size_is_work_disk 49 || size_is_work_disk 65 || size_is_work_disk 1000; then
    echo "a filesystem that is not the 60G work disk was accepted" >&2
    exit 1
  fi
  apply_disk_window 100
  [[ "${WORK_DISK_GIB}" == "100" ]]
  [[ "${WORK_DISK_MIN_GB}" == "90" && "${WORK_DISK_MAX_GB}" == "104" ]]
  if ! size_is_work_disk 100 || ! size_is_work_disk 90 || ! size_is_work_disk 104; then
    echo "100G work disk was rejected" >&2
    exit 1
  fi
  if size_is_work_disk 89 || size_is_work_disk 105 || size_is_work_disk 1000; then
    echo "a filesystem that is not the 100G work disk was accepted" >&2
    exit 1
  fi
  if apply_disk_window 9; then
    echo "a 9 GiB work disk was accepted" >&2
    exit 1
  fi
  if apply_disk_window 513; then
    echo "a 513 GiB work disk was accepted" >&2
    exit 1
  fi
  apply_disk_window 512
  [[ "${WORK_DISK_MIN_GB}" == "502" && "${WORK_DISK_MAX_GB}" == "516" ]]
  sample=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
  if ! work_mount_matches /dev/sdb1 /dev/sda "${sample}" "${sample}"; then
    echo "a distinct work-disk device was rejected" >&2
    exit 1
  fi
  if work_mount_matches /dev/sda /dev/sda "${sample}" "${sample}"; then
    echo "the distro root device was accepted as the work disk" >&2
    exit 1
  fi
  if work_mount_matches /dev/sdb1 /dev/sda "${sample}" bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee; then
    echo "a different filesystem UUID was accepted" >&2
    exit 1
  fi
  if ! mount_case yes "${sample}" "${sample}"; then
    echo "an existing mount of the work-disk UUID was refused" >&2
    exit 1
  fi
  if ! mount_case race "${sample}" "${sample}"; then
    echo "the fstab unit winning the mount race failed the unit" >&2
    exit 1
  fi
  if mount_case yes bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee "${sample}"; then
    echo "an existing mount of another UUID was accepted" >&2
    exit 1
  fi
  if mount_case race bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee "${sample}"; then
    echo "another UUID mounted during the race was accepted" >&2
    exit 1
  fi
  if mount_case fail "${sample}" "${sample}"; then
    echo "a failed mount with nothing mounted was accepted" >&2
    exit 1
  fi
  echo "mount self-check ok"
}

if [[ "${1:-}" == "--self-check" ]]; then
  self_check
  exit 0
fi

read_work_disk_gib
uuid=$(tr -d '[:space:]' < "${UUID_FILE}")
if ! uuid_ok "${uuid}"; then
  echo "refusing: ${UUID_FILE} is not a filesystem UUID" >&2
  exit 1
fi
mount_by_uuid "${uuid}"
assert_mounted
place_state_mounts
