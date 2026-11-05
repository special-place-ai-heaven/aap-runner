#!/bin/bash
# .github/workflows/runner-image-check.yml runs on the pool's self-hosted
# runners, which may be shared with a public repo, so it must stay a manual
# check: workflow_dispatch only, no token permissions, the exact pool labels,
# a 10 minute limit, and no checkout or other action (it never fetches or runs
# PR code). It must print what the image promises.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
wf="${here}/../.github/workflows/runner-image-check.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "${wf}" ]] || fail "${wf##*/../} is missing"

# The on: block is exactly workflow_dispatch.
on_block=$(awk '/^on:/ {f=1; next} f && /^[^ #]/ {f=0} f' "${wf}" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$')
[[ "${on_block}" == "  workflow_dispatch:" ]] || fail "on: is not exactly workflow_dispatch: ${on_block}"
grep -qx 'permissions: {}' "${wf}" || fail "top-level permissions are not {}"
if grep -nE '^\s+permissions:' "${wf}"; then fail "a job asks for permissions"; fi
grep -qF 'runs-on: [self-hosted, linux, x64, fresh]' "${wf}" || fail "runs-on is not [self-hosted, linux, x64, fresh]"
grep -qE '^    timeout-minutes: 10$' "${wf}" || fail "timeout-minutes is not 10"
echo "trigger, permissions, runner and timeout ok"

if grep -nE '^\s*-?\s*uses:|pull_request|github\.event|github\.head_ref|actions/checkout|\$\{\{' "${wf}"; then
  fail "the workflow uses an action, a PR event or an expression"
fi
echo "no checkout, action or PR input ok"

for needle in \
  'jq --version' \
  'node --version' \
  'npm --version' \
  '/usr/local/libexec/aap-guest/cache/bin/zccache --version' \
  'RUSTC_WRAPPER' \
  '/opt/actions-runner/bin/Runner.Listener --version' \
  'nproc' \
  'cat /sys/fs/cgroup/cpu.max' \
  "sh -c 'sleep 300 & echo \$! > /tmp/p'" \
  'kill -9 $(cat /tmp/p)' \
  '|| { echo "process state $s"; exit 1; }'; do
  grep -qF -- "${needle}" "${wf}" || fail "the workflow does not run: ${needle}"
done
echo "checks present ok"

# Actions' default bash runs with -e, and awk exits 2 once the killed process is
# gone (the passing case), so the zombie step needs a shell without -e.
grep -qE '^        shell: bash \{0\}$' "${wf}" || fail "the zombie step does not set shell: bash {0}"
echo "zombie step shell ok"

echo "runner image check workflow tests ok"
