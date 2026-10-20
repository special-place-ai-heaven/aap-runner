#!/bin/bash
# actions/linux/shell-semantics: step bodies run through the exact command lines the Actions runner uses on Linux for
# shell: bash, sh, pwsh and python and for a step that names no shell (oracle shell_templates, with the runner's pwsh
# fixups), and their exit codes compared with the oracle: errexit, pipefail (only shell: bash has it), exit codes.
# Also which binary bash, sh, pwsh and python resolve to, and, inside a job, the command line the runner really used
# for the step that started this workload (found among this process's ancestors).
# Sabotage dash-as-bash puts a 'bash' that is really dash first on PATH.
# shellcheck source-path=SCRIPTDIR source=../../../linux/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../../linux/lib.sh"
wl_start "$@"

if [ "${SABOTAGE}" = dash-as-bash ]; then
  mkdir -p "${WORK}/fakebin"
  ln -s "$(readlink -f /bin/sh)" "${WORK}/fakebin/bash"
  export PATH="${WORK}/fakebin:${PATH}"
  line "sabotage dash-as-bash applied"
  fact sabotage.bash_resolves "$(norm "$(command -v bash)")" '<work>/fakebin/bash'
elif [ -n "${SABOTAGE}" ]; then
  die "unknown sabotage ${SABOTAGE}"
fi
bash_exe=$(command -v bash) || die 'bash is not on PATH'
[ -n "$("${bash_exe}" -c 'echo "${BASH_VERSION:-}"' 2> /dev/null)" ] || die "bash on PATH is not GNU bash: ${bash_exe}"
for s in bash sh pwsh python; do fact "resolve.${s}" "$(command -v "${s}")" "$(oracle "shell_paths/${s}")"; done
fact resolve.sh_target "$(readlink -f "$(command -v sh)")" "$(oracle shell_paths/sh_target)"

if [ "${GITHUB_ACTIONS:-}" = true ]; then
  # the runner's own command line for the step that started this workload: the nearest ancestor running a _temp script
  pid=$$ step=''
  while [ "${pid}" -gt 1 ]; do
    cmd=$(tr '\0' ' ' < "/proc/${pid}/cmdline")
    if [[ ${cmd} == *"/_temp/"*.sh* ]]; then step=$(sed -E 's#[^ ]*/_temp/[^ ]+\.sh#{0}#' <<< "${cmd% }"); break; fi
    pid=$(awk '{ print $4 }' "/proc/${pid}/stat")
  done
  fact runner.step_shell "${step}" "$(oracle shell_templates/bash_resolved)"
fi

pre="\$ErrorActionPreference = 'stop'"
post='if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }'
# name|shell|extension|body (\n separates lines)
cases=(
  'bash.ok|bash|sh|true'
  'bash.errexit|bash|sh|false\necho after'
  'bash.pipefail|bash|sh|false | true'
  'bash.exit|bash|sh|exit 5'
  'default.errexit|default|sh|false\necho after'
  'default.pipefail|default|sh|false | true'
  'sh.errexit|sh|sh|false\necho after'
  'sh.pipefail|sh|sh|false | true'
  'sh.exit|sh|sh|exit 4'
  "pwsh.native_last|pwsh|ps1|${pre}\nsh -c 'exit 3'\n${post}"
  "pwsh.native_then_ok|pwsh|ps1|${pre}\nsh -c 'exit 3'\nsh -c 'exit 0'\n${post}"
  "pwsh.cmdlet_error|pwsh|ps1|${pre}\nWrite-Error 'parity cmdlet error'\n${post}"
  "pwsh.exit|pwsh|ps1|${pre}\nexit 7\n${post}"
  'python.exit|python|py|import sys; sys.exit(6)'
)
lines=()
n=0
for c in "${cases[@]}"; do
  IFS='|' read -r name sh ext body <<< "${c}"
  file="${WORK}/step$((n++)).${ext}"
  printf '%b\n' "${body}" > "${file}"
  tpl=$(oracle "shell_templates/${sh}")
  # the template is a command line with quotes (pwsh -command ". '{0}'"); split it like the runner does
  mapfile -d '' -t argv < <(python3 -B -I -c 'import shlex, sys
sys.stdout.write("\0".join(shlex.split(sys.argv[1].replace("{0}", sys.argv[2]))))' "${tpl}" "${file}")
  try_run "${argv[@]}"
  fact "exit.${name}" "${RC}" "$(oracle "shell_semantics/${name}")"
  lines+=("${name}=${RC}")
done
report "${lines[@]}"
wl_end
