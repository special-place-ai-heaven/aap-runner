#!/bin/bash
# Import the aap-runner WSL distro and install Docker Engine + Sysbox.
# Run from the operator's existing WSL distro (interop still on).
# A Sysbox failure stops the install. There is no privileged fallback
# and no host docker socket mount.
set -euo pipefail

DISTRO=aap-runner
INSTALL_DIR=${AAP_RUNNER_INSTALL_DIR:-/mnt/c/aap-runner}
STAGE=${AAP_RUNNER_STAGE:-/mnt/c/aap-runner-staging}
# Written before import. A re-run that still sees aap-runner stops and
# tells the operator to unregister only this distro.
INSTALL_MARKER=${AAP_RUNNER_INSTALL_MARKER:-/mnt/c/wsl/aap-runner.installing}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=labels.sh
source "${SCRIPT_DIR}/labels.sh"
# Exact match for AAP_RUNNER_LABELS_VERSION in labels.sh.
require_labels_version 1 || exit 1
# AAP_WORK_DISK_GIB is this host's fixed VHDX size. Absent means 60 (CRRR).
# diskpart maximum= is MiB (gib * 1024). PowerShell 1GB is 1024^3.
WORK_VHDX=${AAP_WORK_VHDX:-/mnt/c/wsl/aap-runner-work.vhdx}
WORK_DISK_GB=""
WORK_DISK_BYTES=""
WORK_DISK_PART_MB=""

apply_work_disk_size() {
  local gib="${1:-${AAP_WORK_DISK_GIB:-60}}"
  if [[ ! "${gib}" =~ ^[1-9][0-9]*$ ]] || [[ "${gib}" -lt 20 || "${gib}" -gt 512 ]]; then
    echo "refusing: AAP_WORK_DISK_GIB=${gib} is not 20..512" >&2
    return 1
  fi
  WORK_DISK_GB=${gib}
  WORK_DISK_BYTES=$((gib * 1024 * 1024 * 1024))
  WORK_DISK_PART_MB=$((gib * 1024))
}

# Same floor as the manager. ceil(60 * 55%) is 33, and the 60 GiB disk stays at 35.
disk_floor_gb() {
  local gib="$1" floor
  floor=$(( (gib * 55 + 99) / 100 ))
  if [[ "${gib}" -eq 60 && "${floor}" -lt 35 ]]; then
    floor=35
  fi
  printf '%s\n' "${floor}"
}

# First install only. An existing manager.conf is left alone.
# A floor below 55% of this disk is raised so a copied 35 does not under-protect 100 GiB.
stamp_new_manager_conf() {
  local path="$1" floor min_floor
  if ! grep -q '^AAP_WORK_DISK_GIB=' "${path}"; then
    printf 'AAP_WORK_DISK_GIB=%s\n' "${WORK_DISK_GB}" >> "${path}"
  else
    sed -i "s/^AAP_WORK_DISK_GIB=.*/AAP_WORK_DISK_GIB=${WORK_DISK_GB}/" "${path}"
  fi
  min_floor=$(disk_floor_gb "${WORK_DISK_GB}")
  floor=$(awk -F= '/^AAP_DISK_FLOOR_GB=/ { print $2; exit }' "${path}")
  if [[ -z "${floor}" ]]; then
    printf 'AAP_DISK_FLOOR_GB=%s\n' "${min_floor}" >> "${path}"
  elif [[ "${floor}" =~ ^[0-9]+$ ]] && [[ "${floor}" -lt "${min_floor}" ]]; then
    echo "raising AAP_DISK_FLOOR_GB from ${floor} to ${min_floor} in ${path}" >&2
    sed -i "s/^AAP_DISK_FLOOR_GB=.*/AAP_DISK_FLOOR_GB=${min_floor}/" "${path}"
  fi
}

# crrr or fresh, written in the conf. An empty or missing key is refused.
# A present value goes through labels.sh, so uppercase fails the charset
# check before the crrr-or-fresh check.
require_runner_base_label() {
  local path="$1" base="" line key val
  if [[ ! -f "${path}" ]]; then
    echo "refusing: ${path} is missing" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      '' | \#*) continue ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    if [[ "${key}" == "AAP_RUNNER_BASE_LABEL" ]]; then
      base=${val}
    fi
  done < "${path}"
  if [[ -z "${base}" ]]; then
    echo "refusing: AAP_RUNNER_BASE_LABEL is required in ${path}" >&2
    return 1
  fi
  validate_base_label "${base}"
}

apply_work_disk_size || exit 1

# noble/current has no separate rootfs tarball. This is the WSL image at that
# path. The sha256 is the pin; if the "current" file moves, the check stops
# the install. The image is the 2024-04 snapshot, so the distro apt full-upgrades.
UBUNTU_URL=https://cloud-images.ubuntu.com/wsl/releases/noble/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz
UBUNTU_SHA256=8251e27ffff381a4af5f41dcb94d867de3e0d9774a9241908ab34555d99315ea
UBUNTU_NAME=ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz

DOCKER_GPG_URL=https://download.docker.com/linux/ubuntu/gpg
DOCKER_GPG_SHA256=1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570
DOCKER_GPG_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKER_CE_VERSION=5:29.9.0-1~ubuntu.24.04~noble
CONTAINERD_VERSION=2.4.1-2~ubuntu.24.04~noble

SYSBOX_URL=https://github.com/nestybox/sysbox/releases/download/v0.7.1/sysbox-ce_0.7.1.linux_amd64.deb
SYSBOX_SHA256=9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5
SYSBOX_NAME=sysbox-ce_0.7.1.linux_amd64.deb

RUNNER_URL=https://github.com/actions/runner/releases/download/v2.338.0/actions-runner-linux-x64-2.338.0.tar.gz
RUNNER_SHA256=af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32
RUNNER_NAME=actions-runner-linux-x64-2.338.0.tar.gz

verify_sha256() {
  local file="$1" expected="$2" actual
  actual=$(sha256sum "${file}" | awk '{ print $1 }')
  if [[ "${actual}" != "${expected}" ]]; then
    echo "checksum mismatch for ${file}" >&2
    echo "expected ${expected}" >&2
    echo "actual   ${actual}" >&2
    exit 1
  fi
}

download() {
  local url="$1" dest="$2" sha="$3"
  curl --fail --silent --show-error --location --output "${dest}" "${url}"
  verify_sha256 "${dest}" "${sha}"
}

# df of a drvfs mount (the operator distro's /mnt/c) is the Windows volume.
# Used once, to allocate the fixed VHDX. It is not the per-job floor.
avail_gb() {
  df -BG --output=avail "$1" | awk 'NR==2 { gsub(/G/, "", $1); print $1 }'
}

