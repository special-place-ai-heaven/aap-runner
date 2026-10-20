#!/bin/bash
# actions/linux/runner-env: what an Actions job process on this profile sees: default variables (CI, GITHUB_*,
# RUNNER_*), the image's variables, file-command files, the PATH order /etc/environment gives, the tool cache layout
# the setup-* actions rely on (<tool>/<version>/x64 plus x64.complete), the action archive cache, the user, its groups
# and passwordless sudo, limits and sysctls, and the Docker socket. Runs only inside an Actions job.
# Sabotage no-tool-cache looks for the tool cache layout in an empty folder instead of RUNNER_TOOL_CACHE (the
# variables themselves are left alone).
# shellcheck source-path=SCRIPTDIR source=../../../linux/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../../linux/lib.sh"
wl_start "$@"
require_actions

root=${RUNNER_TOOL_CACHE:-}
if [ "${SABOTAGE}" = no-tool-cache ]; then
  root="${WORK}/empty-tool-cache"
  mkdir -p "${root}"
  line "sabotage no-tool-cache applied"
elif [ -n "${SABOTAGE}" ]; then
  die "unknown sabotage ${SABOTAGE}"
else
  for n in $(oracle_keys runner_env); do fact "env.${n}" "$(printenv "${n}")" "$(oracle "runner_env/${n}")"; done
  for n in $(oracle_keys env); do fact "env.${n}" "$(printenv "${n}")" "$(oracle "env/${n}")"; done
  for n in GITHUB_ENV GITHUB_PATH GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_STATE; do
    f=$(printenv "${n}")
    fact "file_command.${n}" "$([ -n "${f}" ] && [ -d "${f%/*}" ] && echo yes)" yes
  done
  for n in RUNNER_TEMP GITHUB_WORKSPACE ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE; do
    fact "dir.${n}" "$([ -d "$(printenv "${n}")" ] && echo yes)" yes
  done
  fact action_archive_cache "$(cd "${ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE:-/nonexistent}" 2> /dev/null && ls -d -- */ | tr -d / | sort)" \
    "$(oracle_list action_archive_cache | sort)"
  # entries a GITHUB_PATH file command added earlier in this job (under RUNNER_TEMP) are not the image's PATH
  fact path_order "$(tr ':' '\n' <<< "${PATH}" | grep -v "^${RUNNER_TEMP}/")" "$(oracle_list path_order)"
  fact user.id "$(id)" "$(oracle user/id)"
  fact user.passwordless_sudo "$(sudo -n true 2> /dev/null && echo yes)" "$(oracle user/passwordless_sudo)"
  fact limit.nofile "$(ulimit -n)" "$(oracle limits/nofile)"
  fact limit.stack_kb "$(ulimit -s)" "$(oracle limits/stack_kb)"
  for k in $(oracle_keys sysctl); do fact "sysctl.${k}" "$(cat "/proc/sys/${k//.//}")" "$(oracle "sysctl/${k}")"; done
  fact docker.socket "$(stat -c '%A %U %G' /run/docker.sock)" "$(oracle docker_socket)"
  observe hosts.localhost "$(awk '$2 == "localhost" || $3 == "localhost" { print $1 }' /etc/hosts | sort -u)"
  observe hardware "nproc=$(nproc) $(grep -E '^(MemTotal|SwapTotal)' /proc/meminfo | tr -s ' ' | paste -sd' ' -)"
fi
fact env.RUNNER_TOOL_CACHE "${RUNNER_TOOL_CACHE:-}" "$(oracle env_tool_cache/RUNNER_TOOL_CACHE)"
fact env.AGENT_TOOLSDIRECTORY "${AGENT_TOOLSDIRECTORY:-}" "$(oracle env_tool_cache/AGENT_TOOLSDIRECTORY)"
while IFS= read -r e; do
  d="${root}/${e}"
  fact "tool_cache.${e}" "$([ -d "${d}/x64" ] && [ -f "${d}/x64.complete" ] && echo yes)" yes
done < <(oracle_list tool_cache)
wl_end
