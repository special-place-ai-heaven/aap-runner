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

# Registered labels for comparison with manager.conf. Auth is only
# AAP_RUNNERS_READ_TOKEN, a fine-grained token with Self-hosted runners:
# Read. It is passed as GH_TOKEN for the one gh call. Ambient gh login is
# not used. A missing token is recorded and is not a failure. The App
# private key is not read, and the token is not printed.
GITHUB_RUNNERS_PATH=/orgs/special-place-ai-heaven/actions/runners

write_registered_runners() {
  local dest="$1" rc=0 body
  set +x
  {
    printf '%s\n' "GET ${GITHUB_RUNNERS_PATH}"
    if [[ -z "${AAP_RUNNERS_READ_TOKEN:-}" ]]; then
      echo "runners fetch: skipped (no AAP_RUNNERS_READ_TOKEN)"
      return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
      echo "gh is not installed"
      echo "retry: export AAP_RUNNERS_READ_TOKEN and re-run evidence-host.sh after gh is installed"
      return 0
    fi
    # set +x so the token on this command line is not traced.
    # GH_TOKEN exists only in this child. GITHUB_TOKEN is removed so an
    # ambient login cannot satisfy the request.
    body=$(
      set +x
      env -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GH_DEBUG \
        GH_TOKEN="${AAP_RUNNERS_READ_TOKEN}" \
        gh api --paginate "${GITHUB_RUNNERS_PATH}" \
        --jq '.runners[] | "\(.name)\t\(.status)\t\([.labels[].name] | join(","))"' 2>&1
    ) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      echo "gh api failed (exit ${rc})"
      printf '%s\n' "${body}"
      echo "retry: export AAP_RUNNERS_READ_TOKEN and re-run evidence-host.sh"
      return 0
    fi
    if [[ -z "${body}" ]]; then
      echo "(no runners returned)"
    else
      printf '%s\n' "${body}"
    fi
  } > "${dest}"
}

fetch_registered_runners() {
  local dest="$1" tracing=0
  case $- in
    *x*) tracing=1 ;;
  esac
  set +x
  write_registered_runners "${dest}"
  if [[ "${tracing}" -eq 1 ]]; then
    set -x
  fi
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
set +x
if [[ -n "${AAP_GH_MARKER:-}" ]]; then
  printf 'invoked\n' >> "${AAP_GH_MARKER}"
fi
if [[ "${GH_TOKEN:-}" != "test-runners-read-token" ]]; then
  echo "gh was not given the runners read token" >&2
  exit 1
fi
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  echo "gh inherited GITHUB_TOKEN" >&2
  exit 1
fi
printf 'aap-crrr\tonline\tself-hosted,linux,crrr\n'
EOF
  chmod +x "${tmp}/bin/gh"
  : > "${tmp}/marker"
  AAP_GH_MARKER="${tmp}/marker" \
    PATH="${tmp}/bin" \
    GH_TOKEN=ambient-operator-token \
    GITHUB_TOKEN=ambient-github-token \
    AAP_RUNNERS_READ_TOKEN='' \
    fetch_registered_runners "${tmp}/runners-notoken"
  out=$(cat "${tmp}/runners-notoken")
  [[ "${out}" == *"runners fetch: skipped (no AAP_RUNNERS_READ_TOKEN)"* ]]
  [[ ! -s "${tmp}/marker" ]]
  [[ "${out}" != *"ambient-operator-token"* ]]
  [[ "${out}" != *"ambient-github-token"* ]]
  [[ "${out}" != *"test-runners-read-token"* ]]
  AAP_RUNNERS_READ_TOKEN=test-runners-read-token \
    PATH="${tmp}/empty" \
    fetch_registered_runners "${tmp}/runners-nogh"
  out=$(cat "${tmp}/runners-nogh")
  [[ "${out}" == *"gh is not installed"* ]]
  [[ "${out}" != *"test-runners-read-token"* ]]
  : > "${tmp}/marker"
  AAP_GH_MARKER="${tmp}/marker" \
    PATH="${tmp}/bin:/usr/bin:/bin" \
    GH_TOKEN=ambient-operator-token \
    GITHUB_TOKEN=ambient-github-token \
    AAP_RUNNERS_READ_TOKEN=test-runners-read-token \
    fetch_registered_runners "${tmp}/runners"
  out=$(cat "${tmp}/runners")
  [[ "${out}" == *"GET /orgs/special-place-ai-heaven/actions/runners"* ]]
  [[ "${out}" == *"aap-crrr"* ]]
  [[ "${out}" == *$'\t'"online"$'\t'"self-hosted,linux,crrr"* ]]
  [[ -s "${tmp}/marker" ]]
  [[ "${out}" != *"test-runners-read-token"* ]]
  [[ "${out}" != *"ambient-operator-token"* ]]
  [[ "${out}" != *"ambient-github-token"* ]]
  rm -rf "${tmp}"
  echo "evidence-host self-check ok"
}

if [[ "${1:-}" == "--self-check" ]]; then
  self_check
  exit 0
fi

if ! mountpoint -q /mnt/c; then
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