format_work_disk() {
  local name dev fstype uuid line
  local -a names
  mapfile -t names < <(lsblk -bn -d -o NAME,SIZE | awk -v bytes="${WORK_DISK_BYTES}" '$2 == bytes { print $1 }')
  if [[ "${#names[@]}" -ne 1 ]]; then
    echo "expected one ${WORK_DISK_GB}GiB disk (${WORK_DISK_BYTES} bytes); found ${#names[@]}" >&2
    lsblk -bn -d -o NAME,SIZE >&2 || true
    exit 1
  fi
  name=${names[0]}
  dev="/dev/${name}"
  fstype=$(blkid -o value -s TYPE "${dev}" || true)
  if [[ -n "${fstype}" && "${fstype}" != "ext4" ]]; then
    echo "refusing to format ${dev}: filesystem is ${fstype}" >&2
    exit 1
  fi
  if [[ -z "${fstype}" ]]; then
    mkfs.ext4 -F -L aap-runner-work "${dev}"
  fi
  uuid=$(blkid -o value -s UUID "${dev}")
  if [[ ! "${uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "refusing: blkid did not return a UUID for ${dev}" >&2
    exit 1
  fi
  printf '%s\n' "${uuid}" > /etc/aap-runner/work-disk.uuid
  chmod 644 /etc/aap-runner/work-disk.uuid
  line="UUID=${uuid} /var/lib/ghrunner ext4 defaults,noatime,nofail,x-systemd.device-timeout=10s 0 2"
  if ! grep -q ' /var/lib/ghrunner ' /etc/fstab 2>/dev/null; then
    printf '%s\n' "${line}" >> /etc/fstab
  fi
}

install_docker_apt() {
  local tmp fpr
  tmp=$(mktemp)
  download "${DOCKER_GPG_URL}" "${tmp}" "${DOCKER_GPG_SHA256}"
  fpr=$(gpg --show-keys --with-colons "${tmp}" | awk -F: '/^fpr:/ { print $10 }')
  if ! printf '%s\n' "${fpr}" | grep -qx "${DOCKER_GPG_FINGERPRINT}"; then
    echo "Docker apt key fingerprint mismatch" >&2
    printf '%s\n' "${fpr}" >&2
    exit 1
  fi
  install -d -m 0755 /etc/apt/keyrings
  gpg --dearmor < "${tmp}" > /etc/apt/keyrings/docker.gpg
  chmod 0644 /etc/apt/keyrings/docker.gpg
  rm -f "${tmp}"
  printf '%s\n' 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' \
    > /etc/apt/sources.list.d/docker.list
}

# A non-zero status from wsl.exe, powershell.exe, or schtasks.exe stops
# the install. The message names the command and the exit code.
run_checked() {
  local desc="$1" rc=0
  shift
  "$@" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "refusing: ${desc} failed (exit ${rc})" >&2
    exit 1
  fi
}

require_operator_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "refusing: jq is required on the operator distro. Install it with: sudo apt-get install jq" >&2
    exit 1
  fi
}

# UTF-16 from wsl.exe is NUL-separated. Command substitution truncates at
# the first NUL, so strip them in the pipe before the match.
mount_text_is_already() {
  local text
  text=$(printf '%s' "$1" | tr -d '\000')
  [[ "${text}" == *[Aa]lready* ]]
}

distro_exists() {
  local list rc=0
  list=$(wsl.exe -l -q 2>&1) || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    printf '%s\n' "${list}" | tr -d '\000' >&2
    echo "refusing: wsl.exe -l -q failed (exit ${rc})" >&2
    exit 1
  fi
  printf '%s' "${list}" | tr -d '\000\r' | grep -qx "${DISTRO}"
}

# Half-installed aap-runner is not resumed. The command names only this distro.
half_install_refusal() {
  printf '%s\n' "refusing: distro ${DISTRO} is already registered. A half-installed distro is not resumed."
  printf '%s\n' "Unregister only this distro, then re-run bootstrap:"
  printf '%s\n' "wsl --unregister ${DISTRO}"
  printf '%s\n' "That command does not unregister any other distro."
}

copy_staged() {
  local name="$1" dest="$2"
  cp "${STAGE}/${name}" "${dest}"
}

# sudo 1.9.15p5 exits 0 for `sudo -n -l -U user` even when the text is
# "User <name> is not allowed to run sudo". The sentence is the check.
# Returns 0 when the user may run commands, 1 when the denial sentence is
# present, 2 when the listing is neither (fail closed).
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

# Keep sysbox's runtimes object. The template only sets data-root and ipv6.
# Replacing the file drops "sysbox-runc" and docker info no longer lists it.
merge_daemon_json() {
  local template="$1" dest=/etc/docker/daemon.json had="" merged
  install -d -m 755 /etc/docker
  if [[ ! -s "${template}" ]]; then
    echo "refusing: daemon template ${template} is missing" >&2
    exit 1
  fi
  if [[ ! -s "${dest}" ]]; then
    cp "${template}" "${dest}"
    chmod 644 "${dest}"
    return 0
  fi
  if jq -e '.runtimes["sysbox-runc"]' "${dest}" >/dev/null 2>&1; then
    had=yes
  fi
  if ! merged=$(jq -c -s '.[0] * .[1]' "${dest}" "${template}"); then
    echo "refusing: ${dest} is not JSON; not replacing it" >&2
    exit 1
  fi
  printf '%s\n' "${merged}" > "${dest}"
  chmod 644 "${dest}"
  if [[ "${had}" == "yes" ]] && ! jq -e '.runtimes["sysbox-runc"]' "${dest}" >/dev/null; then
    echo "refusing: merge dropped sysbox-runc from ${dest}" >&2
    exit 1
  fi
  if ! jq -e '.["data-root"] == "/var/lib/ghrunner/docker" and .ipv6 == false' "${dest}" >/dev/null; then
    echo "refusing: ${dest} is missing the work-disk data-root or ipv6 false" >&2
    exit 1
  fi
}

inside_packages() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ -e /usr/bin/docker ]]; then
    local docker_path
    docker_path=$(readlink -f /usr/bin/docker || true)
    case "${docker_path}" in
      *docker-desktop*)
        echo "Docker Desktop CLI is on this distro. Disable WSL integration for aap-runner." >&2
        exit 1
        ;;
    esac
  fi
  if [[ -S /mnt/wsl/docker-desktop/shared-sockets/guest-services/docker.sock ]]; then
    echo "Docker Desktop WSL integration socket is present. Disable it for aap-runner." >&2
    exit 1
  fi

  apt-get update
  apt-get full-upgrade -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold
  apt-get install -y --no-install-recommends \
    adduser \
    ca-certificates \
    curl \
    dbus \
    e2fsprogs \
    git \
    gnupg \
    iptables \
    jq \
    nftables \
    openssl \
    passwd \
    sudo \
    systemd \
    systemd-sysv
  if dpkg -s docker.io >/dev/null 2>&1; then
    apt-get purge -y docker.io
  fi
  install_docker_apt
  apt-get update
  apt-get install -y --no-install-recommends \
    "docker-ce=${DOCKER_CE_VERSION}" \
    "docker-ce-cli=${DOCKER_CE_VERSION}" \
    "containerd.io=${CONTAINERD_VERSION}"
  dockerd --version | grep -q '29.9.0'
  containerd --version | grep -q '2.4.1'

  if ! id ghrunner >/dev/null 2>&1; then
    if getent passwd 1002 >/dev/null; then
      echo "uid 1002 is already assigned; ghrunner must be uid 1002" >&2
      exit 1
    fi
    useradd --uid 1002 --create-home --shell /bin/bash ghrunner
  fi
  if [[ "$(id -u ghrunner)" != "1002" ]]; then
    echo "ghrunner uid is $(id -u ghrunner); expected 1002" >&2
    exit 1
  fi
  passwd -l ghrunner

  install -d -m 700 -o root -g root /etc/aap-runner /opt/aap-runner /var/lib/aap-runner/image /usr/local/sbin
  copy_staged "${UBUNTU_NAME}" "/var/lib/aap-runner/image/${UBUNTU_NAME}"
  copy_staged "${RUNNER_NAME}" "/var/lib/aap-runner/image/${RUNNER_NAME}"
  copy_staged "${SYSBOX_NAME}" "/var/lib/aap-runner/${SYSBOX_NAME}"
  copy_staged Dockerfile /var/lib/aap-runner/image/Dockerfile
  copy_staged ephemeral-entry.sh /var/lib/aap-runner/image/ephemeral-entry.sh
  copy_staged manager.sh /usr/local/sbin/aap-runner-manager
  copy_staged labels.sh /usr/local/sbin/labels.sh
  copy_staged evidence.sh /usr/local/sbin/aap-runner-evidence
  copy_staged mount-work-disk.sh /usr/local/sbin/aap-mount-work-disk
  copy_staged aap-runner-manager.service /etc/systemd/system/aap-runner-manager.service
  copy_staged aap-workdisk.service /etc/systemd/system/aap-workdisk.service
  install -d -m 755 /etc/docker /etc/systemd/system/docker.service.d \
    /etc/systemd/system/containerd.service.d \
    /etc/systemd/system/sysbox.service.d \
    /etc/systemd/system/sysbox-mgr.service.d \
    /etc/systemd/system/sysbox-fs.service.d
  copy_staged daemon.json /etc/aap-runner/daemon.json
  merge_daemon_json /etc/aap-runner/daemon.json
  copy_staged docker-workdisk.conf /etc/systemd/system/docker.service.d/workdisk.conf
  copy_staged docker-workdisk.conf /etc/systemd/system/containerd.service.d/workdisk.conf
  copy_staged docker-workdisk.conf /etc/systemd/system/sysbox.service.d/workdisk.conf
  copy_staged docker-workdisk.conf /etc/systemd/system/sysbox-mgr.service.d/workdisk.conf
  copy_staged docker-workdisk.conf /etc/systemd/system/sysbox-fs.service.d/workdisk.conf
  copy_staged nftables.conf /etc/aap-runner/nftables.conf
  copy_staged wsl.conf /etc/wsl.conf
  if [[ ! -f /etc/aap-runner/manager.conf ]]; then
    copy_staged manager.conf.example /etc/aap-runner/manager.conf
    stamp_new_manager_conf /etc/aap-runner/manager.conf
  fi
  require_runner_base_label /etc/aap-runner/manager.conf
  chmod 755 /usr/local/sbin/aap-runner-manager /usr/local/sbin/aap-runner-evidence \
    /usr/local/sbin/aap-mount-work-disk \
    /var/lib/aap-runner/image/ephemeral-entry.sh
  chmod 644 /etc/docker/daemon.json /etc/systemd/system/docker.service.d/workdisk.conf \
    /etc/systemd/system/aap-workdisk.service /usr/local/sbin/labels.sh
  chmod 400 /etc/aap-runner/manager.conf
  chown root:root /etc/aap-runner/manager.conf /usr/local/sbin/aap-runner-manager \
    /etc/docker/daemon.json
  format_work_disk

  verify_sha256 "/var/lib/aap-runner/image/${UBUNTU_NAME}" "${UBUNTU_SHA256}"
  verify_sha256 "/var/lib/aap-runner/image/${RUNNER_NAME}" "${RUNNER_SHA256}"
  verify_sha256 "/var/lib/aap-runner/${SYSBOX_NAME}" "${SYSBOX_SHA256}"
}

