#!/bin/bash
# Import the aap-runner WSL distro and install Docker Engine + Sysbox.
# Run from the operator's existing WSL distro (interop still on).
# A Sysbox failure stops the install. There is no privileged fallback
# and no host docker socket mount.
set -euo pipefail

DISTRO=aap-runner
INSTALL_DIR=${AAP_RUNNER_INSTALL_DIR:-/mnt/c/aap-runner}
STAGE=${AAP_RUNNER_STAGE:-/mnt/c/aap-runner-staging}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# 60 GiB fixed. diskpart maximum= is MiB; 60*1024=61440. PowerShell 60GB matches.
WORK_VHDX=${AAP_WORK_VHDX:-/mnt/c/wsl/aap-runner-work.vhdx}
WORK_DISK_GB=60
WORK_DISK_BYTES=64424509440
WORK_DISK_PART_MB=61440

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

distro_exists() {
  wsl.exe -l -q | tr -d '\000\r' | grep -qx "${DISTRO}"
}

copy_staged() {
  local name="$1" dest="$2"
  cp "${STAGE}/${name}" "${dest}"
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
  copy_staged evidence.sh /usr/local/sbin/aap-runner-evidence
  copy_staged mount-work-disk.sh /usr/local/sbin/aap-mount-work-disk
  copy_staged aap-runner-manager.service /etc/systemd/system/aap-runner-manager.service
  copy_staged aap-workdisk.service /etc/systemd/system/aap-workdisk.service
  install -d -m 755 /etc/docker /etc/systemd/system/docker.service.d
  copy_staged daemon.json /etc/docker/daemon.json
  copy_staged docker-workdisk.conf /etc/systemd/system/docker.service.d/workdisk.conf
  copy_staged nftables.conf /etc/aap-runner/nftables.conf
  copy_staged wsl.conf /etc/wsl.conf
  if [[ ! -f /etc/aap-runner/manager.conf ]]; then
    copy_staged manager.conf.example /etc/aap-runner/manager.conf
  fi
  chmod 755 /usr/local/sbin/aap-runner-manager /usr/local/sbin/aap-runner-evidence \
    /usr/local/sbin/aap-mount-work-disk \
    /var/lib/aap-runner/image/ephemeral-entry.sh
  chmod 644 /etc/docker/daemon.json /etc/systemd/system/docker.service.d/workdisk.conf \
    /etc/systemd/system/aap-workdisk.service
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

inside_runtime() {
  local state rootdir
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
  /usr/local/sbin/aap-mount-work-disk

  apt-get install -y "/var/lib/aap-runner/${SYSBOX_NAME}"
  systemctl stop sysbox sysbox-mgr sysbox-fs >/dev/null 2>&1 || true
  /usr/local/sbin/aap-mount-work-disk
  if systemctl cat sysbox.service >/dev/null 2>&1; then
    systemctl enable --now sysbox
  else
    systemctl enable --now sysbox-mgr
    systemctl enable --now sysbox-fs
  fi
  systemctl enable --now docker
  systemctl restart docker
  rootdir=$(docker info -f '{{.DockerRootDir}}')
  if [[ "${rootdir}" != "/var/lib/ghrunner/docker" ]]; then
    echo "dockerd data-root is ${rootdir}; expected /var/lib/ghrunner/docker" >&2
    exit 1
  fi
  assert_dockerd_ipv6_off

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
  if sudo -n -l -U ghrunner >/dev/null 2>&1; then
    echo "ghrunner has sudo rights" >&2
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
  local raw="" profile="" cfg="" reason="" grep_rc=0
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
      raw=$(powershell.exe -NoProfile -NonInteractive -Command '[Environment]::GetFolderPath("UserProfile")' | tr -d '\r' || true)
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

self_check() {
  local tmp cfg reason
  tmp=$(mktemp)
  printf 'abc' > "${tmp}"
  verify_sha256 "${tmp}" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  rm -f "${tmp}"
  [[ "${WORK_DISK_BYTES}" -eq $((WORK_DISK_GB * 1024 * 1024 * 1024)) ]]
  [[ "${WORK_DISK_PART_MB}" -eq $((WORK_DISK_GB * 1024)) ]]
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
  echo "checksum self-check ok"
}

outside() {
  local win_install win_tar
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
    echo "distro ${DISTRO} already exists; wsl --unregister ${DISTRO} yourself before re-running" >&2
    exit 1
  fi

  local work
  work=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '${work}' '${STAGE}'" EXIT
  download "${UBUNTU_URL}" "${work}/${UBUNTU_NAME}" "${UBUNTU_SHA256}"
  download "${SYSBOX_URL}" "${work}/${SYSBOX_NAME}" "${SYSBOX_SHA256}"
  download "${RUNNER_URL}" "${work}/${RUNNER_NAME}" "${RUNNER_SHA256}"

  mkdir -p "${INSTALL_DIR}"
  win_install=$(wslpath -w "${INSTALL_DIR}")
  win_tar=$(wslpath -w "${work}/${UBUNTU_NAME}")
  wsl.exe --import "${DISTRO}" "${win_install}" "${win_tar}" --version 2

  rm -rf "${STAGE}"
  mkdir -p "${STAGE}"
  cp "${work}/${UBUNTU_NAME}" "${work}/${SYSBOX_NAME}" "${work}/${RUNNER_NAME}" "${STAGE}/"
  cp "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}/ephemeral-entry.sh" "${SCRIPT_DIR}/manager.sh" \
    "${SCRIPT_DIR}/mount-work-disk.sh" "${SCRIPT_DIR}/aap-workdisk.service" \
    "${SCRIPT_DIR}/daemon.json" "${SCRIPT_DIR}/docker-workdisk.conf" \
    "${SCRIPT_DIR}/aap-runner-manager.service" "${SCRIPT_DIR}/nftables.conf" \
    "${SCRIPT_DIR}/wsl.conf" "${SCRIPT_DIR}/manager.conf.example" \
    "${SCRIPT_DIR}/evidence.sh" "${SCRIPT_DIR}/bootstrap.sh" "${STAGE}/"

  wsl.exe -d "${DISTRO}" -u root -- env "AAP_STAGE_BOOT=${STAGE}/bootstrap.sh" \
    bash -lc "mkdir -p /opt/aap-runner && cp \"\$AAP_STAGE_BOOT\" /opt/aap-runner/bootstrap.sh && bash /opt/aap-runner/bootstrap.sh --inside-packages"
  rm -rf "${STAGE}"

  register_mount_task

  wsl.exe --terminate "${DISTRO}"
  wsl.exe -d "${DISTRO}" -u root -- bash /opt/aap-runner/bootstrap.sh --inside-runtime
}

ensure_work_vhdx() {
  local avail bytes win
  win=$(wslpath -w "${WORK_VHDX}")
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
  local win err
  win=$(wslpath -w "${WORK_VHDX}")
  if err=$(wsl.exe --mount --vhd "${win}" --bare 2>&1); then
    return 0
  fi
  if [[ "${err}" == *[Aa]lready* ]]; then
    return 0
  fi
  printf '%s\n' "${err}" >&2
  echo "wsl --mount --bare failed. Run bootstrap from an elevated shell." >&2
  exit 1
}

register_mount_task() {
  local ps1_win vhdx_win xml_dest xml ps1_body
  local task_dir
  task_dir=$(dirname "${WORK_VHDX}")
  mkdir -p "${task_dir}"
  vhdx_win=$(wslpath -w "${WORK_VHDX}")
  ps1_body=$(< "${SCRIPT_DIR}/mount-work-vhdx.ps1")
  ps1_body=${ps1_body//__AAP_VHDX__/${vhdx_win}}
  ps1_win=$(wslpath -w "${task_dir}/mount-work-vhdx.ps1")
  printf '%s\n' "${ps1_body}" > "${task_dir}/mount-work-vhdx.ps1"
  xml=$(< "${SCRIPT_DIR}/mount-work-vhdx-task.xml")
  xml=${xml//__AAP_PS1__/${ps1_win}}
  xml_dest="${task_dir}/mount-work-vhdx-task.xml"
  printf '%s\n' "${xml}" > "${xml_dest}"
  # Folder, boot script, task xml, and VHDX: SYSTEM and Administrators only.
  lock_windows_admin_only "$(wslpath -w "${task_dir}")"
  lock_windows_admin_only "${ps1_win}"
  lock_windows_admin_only "$(wslpath -w "${xml_dest}")"
  lock_windows_admin_only "$(wslpath -w "${WORK_VHDX}")"
  schtasks.exe /Delete /TN AAP-CRRR-C-Free-GB /F >/dev/null 2>&1 || true
  if ! schtasks.exe /Create /TN AAP-CRRR-Mount-Work-Disk /XML "$(wslpath -w "${xml_dest}")" /F; then
    echo "failed to register scheduled task AAP-CRRR-Mount-Work-Disk as SYSTEM." >&2
    echo "Run bootstrap from an elevated shell. Install stopped." >&2
    exit 1
  fi
}

case "${1:-}" in
  --self-check) self_check ;;
  --inside-packages) inside_packages ;;
  --inside-runtime) inside_runtime ;;
  "") outside ;;
  *)
    echo "usage: bootstrap.sh [--self-check]" >&2
    exit 1
    ;;
esac
