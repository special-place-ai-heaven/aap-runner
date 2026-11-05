#!/bin/bash
# The actions-runner pin is the same in the Dockerfile COPY, bootstrap.sh (URL,
# hash, file name) and distro/README.md, is at least the version GitHub requires,
# and ephemeral-entry.sh registers the runner with --disableupdate so a baked
# runner never self-updates mid-job.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
distro="${here}/../distro"
MIN_VERSION=2.338.2

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

name=$(sed -n 's/^RUNNER_NAME=//p' "${distro}/bootstrap.sh")
url=$(sed -n 's/^RUNNER_URL=//p' "${distro}/bootstrap.sh")
sha=$(sed -n 's/^RUNNER_SHA256=//p' "${distro}/bootstrap.sh")
[[ -n "${name}" && -n "${url}" && -n "${sha}" ]] || fail "bootstrap.sh does not pin the runner (name, url, sha256)"
[[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || fail "RUNNER_SHA256 is not 64 lowercase hex digits"

version=${name#actions-runner-linux-x64-}
version=${version%.tar.gz}
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "cannot read a version from RUNNER_NAME ${name}"
[[ "${url}" == "https://github.com/actions/runner/releases/download/v${version}/${name}" ]] || fail "RUNNER_URL ${url} does not match RUNNER_NAME ${name}"
[[ "$(printf '%s\n%s\n' "${MIN_VERSION}" "${version}" | sort -V | head -n 1)" == "${MIN_VERSION}" ]] || fail "runner ${version} is older than the required ${MIN_VERSION}"
echo "bootstrap pin ok (${version})"

grep -qx "COPY ${name} /tmp/actions-runner.tar.gz" "${distro}/Dockerfile" || fail "Dockerfile does not COPY ${name}"
grep -qF "| \`${url}\` | \`${sha}\` |" "${distro}/README.md" || fail "README.md pin table does not list ${url} with ${sha}"
grep -qF "actions-runner ${version} linux-x64" "${distro}/README.md" || fail "README.md pin table does not name version ${version}"
echo "dockerfile and README pin ok"

grep -qE '^  \./config\.sh .* --disableupdate( |\\)' "${distro}/ephemeral-entry.sh" || fail "config.sh is not called with --disableupdate"
if grep -q -- '--disableupdate=' "${distro}/ephemeral-entry.sh"; then
  fail "config.sh still passes --disableupdate with a value"
fi
echo "disableupdate ok"

echo "runner pin tests ok"