rewrite_dns_resolvers() {
  local ns ipv4="" ipv6="" sep4="" sep6=""
  while read -r ns; do
    if [[ "${ns}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      ipv4="${ipv4}${sep4}${ns}"
      sep4=", "
    elif [[ "${ns}" == *:* && "${ns}" != *[!0-9a-fA-F:]* ]]; then
      ipv6="${ipv6}${sep6}${ns}"
      sep6=", "
    else
      echo "skipping unparsed nameserver ${ns}" >&2
    fi
  done < <(awk '/^nameserver[[:space:]]/ { print $2 }' /etc/resolv.conf)
  if [[ -z "${ipv4}" ]]; then
    ipv4="127.0.0.53"
  fi
  sed -i "s|elements = { 127.0.0.53 }|elements = { ${ipv4} }|" /etc/nftables.conf
  if [[ -n "${ipv6}" ]]; then
    sed -i "s|type ipv6_addr|type ipv6_addr\\n    elements = { ${ipv6} }|" /etc/nftables.conf
  fi
}

assert_sysbox_runtime() {
  local runtimes
  runtimes=$(docker info --format '{{json .Runtimes}}' 2>&1 || true)
  printf '%s\n' "${runtimes}"
  if ! printf '%s\n' "${runtimes}" | grep -q 'sysbox-runc'; then
    echo "refusing: sysbox-runc is not in docker info runtimes" >&2
    exit 1
  fi
}

assert_image_store_on_work_disk() {
  local path dev work src
  work=$(df -P /var/lib/ghrunner | awk 'NR==2 { print $1 }')
  if [[ -z "${work}" ]]; then
    echo "refusing: df of /var/lib/ghrunner was empty" >&2
    exit 1
  fi
  for path in /var/lib/containerd /var/lib/ghrunner/docker /run/containerd /var/lib/sysbox; do
    dev=$(df -P "${path}" | awk 'NR==2 { print $1 }')
    if [[ "${dev}" != "${work}" ]]; then
      echo "refusing: ${path} is on ${dev:-missing}; work disk is ${work}" >&2
      exit 1
    fi
  done
  for path in /var/lib/containerd /run/containerd /var/lib/sysbox; do
    if ! mountpoint -q "${path}"; then
      echo "refusing: ${path} is not a bind mount onto the work disk" >&2
      exit 1
    fi
    src=$(findmnt -n -o SOURCE "${path}")
    case "${path}" in
      /var/lib/containerd) bind_source_expect "${src}" /var/lib/ghrunner/containerd ;;
      /run/containerd) bind_source_expect "${src}" /var/lib/ghrunner/containerd-state ;;
      /var/lib/sysbox) bind_source_expect "${src}" /var/lib/ghrunner/sysbox ;;
    esac
  done
}

bind_source_expect() {
  local src="$1" expect="$2"
  if [[ "${src}" == "${expect}" || "${src}" == *"[$expect]" ]]; then
    return 0
  fi
  echo "refusing: bind source ${src} is not ${expect}" >&2
  exit 1
}

inside_runtime() {
  local state rootdir listing grant_rc
  refuse_mirrored_networking
  state=""
  for _ in $(seq 1 30); do
    state=$(systemctl is-system-running || true)
    case "${state}" in
      running | degraded) break ;;
    esac
    sleep 2
  done
  case "${state}" in
    running | degraded) ;;
    *)
      echo "systemd did not become ready (state ${state})" >&2
      exit 1
      ;;
  esac

  systemctl daemon-reload
  systemctl enable aap-workdisk
  systemctl stop docker containerd sysbox sysbox-mgr sysbox-fs >/dev/null 2>&1 || true
  /usr/local/sbin/aap-mount-work-disk

  apt-get install -y "/var/lib/aap-runner/${SYSBOX_NAME}"
  systemctl stop docker containerd sysbox sysbox-mgr sysbox-fs >/dev/null 2>&1 || true
  /usr/local/sbin/aap-mount-work-disk
  merge_daemon_json /etc/aap-runner/daemon.json
  if systemctl cat sysbox.service >/dev/null 2>&1; then
    systemctl enable --now sysbox
  else
    systemctl enable --now sysbox-mgr
    systemctl enable --now sysbox-fs
  fi
  systemctl enable --now containerd
  systemctl enable --now docker
  systemctl restart docker
  rootdir=$(docker info -f '{{.DockerRootDir}}')
  if [[ "${rootdir}" != "/var/lib/ghrunner/docker" ]]; then
    echo "dockerd data-root is ${rootdir}; expected /var/lib/ghrunner/docker" >&2
    exit 1
  fi
  assert_dockerd_ipv6_off
  assert_sysbox_runtime
  assert_image_store_on_work_disk

  if ! docker build -t aap-crrr-runner:local /var/lib/aap-runner/image; then
    echo "runner image build failed; install stopped" >&2
    exit 1
  fi

  # Preflight is the gate. Phase 1 passed on kernel 6.18.35.2 with idmapped
  # mounts and no shiftfs. A failure here still stops the install.
  docker create --runtime=sysbox-runc --name aap-sysbox-preflight \
    --entrypoint /opt/aap-runner/ephemeral-entry.sh \
    aap-crrr-runner:local --preflight
  if ! /usr/local/sbin/aap-runner-manager --assert-mounts aap-sysbox-preflight; then
    docker rm -f aap-sysbox-preflight || true
    echo "ERROR: preflight container has a mount under /mnt. Install stopped." >&2
    exit 1
  fi
  if ! docker start --attach aap-sysbox-preflight; then
    docker rm -f aap-sysbox-preflight || true
    echo "ERROR: Sysbox preflight failed on this WSL2 kernel." >&2
    echo "Install stopped. No privileged container fallback and no host docker.sock mount." >&2
    exit 1
  fi
  docker rm -f aap-sysbox-preflight

  cp /etc/aap-runner/nftables.conf /etc/nftables.conf
  rewrite_dns_resolvers
  nft -f /etc/nftables.conf
  systemctl enable nftables

  systemctl enable aap-runner-manager

  if [[ "$(id -u ghrunner)" != "1002" ]]; then
    echo "ghrunner uid is $(id -u ghrunner); expected 1002" >&2
    exit 1
  fi
  if id -nG ghrunner | tr ' ' '\n' | grep -qx docker; then
    echo "ghrunner is in the docker group" >&2
    exit 1
  fi
  if id -nG ghrunner | tr ' ' '\n' | grep -qx sudo; then
    echo "ghrunner is in the sudo group" >&2
    exit 1
  fi
  if ! listing=$(sudo -n -l -U ghrunner 2>&1); then
    echo "refusing: sudo -l -U ghrunner failed" >&2
    printf '%s\n' "${listing}" >&2
    exit 1
  fi
  grant_rc=0
  sudo_listing_grants "${listing}" || grant_rc=$?
  if [[ "${grant_rc}" -ne 1 ]]; then
    echo "refusing: ghrunner sudo listing is not a denial" >&2
    printf '%s\n' "${listing}" >&2
    exit 1
  fi
  if [[ -d /mnt/c ]]; then
    echo "automount is still on: /mnt/c exists after lockdown" >&2
    exit 1
  fi
  echo "aap-runner install finished. Place the GitHub App key at /etc/aap-runner/app.pem mode 0400, fill /etc/aap-runner/manager.conf, then systemctl start aap-runner-manager."
}

