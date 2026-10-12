#!/bin/bash
# Capture wsl --version and the Windows user's .wslconfig, then run evidence
# inside aap-runner. That distro has automount off, so it cannot read the
# Windows profile or launch wsl.exe. Run this from the operator distro.
set -euo pipefail

DISTRO=${AAP_RUNNER_DISTRO:-aap-runner}

classify_wslconfig() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    printf '%s\n' absent
    return 0
  fi
  if [[ -f "${path}" && -r "${path}" ]]; then
    printf '%s\n' present
    return 0
  fi
  printf '%s\n' unreadable
  return 1
}

windows_profile_wslconfig() {
  local raw profile
  raw=$(powershell.exe -NoProfile -NonInteractive -Command '[Environment]::GetFolderPath("UserProfile")' | tr -d '\r')
  [[ -n "${raw}" ]] || return 1
  profile=$(wslpath -u "${raw}")
  [[ -n "${profile}" ]] || return 1
  printf '%s\n' "${profile}/.wslconfig"
}

self_check() {
  local tmp state
  tmp=$(mktemp -d)
  state=$(classify_wslconfig "${tmp}/missing")
  [[ "${state}" == "absent" ]]
  printf '[wsl2]\nmemory=80GB\n' > "${tmp}/.wslconfig"
  state=$(classify_wslconfig "${tmp}/.wslconfig")
  [[ "${state}" == "present" ]]
  mkdir "${tmp}/dir"
  if classify_wslconfig "${tmp}/dir" >/dev/null; then
    echo "a directory was classified as a wslconfig file" >&2
    exit 1
  fi
  rm -rf "${tmp}"
  echo "evidence-host self-check ok"
}

if [[ "${1:-}" == "--self-check" ]]; then
  self_check
  exit 0
fi

if [[ ! -d /mnt/c ]]; then
  echo "refusing: run this from the operator distro. aap-runner has automount off." >&2
  exit 1
fi
if ! command -v wsl.exe >/dev/null 2>&1 || ! command -v powershell.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1; then
  echo "refusing: wsl.exe, powershell.exe, and wslpath are required" >&2
  exit 1
fi

version=$(mktemp)
cfg=$(mktemp)
trap 'rm -f "${version}" "${cfg}"' EXIT
wsl.exe --version > "${version}"
wslcfg=$(windows_profile_wslconfig)
state=$(classify_wslconfig "${wslcfg}") || {
  echo "refusing: ${wslcfg} is unreadable" >&2
  exit 1
}
wsl.exe -d "${DISTRO}" -u root -- tee /run/aap-wsl-version >/dev/null < "${version}"
if [[ "${state}" == "present" ]]; then
  cp "${wslcfg}" "${cfg}"
  wsl.exe -d "${DISTRO}" -u root -- tee /run/aap-wslconfig >/dev/null < "${cfg}"
else
  wsl.exe -d "${DISTRO}" -u root -- rm -f /run/aap-wslconfig
fi
wsl.exe -d "${DISTRO}" -u root -- env \
  AAP_WSL_VERSION_FILE=/run/aap-wsl-version \
  AAP_WSLCONFIG_STATE="${state}" \
  AAP_WSLCONFIG_FILE=/run/aap-wslconfig \
  bash /usr/local/sbin/aap-runner-evidence
