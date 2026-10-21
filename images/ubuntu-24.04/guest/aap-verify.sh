#!/bin/bash
# P07 verification inside a FRESH guest of the sealed image, run by the agent as the job user (runner, uid 1001, the user a
# hosted job runs as) after the post-generation scripts ran as root. No network.
#  1. Upstream image tests: the pinned tests from the P03-staged archive, run by the upstream RunAll-Tests.ps1.
#  2. Full job inventory with the P05 probe (tools/parity-certify/probe/linux.sh), Docker and sudo included.
#  3. What a job relies on: compilers that build and run a program, the job user's identity and passwordless sudo, systemd
#     as PID 1, the Docker daemon, the Azure kernel flavour.
# Writes <work>/verify.json (one object, the reply's data) and <work>/job-inventory.json. Downloads nothing.
#   aap-verify.sh <work folder> <post-generation exit code> <1 when the first boot made the snakeoil TLS pair>
set -u
export LC_ALL=C
W=$1
POSTGEN_RC=${2:-1}
SNAKEOIL=${3:-0}
cd "${W}" || exit 1
# The Actions runner reads /etc/environment itself (a --norc job shell does not); the checks see what a job step sees.
set -a
# shellcheck source=/dev/null
. "${AAP_ENVIRONMENT_FILE:-/etc/environment}"   # tests only: another file
set +a

js() { local s="${1//[^ -~]/?}"; s="${s:0:200}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "${s}"; }
ok() { if "$@" > /dev/null 2>&1; then printf true; else printf false; fi; }
attr() { # attribute of the <test-results> element in $1
  local v
  v=$(grep -o -m1 '<test-results [^>]*>' "$1" | grep -o " $2=\"[0-9]*\"" | grep -o '[0-9]*')
  printf '%s' "${v:-0}"
}

# 1. Upstream tests, with the environment upstream's inline block gave them.
mkdir -p "${W}/installers" "${W}/tests-out"
cp "${W}/src/images/ubuntu/toolsets/toolset-2404.json" "${W}/installers/toolset.json"
# shellcheck disable=SC2154 # ImageVersion comes from /etc/environment
IMAGE_VERSION=${ImageVersion:-} INSTALLER_SCRIPT_FOLDER="${W}/installers" \
  pwsh -NoProfile -NonInteractive -File "${W}/src/images/ubuntu/scripts/tests/RunAll-Tests.ps1" -OutputDirectory "${W}/tests-out" > "${W}/upstream-tests.log" 2>&1
results="${W}/tests-out/testResults.xml"
total=0; failed=1; skipped=0
if [ -f "${results}" ]; then
  total=$(attr "${results}" total)
  failed=$(( $(attr "${results}" failures) + $(attr "${results}" errors) + $(attr "${results}" invalid) ))
  skipped=$(( $(attr "${results}" not-run) + $(attr "${results}" skipped) + $(attr "${results}" ignored) + $(attr "${results}" inconclusive) ))
fi
passed=$(( total - failed - skipped )); [ "${passed}" -ge 0 ] || passed=0

# 2. Inventory.
bash "${W}/linux.sh" --out "${W}/job-inventory.json" > "${W}/probe.log" 2>&1
inv_sha=''
[ ! -f "${W}/job-inventory.json" ] || inv_sha=$(sha256sum "${W}/job-inventory.json" | cut -d' ' -f1)

# 3. Discovery the way a job step does it.
groups=" $(id -nG) "
job_user=false
if [ "$(id -un)" = runner ] && [ "$(id -u)" = 1001 ]; then
  job_user=true
  for g in adm users docker systemd-journal; do [[ ${groups} == *" ${g} "* ]] || job_user=false; done
fi
root_dev=$(findmnt -no SOURCE /)
root_disk=$(lsblk -no PKNAME "${root_dev}" 2>/dev/null | head -n 1)
facts_kernel=$(uname -r)
{
  printf '{"upstream_tests":{"total":%s,"passed":%s,"failed":%s,"skipped":%s},' "${total}" "${passed}" "${failed}" "${skipped}"
  printf '"discovery":{'
  printf '"gcc":%s,"gxx":%s,"clang":%s,' "$(ok gcc --version)" "$(ok g++ --version)" "$(ok clang --version)"
  printf '"cmake":%s,"ninja":%s,"make":%s,"pkg_config":%s,' "$(ok cmake --version)" "$(ok ninja --version)" "$(ok make --version)" "$(ok pkg-config --version)"
  printf '"hello_gcc":%s,' "$(ok sh -c 'gcc -o hello_gcc hello.c && ./hello_gcc')"
  printf '"hello_clang":%s,' "$(ok sh -c 'clang -o hello_clang hello.c && ./hello_clang')"
  printf '"pwsh":%s,"python3":%s,' "$(ok pwsh -NoProfile -Command exit)" "$(ok python3 --version)"
  printf '"docker_daemon":%s,"sudo_nopasswd":%s,' "$(ok docker info)" "$(ok sudo -n true)"
  printf '"systemd_pid1":%s,' "$(ok grep -qx systemd /proc/1/comm)"
  printf '"kernel_azure":%s,' "$( [[ ${facts_kernel} == *-azure ]] && printf true || printf false)"
  printf '"job_user":%s,"post_generation":%s,' "${job_user}" "$( [ "${POSTGEN_RC}" = 0 ] && printf true || printf false)"
  printf '"tls_snakeoil":%s},' "$( [ "${SNAKEOIL}" = 1 ] && printf true || printf false)"
  printf '"facts":{"kernel":%s,"systemd_state":%s,' "$(js "${facts_kernel}")" "$(js "$(systemctl is-system-running 2>/dev/null)")"
  printf '"root_mount_options":%s,' "$(js "$(findmnt -no OPTIONS /)")"
  printf '"read_ahead_kb_root":%s},' "$(js "$(cat "/sys/block/${root_disk}/queue/read_ahead_kb" 2>/dev/null)")"
  printf '"inventory_sha256":%s}\n' "$(js "${inv_sha}")"
} > "${W}/verify.json"