wslconfig_sets_mirrored() {
  local file="$1"
  grep -Eiq '^[[:space:]]*networkingMode[[:space:]]*=[[:space:]]*mirrored[[:space:]]*(#.*)?$' "${file}"
}

# Echoes a reason and returns 0 when bootstrap must stop.
# Returns 1 when networkingMode is proven not mirrored.
# inside=yes is the aap-runner distro. cfg_state is absent, nat, mirrored,
# unreadable, or skipped (not looked at, because /mnt/c is gone).
networking_stop_reason() {
  local inside="$1" have_wslinfo="$2" mode="$3" cfg_state="$4"
  if printf '%s\n' "${mode}" | grep -Eiq '^mirrored$'; then
    echo "WSL networkingMode is mirrored (wslinfo). Use NAT."
    return 0
  fi
  if [[ "${have_wslinfo}" == "yes" && -z "${mode}" ]]; then
    echo "wslinfo returned no networkingMode"
    return 0
  fi
  if [[ "${inside}" == "yes" && ( "${have_wslinfo}" != "yes" || -z "${mode}" ) ]]; then
    echo "wslinfo is missing inside aap-runner; cannot prove networkingMode is not mirrored"
    return 0
  fi
  case "${cfg_state}" in
    unreadable)
      echo ".wslconfig is unreadable; cannot prove networkingMode is not mirrored"
      return 0
      ;;
    mirrored)
      echo ".wslconfig sets networkingMode=mirrored. Use NAT, then wsl --shutdown."
      return 0
      ;;
    absent | nat | skipped) ;;
    *)
      echo ".wslconfig state '${cfg_state}' is not a proof"
      return 0
      ;;
  esac
  return 1
}

# wslinfo is the live mode. .wslconfig is the next boot. Either one saying
# mirrored stops the install. Inside aap-runner a missing wslinfo stops it
# too, and an unreadable .wslconfig stops it. Mirrored mode puts the distro
# on the Windows LAN and the bridge filter does not see that traffic.
refuse_mirrored_networking() {
  local mode="" have_wslinfo=no inside=no cfg_state=skipped
  local raw="" profile="" cfg="" reason="" grep_rc=0 ps_rc=0
  if [[ "${WSL_DISTRO_NAME:-}" == "${DISTRO}" || ! -d /mnt/c ]]; then
    inside=yes
  fi
  if command -v wslinfo >/dev/null 2>&1; then
    have_wslinfo=yes
    mode=$(wslinfo --networking-mode 2>/dev/null | tr -d '\r' | head -n 1 || true)
  fi
  if [[ -d /mnt/c ]]; then
    cfg_state=unreadable
    if command -v powershell.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
      ps_rc=0
      raw=$(powershell.exe -NoProfile -NonInteractive -Command '[Environment]::GetFolderPath("UserProfile")' | tr -d '\000\r') || ps_rc=$?
      if [[ "${ps_rc}" -ne 0 ]]; then
        echo "refusing: powershell.exe could not read the Windows user profile (exit ${ps_rc})" >&2
        exit 1
      fi
      if [[ -n "${raw}" ]]; then
        profile=$(wslpath -u "${raw}" || true)
      fi
      if [[ -n "${profile}" ]]; then
        cfg="${profile}/.wslconfig"
        if [[ ! -e "${cfg}" ]]; then
          cfg_state=absent
        elif [[ -f "${cfg}" && -r "${cfg}" ]]; then
          grep_rc=0
          wslconfig_sets_mirrored "${cfg}" || grep_rc=$?
          if [[ "${grep_rc}" -eq 0 ]]; then
            cfg_state=mirrored
          elif [[ "${grep_rc}" -eq 1 ]]; then
            cfg_state=nat
          else
            cfg_state=unreadable
          fi
        fi
      fi
    fi
  fi
  if reason=$(networking_stop_reason "${inside}" "${have_wslinfo}" "${mode}" "${cfg_state}"); then
    echo "refusing: ${reason}" >&2
    exit 1
  fi
}

assert_dockerd_ipv6_off() {
  local enabled
  enabled=$(docker network inspect bridge --format '{{.EnableIPv6}}')
  if [[ "${enabled}" != "false" ]]; then
    echo "refusing: dockerd IPv6 is '${enabled}'; expected false" >&2
    exit 1
  fi
}

lock_windows_admin_only() {
  local win="$1"
  if ! powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$(wslpath -w "${SCRIPT_DIR}/lock-acl.ps1")" \
    -LiteralPath "${win}"; then
    echo "refusing: ACL on ${win} is not limited to SYSTEM and Administrators" >&2
    exit 1
  fi
}

lock_work_disk_acl() {
  local dir
  dir=$(dirname "${WORK_VHDX}")
  lock_windows_admin_only "$(wslpath -w "${dir}")"
  lock_windows_admin_only "$(wslpath -w "${WORK_VHDX}")"
}

# Create the directory and lock it before any file is written there.
lock_created_windows_dir() {
  local linux_dir="$1"
  mkdir -p "${linux_dir}"
  lock_windows_admin_only "$(wslpath -w "${linux_dir}")"
}

# Same rule as create-work-vhdx.ps1. Checked here so a bad path never
# reaches diskpart.
vhdx_windows_path_ok() {
  [[ "$1" =~ ^[A-Za-z]:\\[A-Za-z0-9\ _.\\-]+\.vhdx$ ]]
}

