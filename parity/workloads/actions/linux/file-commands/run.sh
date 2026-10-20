#!/bin/bash
# actions/linux/file-commands: checks the marker the composite action in this folder wrote earlier in the same job
# (same run id and attempt), so GITHUB_ENV/PATH/OUTPUT/STEP_SUMMARY and working-directory behaviour lands in the results.
# Sabotage missing-marker looks for a marker that was never written.
# shellcheck source-path=SCRIPTDIR source=../../../linux/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../../linux/lib.sh"
wl_start "$@"
require_actions

name=aap-parity-file-commands.json
if [ "${SABOTAGE}" = missing-marker ]; then
  name=aap-parity-file-commands.missing.json
  line "sabotage missing-marker applied"
  # the sabotage holds: the composite action did write the real marker; only the name looked up is wrong
  fact sabotage.real_marker_exists "$([ -f "${RUNNER_TEMP:-}/aap-parity-file-commands.json" ] && echo yes)" yes
elif [ -n "${SABOTAGE}" ]; then
  die "unknown sabotage ${SABOTAGE}"
fi
marker="${RUNNER_TEMP:-}/${name}"
[ -f "${marker}" ] || die 'file-commands marker not found: run uses: ./parity/workloads/actions/linux/file-commands earlier in this job'
run python3 -B -I -c 'import json, sys
m = json.load(open(sys.argv[1]))
print("run_id\t" + str(m["run_id"]))
print("run_attempt\t" + str(m["run_attempt"]))
for k, v in m["checks"].items():
    print("check." + k + "\t" + str(v))' "${marker}"
lines=()
while IFS=$'\t' read -r k v; do
  case ${k} in
    run_id) fact marker.run_id "${v}" "${GITHUB_RUN_ID:-}" ;;
    run_attempt) fact marker.run_attempt "${v}" "${GITHUB_RUN_ATTEMPT:-}" ;;
    *) fact "${k}" "${v}" True; lines+=("${k#check.}=${v}") ;;
  esac
done <<< "${OUT}"
fact marker.checks "${#lines[@]}" 8
report "${lines[@]}"
wl_end
