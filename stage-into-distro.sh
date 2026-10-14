#!/bin/bash
# Copy the staged bootstrap into the new distro and run --inside-packages.
# wsl.exe --exec passes the stage path and disk size as argv. Nothing here
# is expanded by the distro's login shell.
set -euo pipefail

if [[ "${1:-}" == "--self-check" ]]; then
  rc=0
  bash "$0" >/dev/null 2>&1 || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    echo "an empty stage path was accepted" >&2
    exit 1
  fi
  echo "stage-into-distro self-check ok"
  exit 0
fi

stage="${1:-}"
gib="${2:-}"
if [[ -z "${stage}" || ! -f "${stage}/bootstrap.sh" || ! -f "${stage}/labels.sh" ]]; then
  echo "refusing: stage path is missing bootstrap.sh or labels.sh" >&2
  exit 1
fi
mkdir -p /opt/aap-runner
cp "${stage}/bootstrap.sh" /opt/aap-runner/bootstrap.sh
cp "${stage}/labels.sh" /opt/aap-runner/labels.sh
export AAP_RUNNER_STAGE="${stage}"
if [[ -n "${gib}" ]]; then
  export AAP_WORK_DISK_GIB="${gib}"
fi
exec bash /opt/aap-runner/bootstrap.sh --inside-packages