self_check() {
  local tmp cfg reason rc err body msg gap nulled
  require_operator_jq
  labels_self_check
  tmp=$(mktemp)
  printf 'abc' > "${tmp}"
  verify_sha256 "${tmp}" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  rm -f "${tmp}"
  apply_work_disk_size 60
  [[ "${WORK_DISK_GB}" == "60" ]]
  [[ "${WORK_DISK_BYTES}" -eq 64424509440 ]]
  [[ "${WORK_DISK_PART_MB}" -eq 61440 ]]
  [[ "$(disk_floor_gb 60)" == "35" ]]
  apply_work_disk_size 100
  [[ "${WORK_DISK_GB}" == "100" ]]
  [[ "${WORK_DISK_BYTES}" -eq 107374182400 ]]
  [[ "${WORK_DISK_PART_MB}" -eq 102400 ]]
  [[ "$(disk_floor_gb 100)" == "55" ]]
  if apply_work_disk_size 9; then
    echo "a 9 GiB work disk was accepted" >&2
    exit 1
  fi
  if apply_work_disk_size 513; then
    echo "a 513 GiB work disk was accepted" >&2
    exit 1
  fi
  apply_work_disk_size 512
  [[ "${WORK_DISK_GB}" == "512" ]]
  [[ "${WORK_DISK_BYTES}" -eq 549755813888 ]]
  [[ "${WORK_DISK_PART_MB}" -eq 524288 ]]
  cfg=$(mktemp)
  printf 'AAP_WORK_DISK_GIB=60\nAAP_DISK_FLOOR_GB=35\n' > "${cfg}"
  apply_work_disk_size 100
  stamp_new_manager_conf "${cfg}"
  grep -qx 'AAP_WORK_DISK_GIB=100' "${cfg}"
  grep -qx 'AAP_DISK_FLOOR_GB=55' "${cfg}"
  printf 'AAP_WORK_DISK_GIB=60\nAAP_DISK_FLOOR_GB=60\n' > "${cfg}"
  stamp_new_manager_conf "${cfg}"
  grep -qx 'AAP_WORK_DISK_GIB=100' "${cfg}"
  grep -qx 'AAP_DISK_FLOOR_GB=60' "${cfg}"
  rm -f "${cfg}"
  apply_work_disk_size 60
  cfg=$(mktemp)
  printf 'AAP_RUNNER_BASE_LABEL=crrr\n' > "${cfg}"
  require_runner_base_label "${cfg}"
  printf 'AAP_RUNNER_BASE_LABEL=fresh\n' > "${cfg}"
  require_runner_base_label "${cfg}"
  printf 'AAP_GITHUB_ORG=special-place-ai-heaven\n' > "${cfg}"
  if require_runner_base_label "${cfg}"; then
    echo "a missing base label was accepted" >&2
    exit 1
  fi
  printf 'AAP_RUNNER_BASE_LABEL=\n' > "${cfg}"
  if require_runner_base_label "${cfg}"; then
    echo "an empty base label was accepted" >&2
    exit 1
  fi
  printf 'AAP_RUNNER_BASE_LABEL=heavy\n' > "${cfg}"
  if require_runner_base_label "${cfg}"; then
    echo "base label heavy was accepted" >&2
    exit 1
  fi
  printf 'AAP_RUNNER_BASE_LABEL=CRRR\n' > "${cfg}"
  rc=0
  err=$(require_runner_base_label "${cfg}" 2>&1) || rc=$?
  if [[ "${rc}" -eq 0 ]] || ! charset_refusal "${err}"; then
    echo "base label CRRR was not refused by the charset check" >&2
    printf '%s\n' "${err}" >&2
    exit 1
  fi
  rm -f "${cfg}"
  cfg=$(mktemp)
  printf '[wsl2]\nnetworkingMode=mirrored\n' > "${cfg}"
  wslconfig_sets_mirrored "${cfg}"
  printf '[wsl2]\nnetworkingMode = mirrored # note\n' > "${cfg}"
  wslconfig_sets_mirrored "${cfg}"
  printf '[wsl2]\nnetworkingMode=nat\n' > "${cfg}"
  if wslconfig_sets_mirrored "${cfg}"; then
    echo "nat was treated as mirrored" >&2
    exit 1
  fi
  printf '# networkingMode=mirrored\n' > "${cfg}"
  if wslconfig_sets_mirrored "${cfg}"; then
    echo "a comment was treated as mirrored" >&2
    exit 1
  fi
  rm -f "${cfg}"
  if ! reason=$(networking_stop_reason yes no "" skipped); then
    echo "missing wslinfo inside aap-runner was allowed" >&2
    exit 1
  fi
  if ! reason=$(networking_stop_reason yes yes "" skipped); then
    echo "empty wslinfo inside aap-runner was allowed" >&2
    exit 1
  fi
  if ! reason=$(networking_stop_reason yes yes mirrored skipped); then
    echo "mirrored wslinfo was allowed" >&2
    exit 1
  fi
  if reason=$(networking_stop_reason yes yes nat skipped); then
    echo "nat inside aap-runner was refused: ${reason}" >&2
    exit 1
  fi
  if ! reason=$(networking_stop_reason no no "" unreadable); then
    echo "unreadable .wslconfig was allowed" >&2
    exit 1
  fi
  if ! reason=$(networking_stop_reason no yes nat unreadable); then
    echo "unreadable .wslconfig was allowed beside a nat wslinfo" >&2
    exit 1
  fi
  if reason=$(networking_stop_reason no no "" absent); then
    echo "absent .wslconfig on the operator distro was refused: ${reason}" >&2
    exit 1
  fi
  if valid_operator_sid "S-1-5-18"; then
    echo "SYSTEM was accepted as the mount-task principal" >&2
    exit 1
  fi
  if valid_operator_sid "S-1-5-21-1-2-3-1001</UserId>"; then
    echo "a SID with XML markup was accepted" >&2
    exit 1
  fi
  if ! valid_operator_sid "S-1-5-21-111-222-333-1001"; then
    echo "a user SID was rejected" >&2
    exit 1
  fi
  local task_xml decoded bom sid ps1 count grant_rc live merged
  sid="S-1-5-21-111-222-333-1001"
  ps1='C:\wsl\mount-work-vhdx.ps1'
  if ! task_xml=$(render_mount_task_xml "${sid}" "${ps1}"); then
    echo "task xml render failed" >&2
    exit 1
  fi
  tmp=$(mktemp)
  if ! printf '%s\n' "${task_xml}" | write_utf16_le_bom "${tmp}"; then
    echo "UTF-16 task xml write failed" >&2
    exit 1
  fi
  bom=$(od -An -t x1 -N 2 "${tmp}" | tr -d ' \n')
  if [[ "${bom}" != "fffe" ]]; then
    echo "task xml BOM is ${bom}, expected fffe" >&2
    exit 1
  fi
  decoded=$(iconv -f UTF-16 -t UTF-8 "${tmp}")
  rm -f "${tmp}"
  [[ "${decoded}" == *'encoding="UTF-16"'* ]]
  [[ "${decoded}" == *'<LogonType>InteractiveToken</LogonType>'* ]]
  [[ "${decoded}" == *'<RunLevel>HighestAvailable</RunLevel>'* ]]
  [[ "${decoded}" == *'<LogonTrigger>'* ]]
  [[ "${decoded}" == *"<UserId>${sid}</UserId>"* ]]
  if ! grep -F -q -- "-File \"${ps1}\"" <<< "${decoded}"; then
    echo "rendered task xml is missing the script path" >&2
    exit 1
  fi
  if [[ "${decoded}" == *BootTrigger* || "${decoded}" == *ServiceAccount* || "${decoded}" == *S-1-5-18* ]]; then
    echo "rendered task xml still has a boot trigger or a SYSTEM principal" >&2
    exit 1
  fi
  count=$(printf '%s\n' "${decoded}" | grep -c "<UserId>${sid}</UserId>" || true)
  if [[ "${count}" -ne 2 ]]; then
    echo "expected the operator SID on the trigger and the principal, found ${count}" >&2
    exit 1
  fi
  if [[ "$(< "${SCRIPT_DIR}/mount-work-vhdx.ps1")" != *'C:\wsl\mount-work-vhdx.log'* ]]; then
    echo "mount script does not log under C:\\wsl" >&2
    exit 1
  fi
  grant_rc=0
  sudo_listing_grants "User ghrunner is not allowed to run sudo on CRRR65734." || grant_rc=$?
  if [[ "${grant_rc}" -ne 1 ]]; then
    echo "sudo denial text was not classified as a denial" >&2
    exit 1
  fi
  grant_rc=0
  sudo_listing_grants "User ghrunner may run the following commands on CRRR65734:" || grant_rc=$?
  if [[ "${grant_rc}" -ne 0 ]]; then
    echo "sudo grant text was not classified as a grant" >&2
    exit 1
  fi
  grant_rc=0
  sudo_listing_grants "sudo: a password is required" || grant_rc=$?
  if [[ "${grant_rc}" -ne 2 ]]; then
    echo "an unreadable sudo listing was classified" >&2
    exit 1
  fi
  if live=$(sudo -n -l -U nobody 2>&1); then
    grant_rc=0
    sudo_listing_grants "${live}" || grant_rc=$?
    if [[ "${grant_rc}" -ne 1 ]]; then
      echo "live sudo denial for nobody was not a denial" >&2
      printf '%s\n' "${live}" >&2
      exit 1
    fi
  fi
  if live=$(sudo -n -l -U root 2>&1); then
    grant_rc=0
    sudo_listing_grants "${live}" || grant_rc=$?
    if [[ "${grant_rc}" -ne 0 ]]; then
      echo "live sudo listing for root was not a grant" >&2
      printf '%s\n' "${live}" >&2
      exit 1
    fi
  fi
  if grep -q 'sudo -n -l -U runner >/dev/null' "${SCRIPT_DIR}/Dockerfile"; then
    echo "Dockerfile still treats sudo -l exit status as the check" >&2
    exit 1
  fi
  if ! grep -q 'may run the following' "${SCRIPT_DIR}/Dockerfile"; then
    echo "Dockerfile does not parse the sudo grant sentence" >&2
    exit 1
  fi
  tmp=$(mktemp -d)
  printf '%s\n' '{"runtimes":{"sysbox-runc":{"path":"/usr/bin/sysbox-runc"}},"ipv6":true,"data-root":"/var/lib/docker"}' > "${tmp}/live.json"
  merged=$(jq -c -s '.[0] * .[1]' "${tmp}/live.json" "${SCRIPT_DIR}/daemon.json")
  if ! printf '%s\n' "${merged}" | jq -e '.runtimes["sysbox-runc"].path == "/usr/bin/sysbox-runc" and .["data-root"] == "/var/lib/ghrunner/docker" and .ipv6 == false' >/dev/null; then
    echo "daemon.json merge dropped sysbox-runc or missed data-root" >&2
    printf '%s\n' "${merged}" >&2
    exit 1
  fi
  rm -rf "${tmp}"
  rc=0
  err=$(run_checked "wsl.exe --exec simulated" false 2>&1) || rc=$?
  if [[ "${rc}" -eq 0 || "${err}" != *"refusing: wsl.exe --exec simulated failed"* ]]; then
    echo "a simulated wsl.exe failure was accepted" >&2
    printf '%s\n' "${err}" >&2
    exit 1
  fi
  body=$(declare -f outside)
  [[ "${body}" == *'--exec'* ]]
  [[ "${body}" == *'stage-into-distro.sh'* ]]
  [[ "${body}" == *'set -euo pipefail'* ]]
  if [[ "${body}" == *'bash -lc'* || "${body}" == *'AAP_STAGE_BOOT'* ]]; then
    echo "outside() still re-parses the stage path through a shell" >&2
    exit 1
  fi
  msg=$(half_install_refusal)
  [[ "${msg}" == *"wsl --unregister ${DISTRO}"* ]]
  [[ "${msg}" != *Ubuntu* && "${msg}" != *docker-desktop* ]]
  nulled=$(printf 'a\0l\0r\0e\0a\0d\0y' | tr -d '\000')
  if ! mount_text_is_already "${nulled}"; then
    echo "UTF-16 'already' was not recognized after NUL stripping" >&2
    exit 1
  fi
  if mount_text_is_already "The requested operation requires elevation."; then
    echo "an elevation error was treated as already mounted" >&2
    exit 1
  fi
  if ! gap=$(install_gaps no inactive inactive 1 1); then
    echo "a failed install was treated as complete" >&2
    exit 1
  fi
  [[ "${gap}" == *"/opt/aap-runner/bootstrap.sh"* ]]
  [[ "${gap}" == *"docker"* && "${gap}" == *"sysbox"* ]]
  [[ "${gap}" == *"AAP-CRRR-Mount-Work-Disk"* ]]
  [[ "${gap}" == *"aap-crrr-runner:local"* ]]
  if install_gaps yes active active 0 0; then
    echo "a complete install was treated as incomplete" >&2
    exit 1
  fi
  if ! vhdx_windows_path_ok 'C:\wsl\aap-runner-work.vhdx'; then
    echo "C:\\wsl\\aap-runner-work.vhdx was refused" >&2
    exit 1
  fi
  if ! vhdx_windows_path_ok 'C:\wsl\my disk.vhdx'; then
    echo "a VHDX path with a space was refused" >&2
    exit 1
  fi
  if vhdx_windows_path_ok 'C:/wsl/foo.vhdx' \
    || vhdx_windows_path_ok '\\server\share\foo.vhdx' \
    || vhdx_windows_path_ok 'C:\wsl\foo.txt' \
    || vhdx_windows_path_ok 'C:\wsl\foo.vhdx.exe' \
    || vhdx_windows_path_ok 'C:\wsl\foo&bar.vhdx'; then
    echo "a non-drive-letter or non-.vhdx path was accepted" >&2
    exit 1
  fi
  if [[ "$(retired_task_action 0)" != delete ]]; then
    echo "an existing retired task was not selected for delete" >&2
    exit 1
  fi
  if [[ "$(retired_task_action 1)" != skip ]]; then
    echo "a missing retired task was selected for delete" >&2
    exit 1
  fi
  body=$(declare -f delete_retired_mount_task)
  if [[ "${body}" == *"cannot find"* || "${body}" == *"does not exist"* ]]; then
    echo "retired-task delete still matches English text" >&2
    exit 1
  fi
  if [[ "${body}" != *'/Query'* || "${body%%/Delete*}" != *'/Query'* ]]; then
    echo "retired-task delete does not query before it deletes" >&2
    exit 1
  fi
  body=$(declare -f ensure_work_vhdx)
  if [[ "${body%%vhdx_windows_path_ok*}" != *lock_created_windows_dir* ]]; then
    echo "C:\\wsl is not locked before the VHDX path is checked" >&2
    exit 1
  fi
  if [[ "${body%%create-work-vhdx.ps1*}" != *vhdx_windows_path_ok* ]]; then
    echo "the VHDX is created before its path is checked" >&2
    exit 1
  fi
  body=$(declare -f outside)
  if [[ "${body}" != *'lock_created_windows_dir "$(dirname "${INSTALL_MARKER}")"'* ]]; then
    echo "the install marker is written before C:\\wsl is locked" >&2
    exit 1
  fi
  body=$(declare -f register_mount_task)
  if [[ "${body%%mount-work-vhdx.ps1*}" != *lock_created_windows_dir* ]]; then
    echo "the logon script is written before C:\\wsl is locked" >&2
    exit 1
  fi
  vhdx_ps1=$(< "${SCRIPT_DIR}/create-work-vhdx.ps1")
  if [[ "${vhdx_ps1}" == *'$env:TEMP'* ]]; then
    echo "create-work-vhdx.ps1 writes the diskpart script under TEMP" >&2
    exit 1
  fi
  if [[ "${vhdx_ps1}" != *"Join-Path \$dir 'aap-runner-diskpart.txt'"* \
    || "${vhdx_ps1}" != *'Remove-Item -LiteralPath $dp'* ]]; then
    echo "the diskpart script is not written beside the VHDX and deleted" >&2
    exit 1
  fi
  if [[ "${vhdx_ps1}" != *'^[A-Za-z]:\\[A-Za-z0-9 _.\\-]+\.vhdx$'* ]]; then
    echo "create-work-vhdx.ps1 does not refuse a bad -Path" >&2
    exit 1
  fi
  path_line=$(grep -n -- '-notmatch' "${SCRIPT_DIR}/create-work-vhdx.ps1" | head -1 | cut -d: -f1)
  lock_line=$(grep -n -- '& $lock -LiteralPath $dir' "${SCRIPT_DIR}/create-work-vhdx.ps1" | head -1 | cut -d: -f1)
  new_line=$(grep -n -- 'New-VHD -Path' "${SCRIPT_DIR}/create-work-vhdx.ps1" | head -1 | cut -d: -f1)
  dp_line=$(grep -n -- 'aap-runner-diskpart.txt' "${SCRIPT_DIR}/create-work-vhdx.ps1" | head -1 | cut -d: -f1)
  if [[ -z "${path_line}" || -z "${lock_line}" || -z "${new_line}" || -z "${dp_line}" \
    || "${path_line}" -ge "${lock_line}" || "${lock_line}" -ge "${new_line}" \
    || "${new_line}" -ge "${dp_line}" ]]; then
    echo "create-work-vhdx.ps1 does not check the path, lock the directory, then create the VHDX" >&2
    exit 1
  fi
  readme=$(< "${SCRIPT_DIR}/README.md")
  if [[ "${readme}" != *'AAP_RUNNERS_READ_TOKEN="$(cat ~/.aap-runners-token)" bash evidence-host.sh'* ]]; then
    echo "README does not document the one-shot runners token" >&2
    exit 1
  fi
  if [[ "${readme}" == *'export AAP_RUNNERS_READ_TOKEN'* ]]; then
    echo "README exports the runners token" >&2
    exit 1
  fi
  if [[ "${readme}" != *'chmod 600 ~/.aap-runners-token'* ]]; then
    echo "README does not require mode 600 on the token file" >&2
    exit 1
  fi
  bash "${SCRIPT_DIR}/stage-into-distro.sh" --self-check
  bash "${SCRIPT_DIR}/mount-work-disk.sh" --self-check
  echo "checksum self-check ok"
}

