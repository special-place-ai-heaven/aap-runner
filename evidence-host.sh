#!/bin/bash
# Capture wsl --version, the Windows user's .wslconfig, and the org's
# registered runners, then run evidence inside aap-runner. That distro has
# automount off, so it cannot read the Windows profile or launch wsl.exe.
# Run this from the operator distro.
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

# Registered labels for comparison with manager.conf. A missing gh or a
# failed request is written into the file. This does not fail the script
# and it does not read the App private key.
GITHUB_RUNNERS_PATH=/orgs/special-place-ai-heaven/actions/runners

fetch_registered_runners() {
  local dest="$1" rc=0 body
  {
    printf '%s\n' "GET ${GITHUB_RUNNERS_PATH}"
    if ! command -v gh >/dev/null 2>&1; then
      echo "gh is not installed"
      echo "retry: gh api --paginate ${GITHUB_RUNNERS_PATH} --jq '.runners[] | \"\\(.name)\\t\\(.status)\\t\\([.labels[].name] | join(\",\"))\"'"
      echo "retry: curl -fsS -H \"Authorization: Bearer \$TOKEN\" -H \"Accept: application/vnd.github+json\" \"https://api.github.com${GITHUB_RUNNERS_PATH}\""
      return 0
    fi
    body=$(gh api --paginate "${GITHUB_RUNNERS_PATH}" \
      --jq '.runners[] | "\(.name)\t\(.status)\t\([.labels[].name] | join(","))"' 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      echo "gh api failed (exit ${rc})"
      printf '%s\n' "${body}"
      echo "retry: gh api --paginate ${GITHUB_RUNNERS_PATH}"
      return 0
    fi
    if [[ -z "${body}" ]]; then
      echo "(no runners returned)"
    else
      printf '%s\n' "${body}"
    fi
  } > "${dest}"
}

self_check() {
  local tmp state out
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
  tmp=$(mktemp -d)
  mkdir -p "${tmp}/bin" "${tmp}/empty"
  cat > "${tmp}/bin/gh" <<'EOF'
#!/bin/bash
printf 'aap-crrr\tonline\tself-hosted,linux,crrr\n'
EOF
  chmod +x "${tmp}/bin/gh"
  PATH="${tmp}/bin" fetch_registered_runners "${tmp}/runners"
  out=$(cat "${tmp}/runners")
  [[ "${out}" == *"GET /orgs/special-place-ai-heaven/actions/runners"* ]]
  [[ "${out}" == *"aap-crrr"* ]]
  [[ "${out}" == *$'\t'"online"$'\t'"self-hosted,linux,crrr"* ]]
  PATH="${tmp}/empty" fetch_registered_runners "${tmp}/runners-nogh"
  out=$(cat "${tmp}/runners-nogh")
  [[ "${out}" == *"gh is not installed"* ]]
  [[ "${out}" == *"GET /orgs/special-place-ai-heaven/actions/runners"* ]]
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
runners=$(mktemp)
trap 'rm -f "${version}" "${cfg}" "${runners}"' EXIT
wsl.exe --version > "${version}"
wslcfg=$(windows_profile_wslconfig)
state=$(classify_wslconfig "${wslcfg}") || {
  echo "refusing: ${wslcfg} is unreadable" >&2
  exit 1
}
fetch_registered_runners "${runners}"
wsl.exe -d "${DISTRO}" -u root -- tee /run/aap-wsl-version >/dev/null < "${version}"
if [[ "${state}" == "present" ]]; then
  cp "${wslcfg}" "${cfg}"
  wsl.exe -d "${DISTRO}" -u root -- tee /run/aap-wslconfig >/dev/null < "${cfg}"
else
  wsl.exe -d "${DISTRO}" -u root -- rm -f /run/aap-wslconfig
fi
wsl.exe -d "${DISTRO}" -u root -- tee /run/aap-github-runners >/dev/null < "${runners}"
wsl.exe -d "${DISTRO}" -u root -- env \
  AAP_WSL_VERSION_FILE=/run/aap-wsl-version \
  AAP_WSLCONFIG_STATE="${state}" \
  AAP_WSLCONFIG_FILE=/run/aap-wslconfig \
  AAP_GITHUB_RUNNERS_FILE=/run/aap-github-runners \
  bash /usr/local/sbin/aap-runner-evidence
