#!/bin/bash
# One ephemeral Actions job inside a Sysbox container.
# Stdin is the registration token (one line). The app private key is not
# mounted and is not in the environment.
set -euo pipefail

# zccache, installed by the Dockerfile. The job's private root lives in the
# container (guests/cache/INTEGRATION.md, P15); no root is shared between jobs.
ZC_DIR=/usr/local/libexec/aap-guest/cache
ZC_ROOT=/var/cache/aap-zccache

start_inner_dockerd() {
  local enabled
  if [[ -S /var/run/docker.sock ]]; then
    rm -f /var/run/docker.sock
  fi
  install -d -m 0755 /etc/docker
  printf '%s\n' '{"ipv6":false}' > /etc/docker/daemon.json
  dockerd --host unix:///var/run/docker.sock >/var/log/aap-inner-dockerd.log 2>&1 &
  for _ in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
      chown root:docker /var/run/docker.sock
      chmod 660 /var/run/docker.sock
      enabled=$(docker network inspect bridge --format '{{.EnableIPv6}}')
      if [[ "${enabled}" != "false" ]]; then
        echo "refusing: inner dockerd IPv6 is '${enabled}'; expected false" >&2
        return 1
      fi
      return 0
    fi
    sleep 1
  done
  echo "inner dockerd did not become ready" >&2
  return 1
}

# Creates the job root and runs `init` as the runner user from a clean
# environment, before the runner starts (INTEGRATION.md, P15 step 2). `init`
# writes ${ZC_ROOT}/state/runner.env, which run.sh below loads. While no
# compiler and invocation pair is qualified that file is empty, so compilers
# run directly. A failed init also builds directly (contract rule 7); it never
# fails the job.
start_zccache() {
  install -d -o runner -g runner -m 0700 "${ZC_ROOT}"
  if ! runuser -u runner -- env -i PATH=/usr/bin:/bin HOME=/home/runner \
    "${ZC_DIR}/aap-zccache.sh" init "${ZC_DIR}" "${ZC_ROOT}" "${AAP_ZCCACHE_BUDGET_BYTES:-0}" >/dev/null; then
    echo "zccache: init failed; compilers run directly" >&2
    return 0
  fi
  echo "zccache: $(runuser -u runner -- "${ZC_DIR}/aap-zccache.sh" state "${ZC_ROOT}" || true)"
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
start_zccache

rm -rf /opt/actions-runner/_work
install -d -o runner -g runner /opt/actions-runner/_work

# runuser -u keeps this environment except HOME, SHELL, USER and LOGNAME
# (only --login resets it), so config.sh sees the names docker passed in
# and the token exported here.
# The registration token stays out of argv; it is unset before run.sh.
export AAP_RUNNER_REG_TOKEN="${reg_token}"
# Names in this script expand in the runner user's shell, not this one.
# shellcheck disable=SC2016
runuser -u runner -- bash -c '
  set -euo pipefail
  cd /opt/actions-runner
  ./config.sh --unattended --ephemeral --disableupdate \
    --url "https://github.com/${AAP_GITHUB_ORG}" \
    --token "${AAP_RUNNER_REG_TOKEN}" \
    --labels "${AAP_RUNNER_LABELS}" \
    --runnergroup "${AAP_RUNNER_GROUP}" \
    --work _work \
    --name "aap-crrr-${HOSTNAME:-runner}"
'
reg_token=""
unset reg_token AAP_RUNNER_REG_TOKEN

# run.sh inherits this environment too, with the token unset above, so it
# keeps the disk bounds docker passed in. The zccache settings come from
# runner.env, which init wrote.
# Names in this script expand in the runner user's shell, not this one.
# shellcheck disable=SC2016
exec runuser -u runner -- bash -c '
  cd /opt/actions-runner
  if [[ -s "$1" ]]; then
    set -a
    . "$1"
    set +a
  fi
  exec ./run.sh
' bash "${ZC_ROOT}/state/runner.env"