outside() {
  local win_install win_tar
  set -euo pipefail
  require_operator_jq
  if [[ "${WSL_DISTRO_NAME:-}" == "${DISTRO}" ]]; then
    echo "run bootstrap from the operator distro, not from ${DISTRO}" >&2
    exit 1
  fi
  if ! command -v wsl.exe >/dev/null 2>&1; then
    echo "wsl.exe is required; run this inside the existing WSL distro" >&2
    exit 1
  fi
  if [[ ! -d /mnt/c ]]; then
    echo "/mnt/c is not mounted; this step has to run before aap-runner is locked down" >&2
    exit 1
  fi
  refuse_mirrored_networking
  ensure_work_vhdx
  attach_work_vhdx
  if distro_exists; then
    half_install_refusal >&2
    exit 1
  fi
  if [[ -f "${INSTALL_MARKER}" ]]; then
    rm -f "${INSTALL_MARKER}"
  fi

  local work
  work=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '${work}' '${STAGE}'" EXIT
  download "${UBUNTU_URL}" "${work}/${UBUNTU_NAME}" "${UBUNTU_SHA256}"
  download "${SYSBOX_URL}" "${work}/${SYSBOX_NAME}" "${SYSBOX_SHA256}"
  download "${RUNNER_URL}" "${work}/${RUNNER_NAME}" "${RUNNER_SHA256}"

  mkdir -p "${INSTALL_DIR}"
  # C:\wsl is locked before the install marker is written.
  lock_created_windows_dir "$(dirname "${INSTALL_MARKER}")"
  printf '%s\n' "${DISTRO}" > "${INSTALL_MARKER}"
  win_install=$(wslpath -w "${INSTALL_DIR}")
  win_tar=$(wslpath -w "${work}/${UBUNTU_NAME}")
  run_checked "wsl.exe --import ${DISTRO}" \
    wsl.exe --import "${DISTRO}" "${win_install}" "${win_tar}" --version 2

  rm -rf "${STAGE}"
  mkdir -p "${STAGE}"
  cp "${work}/${UBUNTU_NAME}" "${work}/${SYSBOX_NAME}" "${work}/${RUNNER_NAME}" "${STAGE}/"
  cp "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}/ephemeral-entry.sh" "${SCRIPT_DIR}/manager.sh" \
    "${SCRIPT_DIR}/mount-work-disk.sh" "${SCRIPT_DIR}/aap-workdisk.service" \
    "${SCRIPT_DIR}/daemon.json" "${SCRIPT_DIR}/docker-workdisk.conf" \
    "${SCRIPT_DIR}/aap-runner-manager.service" "${SCRIPT_DIR}/nftables.conf" \
    "${SCRIPT_DIR}/wsl.conf" "${SCRIPT_DIR}/manager.conf.example" \
    "${SCRIPT_DIR}/evidence.sh" "${SCRIPT_DIR}/bootstrap.sh" \
    "${SCRIPT_DIR}/labels.sh" "${SCRIPT_DIR}/stage-into-distro.sh" "${STAGE}/"

  # --exec does not join the command into the distro shell. The stage path
  # and the disk size are positional arguments of stage-into-distro.sh.
  run_checked "wsl.exe --exec stage-into-distro.sh" \
    wsl.exe -d "${DISTRO}" -u root --exec /bin/bash \
    "${STAGE}/stage-into-distro.sh" "${STAGE}" "${WORK_DISK_GB}"
  rm -rf "${STAGE}"

  register_mount_task

  run_checked "wsl.exe --terminate ${DISTRO}" \
    wsl.exe --terminate "${DISTRO}"
  run_checked "wsl.exe --exec bootstrap.sh --inside-runtime" \
    wsl.exe -d "${DISTRO}" -u root --exec /bin/bash \
    /opt/aap-runner/bootstrap.sh --inside-runtime
  verify_install
}

