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
# df of / inside aap-runner is the 1 TB VHD and is not a free-space reading.
avail_gb() {
  df -BG --output=avail "$1" | awk 'NR==2 { gsub(/G/, "", $1); print $1 }'
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
  copy_staged record-c-free-gb.sh /usr/local/sbin/aap-record-c-free-gb
  copy_staged aap-runner-manager.service /etc/systemd/system/aap-runner-manager.service
  copy_staged nftables.conf /etc/aap-runner/nftables.conf
  copy_staged wsl.conf /etc/wsl.conf
  if [[ ! -f /etc/aap-runner/manager.conf ]]; then
    copy_staged manager.conf.example /etc/aap-runner/manager.conf
  fi
  chmod 755 /usr/local/sbin/aap-runner-manager /usr/local/sbin/aap-record-c-free-gb \
    /var/lib/aap-runner/image/ephemeral-entry.sh
  chmod 400 /etc/aap-runner/manager.conf
  chown root:root /etc/aap-runner/manager.conf /usr/local/sbin/aap-runner-manager

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
  local state
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

  apt-get install -y "/var/lib/aap-runner/${SYSBOX_NAME}"
  if systemctl cat sysbox.service >/dev/null 2>&1; then
    systemctl enable --now sysbox
  else
    systemctl enable --now sysbox-mgr
    systemctl enable --now sysbox-fs
  fi
  systemctl enable --now docker
  systemctl restart docker

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

self_check() {
  local tmp
  tmp=$(mktemp)
  printf 'abc' > "${tmp}"
  verify_sha256 "${tmp}" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  rm -f "${tmp}"
  echo "checksum self-check ok"
}

outside() {
  local avail win_install win_tar
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
  avail=$(avail_gb /mnt/c)
  if [[ "${avail}" -lt 40 ]]; then
    echo "refusing import: ${avail}G free on C:; floor is 40G" >&2
    exit 1
  fi
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
    "${SCRIPT_DIR}/record-c-free-gb.sh" \
    "${SCRIPT_DIR}/aap-runner-manager.service" "${SCRIPT_DIR}/nftables.conf" \
    "${SCRIPT_DIR}/wsl.conf" "${SCRIPT_DIR}/manager.conf.example" \
    "${SCRIPT_DIR}/bootstrap.sh" "${STAGE}/"

  wsl.exe -d "${DISTRO}" -u root -- env "AAP_STAGE_BOOT=${STAGE}/bootstrap.sh" \
    bash -lc "mkdir -p /opt/aap-runner && cp \"\$AAP_STAGE_BOOT\" /opt/aap-runner/bootstrap.sh && bash /opt/aap-runner/bootstrap.sh --inside-packages"
  rm -rf "${STAGE}"

  register_c_free_task

  wsl.exe --terminate "${DISTRO}"
  wsl.exe -d "${DISTRO}" -u root -- bash /opt/aap-runner/bootstrap.sh --inside-runtime
  prove_c_free_task
}

register_c_free_task() {
  local ps1_win xml_dest xml
  cp "${SCRIPT_DIR}/c-free-gb.ps1" "${INSTALL_DIR}/c-free-gb.ps1"
  ps1_win=$(wslpath -w "${INSTALL_DIR}/c-free-gb.ps1")
  xml=$(< "${SCRIPT_DIR}/c-free-gb-task.xml")
  xml=${xml//__AAP_PS1__/${ps1_win}}
  xml_dest="${INSTALL_DIR}/c-free-gb-task.xml"
  printf '%s\n' "${xml}" > "${xml_dest}"
  icacls.exe "${ps1_win}" /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F'
  if ! schtasks.exe /Create /TN AAP-CRRR-C-Free-GB /XML "$(wslpath -w "${xml_dest}")" /F; then
    echo "failed to register scheduled task AAP-CRRR-C-Free-GB as SYSTEM." >&2
    echo "Run bootstrap from an elevated shell. Install stopped." >&2
    exit 1
  fi
}

prove_c_free_task() {
  local line=""
  schtasks.exe /Run /TN AAP-CRRR-C-Free-GB
  for _ in $(seq 1 15); do
    if line=$(wsl.exe -d "${DISTRO}" -u root -- cat /run/aap-runner/c-free-gb 2>/dev/null); then
      line=$(printf '%s' "${line}" | tr -d '\r')
      if [[ "${line}" =~ ^[0-9]+\ [0-9]+$ ]]; then
        echo "C: free-space task wrote: ${line}"
        return 0
      fi
    fi
    sleep 2
  done
  echo "scheduled task did not write /run/aap-runner/c-free-gb. Install stopped." >&2
  exit 1
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
