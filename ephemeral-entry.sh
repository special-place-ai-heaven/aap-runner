#!/bin/bash
# One ephemeral Actions job inside a Sysbox container.
# Stdin is the registration token (one line). The app private key is not
# mounted and is not in the environment.
set -euo pipefail

start_inner_dockerd() {
  if [[ -S /var/run/docker.sock ]]; then
    rm -f /var/run/docker.sock
  fi
  dockerd --host unix:///var/run/docker.sock >/var/log/aap-inner-dockerd.log 2>&1 &
  for _ in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
      chown root:docker /var/run/docker.sock
      chmod 660 /var/run/docker.sock
      return 0
    fi
    sleep 1
  done
  echo "inner dockerd did not become ready" >&2
  return 1
}

if [[ "${1:-}" == "--preflight" ]]; then
  start_inner_dockerd
  docker info
  exit 0
fi

: "${AAP_GITHUB_ORG:?AAP_GITHUB_ORG is required}"
: "${AAP_RUNNER_LABELS:?AAP_RUNNER_LABELS is required}"
: "${AAP_RUNNER_GROUP:?AAP_RUNNER_GROUP is required}"

reg_token=""
IFS= read -r reg_token || true
if [[ -z "${reg_token}" ]]; then
  echo "registration token missing on stdin" >&2
  exit 1
fi

start_inner_dockerd

rm -rf /opt/actions-runner/_work
install -d -o runner -g runner /opt/actions-runner/_work

# runuser drops the environment. Whitelist the four names config.sh needs.
# The registration token stays out of argv; it is unset before run.sh.
export AAP_RUNNER_REG_TOKEN="${reg_token}"
# Names in this script expand in the runner user's shell, not this one.
# shellcheck disable=SC2016
runuser -u runner \
  --whitelist-environment=AAP_GITHUB_ORG,AAP_RUNNER_LABELS,AAP_RUNNER_GROUP,AAP_RUNNER_REG_TOKEN \
  -- bash -c '
  set -euo pipefail
  cd /opt/actions-runner
  ./config.sh --unattended --ephemeral --disableupdate=false \
    --url "https://github.com/${AAP_GITHUB_ORG}" \
    --token "${AAP_RUNNER_REG_TOKEN}" \
    --labels "${AAP_RUNNER_LABELS}" \
    --runnergroup "${AAP_RUNNER_GROUP}" \
    --work _work \
    --name "aap-crrr-${HOSTNAME:-runner}"
'
reg_token=""
unset reg_token AAP_RUNNER_REG_TOKEN

exec runuser -u runner -- bash -c 'cd /opt/actions-runner && exec ./run.sh'