# Echoes what is still missing. Returns 1 when every check passed.
install_gaps() {
  local bootstrap="$1" docker_state="$2" sysbox_state="$3" task_rc="$4" image_rc="$5"
  local gap=""
  [[ "${bootstrap}" == yes ]] || gap="${gap} missing /opt/aap-runner/bootstrap.sh."
  [[ "${docker_state}" == active ]] || gap="${gap} docker is ${docker_state:-missing}."
  [[ "${sysbox_state}" == active ]] || gap="${gap} sysbox is ${sysbox_state:-missing}."
  [[ "${task_rc}" -eq 0 ]] || gap="${gap} task AAP-CRRR-Mount-Work-Disk is not registered."
  [[ "${image_rc}" -eq 0 ]] || gap="${gap} image aap-crrr-runner:local is not built."
  if [[ -n "${gap}" ]]; then
    printf '%s\n' "${gap# }"
    return 0
  fi
  return 1
}

verify_inside() {
  local bootstrap=no docker_state sysbox_state image_rc=0 gap
  if [[ -f /opt/aap-runner/bootstrap.sh ]]; then
    bootstrap=yes
  fi
  docker_state=$(systemctl is-active docker 2>/dev/null || true)
  if systemctl is-active --quiet sysbox || systemctl is-active --quiet sysbox-mgr; then
    sysbox_state=active
  else
    sysbox_state=$(systemctl is-active sysbox 2>/dev/null || systemctl is-active sysbox-mgr 2>/dev/null || true)
  fi
  docker image inspect aap-crrr-runner:local >/dev/null 2>&1 || image_rc=$?
  if gap=$(install_gaps "${bootstrap}" "${docker_state}" "${sysbox_state}" 0 "${image_rc}"); then
    echo "refusing: ${gap}" >&2
    exit 1
  fi
}

verify_install() {
  local task_rc=0
  run_checked "wsl.exe --exec bootstrap.sh --verify-install" \
    wsl.exe -d "${DISTRO}" -u root --exec /bin/bash \
    /opt/aap-runner/bootstrap.sh --verify-install
  schtasks.exe /Query /TN AAP-CRRR-Mount-Work-Disk >/dev/null || task_rc=$?
  if [[ "${task_rc}" -ne 0 ]]; then
    echo "refusing: schtasks.exe /Query /TN AAP-CRRR-Mount-Work-Disk failed (exit ${task_rc})" >&2
    exit 1
  fi
}

ensure_work_vhdx() {
  local avail bytes win dir
  dir=$(dirname "${WORK_VHDX}")
  lock_created_windows_dir "${dir}"
  win=$(wslpath -w "${WORK_VHDX}")
  if ! vhdx_windows_path_ok "${win}"; then
    echo "refusing: ${win} must match ^[A-Za-z]:\\\\[A-Za-z0-9 _.\\\\-]+\\.vhdx$" >&2
    exit 1
  fi
  if [[ -f "${WORK_VHDX}" ]]; then
    bytes=$(stat -c '%s' "${WORK_VHDX}")
    if [[ "${bytes}" -lt "${WORK_DISK_BYTES}" ]]; then
      echo "refusing: ${WORK_VHDX} is ${bytes} bytes, not a ${WORK_DISK_GB}GiB fixed VHDX" >&2
      exit 1
    fi
    lock_work_disk_acl
    return 0
  fi
  avail=$(avail_gb /mnt/c)
  if [[ "${avail}" -lt "${WORK_DISK_GB}" ]]; then
    echo "refusing: ${avail}G free on C:; creating the fixed work disk needs ${WORK_DISK_GB}G" >&2
    exit 1
  fi
  if ! powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$(wslpath -w "${SCRIPT_DIR}/create-work-vhdx.ps1")" \
    -Path "${win}" -SizeGiB "${WORK_DISK_GB}"; then
    echo "failed to create ${win}. Run bootstrap from an elevated shell." >&2
    exit 1
  fi
  lock_work_disk_acl
}

attach_work_vhdx() {
  local win err rc=0
  win=$(wslpath -w "${WORK_VHDX}")
  # Strip NULs in the pipe. A bash variable truncates at the first NUL,
  # which hides the word "already" in UTF-16 wsl.exe output.
  err=$(wsl.exe --mount --vhd "${win}" --bare 2>&1 | tr -d '\000') || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    return 0
  fi
  if mount_text_is_already "${err}"; then
    return 0
  fi
  printf '%s\n' "${err}" >&2
  echo "refusing: wsl.exe --mount --bare failed (exit ${rc}). Run bootstrap from an elevated shell." >&2
  exit 1
}

# A Windows account SID. SYSTEM (S-1-5-18) and other well-known service
# SIDs do not match: wsl --mount as those accounts attaches a different VM.
valid_operator_sid() {
  [[ "$1" =~ ^S-1-5-21-[0-9]+-[0-9]+-[0-9]+-[0-9]+$ ]]
}

installing_operator_sid() {
  local line sid="" text rc=0
  if ! command -v powershell.exe >/dev/null 2>&1; then
    echo "refusing: powershell.exe is required to resolve the operator SID" >&2
    return 1
  fi
  text=$(powershell.exe -NoProfile -NonInteractive -Command '[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value' | tr -d '\000\r') || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "refusing: powershell.exe could not resolve the operator SID (exit ${rc})" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line=${line// /}
    if valid_operator_sid "${line}"; then
      sid="${line}"
    fi
  done <<< "${text}"
  if [[ -z "${sid}" ]]; then
    echo "refusing: could not resolve the installing operator SID" >&2
    return 1
  fi
  printf '%s\n' "${sid}"
}

# schtasks /XML reads the file as UTF-16. A UTF-8 document fails at (1,2).
# GNU iconv's UTF-16 charset writes the byte-order mark; this host is LE.
write_utf16_le_bom() {
  local dest="$1" tmp bom
  tmp=$(mktemp)
  cat > "${tmp}"
  if ! iconv -f UTF-8 -t UTF-16 "${tmp}" > "${dest}"; then
    rm -f "${tmp}"
    echo "refusing: iconv could not encode ${dest} as UTF-16" >&2
    return 1
  fi
  rm -f "${tmp}"
  bom=$(od -An -t x1 -N 2 "${dest}" | tr -d ' \n')
  if [[ "${bom}" != "fffe" ]]; then
    echo "refusing: ${dest} is not UTF-16 LE (BOM ${bom:-empty}, expected fffe)" >&2
    return 1
  fi
}

render_mount_task_xml() {
  local sid="$1" ps1_win="$2" xml
  if ! valid_operator_sid "${sid}"; then
    echo "refusing: operator SID '${sid}' is not a user account SID" >&2
    return 1
  fi
  if [[ "${ps1_win}" == *'<'* || "${ps1_win}" == *'>'* || "${ps1_win}" == *'&'* || "${ps1_win}" == *'"'* ]]; then
    echo "refusing: task script path cannot be placed in the task xml" >&2
    return 1
  fi
  xml=$(< "${SCRIPT_DIR}/mount-work-vhdx-task.xml")
  if [[ "${xml}" != *'encoding="UTF-16"'* || "${xml}" != *'InteractiveToken'* || "${xml}" != *'LogonTrigger'* ]]; then
    echo "refusing: task xml template is missing the operator logon principal" >&2
    return 1
  fi
  if [[ "${xml}" == *BootTrigger* || "${xml}" == *ServiceAccount* || "${xml}" == *S-1-5-18* ]]; then
    echo "refusing: task xml template still targets SYSTEM or boot" >&2
    return 1
  fi
  xml=${xml//__AAP_USER_SID__/${sid}}
  xml=${xml//__AAP_PS1__/${ps1_win}}
  if [[ "${xml}" == *__AAP_* ]]; then
    echo "refusing: task xml still has an unsubstituted placeholder" >&2
    return 1
  fi
  printf '%s\n' "${xml}"
}

register_mount_task() {
  local ps1_win vhdx_win xml_dest xml ps1_body sid rc
  local task_dir
  task_dir=$(dirname "${WORK_VHDX}")
  # Lock the folder before the logon script or the task xml is written.
  lock_created_windows_dir "${task_dir}"
  vhdx_win=$(wslpath -w "${WORK_VHDX}")
  ps1_body=$(< "${SCRIPT_DIR}/mount-work-vhdx.ps1")
  ps1_body=${ps1_body//__AAP_VHDX__/${vhdx_win}}
  ps1_win=$(wslpath -w "${task_dir}/mount-work-vhdx.ps1")
  printf '%s\n' "${ps1_body}" > "${task_dir}/mount-work-vhdx.ps1"
  if ! sid=$(installing_operator_sid); then
    exit 1
  fi
  if ! xml=$(render_mount_task_xml "${sid}" "${ps1_win}"); then
    exit 1
  fi
  xml_dest="${task_dir}/mount-work-vhdx-task.xml"
  if ! printf '%s\n' "${xml}" | write_utf16_le_bom "${xml_dest}"; then
    exit 1
  fi
  echo "registering AAP-CRRR-Mount-Work-Disk for operator ${sid} (logon, InteractiveToken, HighestAvailable)"
  # Folder, script, task xml, and VHDX: SYSTEM and Administrators only.
  # The task runs as the operator with HighestAvailable, so the
  # Administrators ACE covers it. The operator SID is not its own ACE.
  lock_windows_admin_only "$(wslpath -w "${task_dir}")"
  lock_windows_admin_only "${ps1_win}"
  lock_windows_admin_only "$(wslpath -w "${xml_dest}")"
  lock_windows_admin_only "$(wslpath -w "${WORK_VHDX}")"
  delete_retired_mount_task
  rc=0
  schtasks.exe /Create /TN AAP-CRRR-Mount-Work-Disk /XML "$(wslpath -w "${xml_dest}")" /F || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "refusing: schtasks.exe /Create /TN AAP-CRRR-Mount-Work-Disk failed (exit ${rc})." >&2
    echo "Run bootstrap from an elevated shell. Install stopped." >&2
    exit 1
  fi
}

# Query exit 0 means the retired task exists. Any other status means it does
# not. The wording of the query is not part of the decision.
retired_task_action() {
  if [[ "$1" -eq 0 ]]; then
    printf '%s\n' delete
  else
    printf '%s\n' skip
  fi
}

delete_retired_mount_task() {
  local query_rc=0 action
  schtasks.exe /Query /TN AAP-CRRR-C-Free-GB >/dev/null 2>&1 || query_rc=$?
  action=$(retired_task_action "${query_rc}")
  if [[ "${action}" == skip ]]; then
    return 0
  fi
  run_checked "schtasks.exe /Delete /TN AAP-CRRR-C-Free-GB" \
    schtasks.exe /Delete /TN AAP-CRRR-C-Free-GB /F
}

case "${1:-}" in
  --self-check) self_check ;;
  --inside-packages) inside_packages ;;
  --inside-runtime) inside_runtime ;;
  --verify-install) verify_inside ;;
  "") outside ;;
  *)
    echo "usage: bootstrap.sh [--self-check]" >&2
    exit 1
    ;;
esac
