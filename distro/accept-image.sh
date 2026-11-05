#!/bin/bash
# Image acceptance: build the runner image under a temporary tag and check it
# in temporary containers before any rollout. Run as root inside the distro.
#
#   accept-image.sh assemble SRC CONTEXT   verified build context in CONTEXT
#   accept-image.sh verify CONTEXT [TAG]   build TAG, check it, remove it
#
# SRC holds the repo's distro/ files (Dockerfile, ephemeral-entry.sh,
# aap-zccache.sh, zccache-wrappers.json, bootstrap.sh, staging.sha256). The
# base rootfs comes from the install's image dir and the runner tarball is
# downloaded; both are checked against the pins in bootstrap.sh.
#
# verify never touches the live pool: TAG must be aap-accept:<name>, the
# containers are named aap-accept-* and carry no aap-crrr-job label and no
# environment or mount, nothing registers (no token is ever given), and TAG is
# untagged, never force-removed. It refuses while aap-runner-manager is
# active: the manager prunes dangling images after every job, which breaks a
# build in progress (seen live 2026-11-05). Drain the pool and let the manager
# exit first; ACCEPT_ALLOW_LIVE_POOL=1 overrides. ACCEPT_KEEP=1 keeps the tag.
#
# It proves: the image builds; --init runs as PID 1 under Sysbox; the
# preflight (inner dockerd) passes with --assert-mounts; the runner, Node and
# zccache are the pinned versions, jq and npm are present, sccache is absent,
# the runner user has no sudo; zccache init works as the runner user. It
# cannot prove that a runner stays registered after a job: that needs a real
# job, the rollout canary.
set -euo pipefail

ACCEPT_INSTALL_IMAGE_DIR=${ACCEPT_INSTALL_IMAGE_DIR:-/var/lib/aap-runner/image}
ACCEPT_MANAGER=${ACCEPT_MANAGER:-/usr/local/sbin/aap-runner-manager}
ACCEPT_LOCK=${ACCEPT_LOCK:-/run/aap-accept.lock}
ACCEPT_BUILD_TIMEOUT=${ACCEPT_BUILD_TIMEOUT:-2700}
ACCEPT_RUN_TIMEOUT=${ACCEPT_RUN_TIMEOUT:-300}
ACCEPT_TMP=${ACCEPT_TMP:-/tmp}
ACCEPT_FILES=(Dockerfile ephemeral-entry.sh aap-zccache.sh zccache-wrappers.json)
# The image's zccache install dir; tests point it at a stub.
ZC_DIR=${ACCEPT_ZC_DIR:-/usr/local/libexec/aap-guest/cache}
# A real budget: 0 makes init report "disabled", not "direct".
ZC_PROBE_BUDGET=1073741824

failures=0
containers=()
built_tag=""
work=""

say() { echo "accept: $*"; }
check() { # NAME ok|fail DETAIL
  if [[ "$2" == ok ]]; then
    say "$1 ok${3:+ ($3)}"
  else
    say "$1 FAIL${3:+ ($3)}"
    failures=$((failures + 1))
  fi
}

# The value of NAME=... in FILE, refused unless it matches PATTERN.
pin() { # FILE NAME PATTERN
  local v
  v=$(sed -n "s/^$2=//p" "$1" | head -n 1)
  [[ "${v}" =~ ^$3$ ]] || { echo "refusing: $2 in $1 is '${v}'" >&2; return 1; }
  printf '%s\n' "${v}"
}

# Copies SRC to DEST, then checks the copy, so what is checked is what is used.
copy_checked() { # SRC DEST SHA256
  local got
  cp "$1" "$2" || return 1
  got=$(sha256sum "$2" | cut -d' ' -f1)
  if [[ "${got}" != "$3" ]]; then
    rm -f "$2"
    echo "refusing: $1 is ${got}, expected $3" >&2
    return 1
  fi
}

staged_sha() { # STAGING_FILE NAME
  local want
  want=$(awk -v n="$2" '$2 == n { print $1 }' "$1")
  [[ "${want}" =~ ^[0-9a-f]{64}$ ]] || { echo "refusing: no staging.sha256 entry for $2" >&2; return 1; }
  printf '%s\n' "${want}"
}

assemble() { # SRC CONTEXT
  local src=$1 ctx=$2 f want boot ub_name ub_sha rn_name rn_sha rn_url
  [[ -d "${src}" ]] || { echo "refusing: ${src} is not a directory" >&2; return 2; }
  if [[ -e "${ctx}" && -n "$(ls -A "${ctx}")" ]]; then
    echo "refusing: ${ctx} is not empty" >&2
    return 2
  fi
  install -d -m 0700 "${ctx}"
  for f in "${ACCEPT_FILES[@]}"; do
    want=$(staged_sha "${src}/staging.sha256" "${f}") || return 1
    copy_checked "${src}/${f}" "${ctx}/${f}" "${want}" || return 1
  done
  # The pins are read from a checked copy of bootstrap.sh, outside the context.
  boot=$(mktemp)
  want=$(staged_sha "${src}/staging.sha256" bootstrap.sh) || { rm -f "${boot}"; return 1; }
  copy_checked "${src}/bootstrap.sh" "${boot}" "${want}" || { rm -f "${boot}"; return 1; }
  ub_name=$(pin "${boot}" UBUNTU_NAME '[A-Za-z0-9._-]+\.tar\.gz') &&
    ub_sha=$(pin "${boot}" UBUNTU_SHA256 '[0-9a-f]{64}') &&
    rn_name=$(pin "${boot}" RUNNER_NAME 'actions-runner-linux-x64-[0-9.]+\.tar\.gz') &&
    rn_sha=$(pin "${boot}" RUNNER_SHA256 '[0-9a-f]{64}') &&
    rn_url=$(pin "${boot}" RUNNER_URL 'https://github\.com/actions/runner/releases/download/v[0-9.]+/actions-runner-linux-x64-[0-9.]+\.tar\.gz') ||
    { rm -f "${boot}"; return 1; }
  rm -f "${boot}"
  copy_checked "${ACCEPT_INSTALL_IMAGE_DIR}/${ub_name}" "${ctx}/${ub_name}" "${ub_sha}" || return 1
  if [[ -f "${ACCEPT_INSTALL_IMAGE_DIR}/${rn_name}" ]]; then
    copy_checked "${ACCEPT_INSTALL_IMAGE_DIR}/${rn_name}" "${ctx}/${rn_name}" "${rn_sha}" || return 1
  else
    curl --fail --silent --show-error --location --output "${ctx}/${rn_name}.part" "${rn_url}" || { rm -f "${ctx}/${rn_name}.part"; return 1; }
    copy_checked "${ctx}/${rn_name}.part" "${ctx}/${rn_name}" "${rn_sha}" || { rm -f "${ctx}/${rn_name}.part"; return 1; }
    rm -f "${ctx}/${rn_name}.part"
  fi
  say "context ${ctx} assembled (${#ACCEPT_FILES[@]} files, ${ub_name}, ${rn_name})"
}

# A pinned version, read from the Dockerfile being accepted.
dockerfile_pin() { # DOCKERFILE SED_EXPR
  sed -nE "$2" "$1" | head -n 1
}

# Containers and tags an earlier run left behind (killed, or the VM stopped).
remove_leftovers() {
  local c t
  for c in $(docker ps -aq --filter name=^aap-accept- 2> /dev/null); do
    docker rm -f "${c}" > /dev/null 2>&1 || true
  done
  for t in $(docker images --format '{{.Repository}}:{{.Tag}}' 2> /dev/null | grep '^aap-accept:'); do
    docker rmi "${t}" > /dev/null 2>&1 || say "could not untag leftover ${t}"
  done
}

cleanup() {
  local c
  for c in "${containers[@]}"; do
    docker rm -f "${c}" > /dev/null 2>&1 || true
  done
  if [[ -n "${built_tag}" && "${ACCEPT_KEEP:-0}" != 1 ]]; then
    # Untag only: an image another tag still names (the live one) stays.
    docker rmi "${built_tag}" > /dev/null 2>&1 || say "could not untag ${built_tag}"
  fi
  if [[ -n "${work}" ]] && ((failures == 0)); then
    rm -rf "${work}"
  fi
}

preflight() { # TAG
  local name="aap-accept-preflight-$$"
  containers+=("${name}")
  if ! docker create --pull=never --runtime=sysbox-runc --init --name "${name}" \
    --entrypoint /opt/aap-runner/ephemeral-entry.sh "$1" --preflight > /dev/null; then
    check preflight fail "docker create"
    return 0
  fi
  if ! "${ACCEPT_MANAGER}" --assert-mounts "${name}"; then
    check mounts fail "--assert-mounts refused the container"
    return 0
  fi
  check mounts ok "no mount under /mnt, with --init"
  if timeout --foreground "${ACCEPT_RUN_TIMEOUT}" docker start --attach "${name}" > "${work}/preflight.log" 2>&1; then
    check preflight ok "inner dockerd under Sysbox and --init"
  else
    check preflight fail "$(tail -n 3 "${work}/preflight.log" | tr '\n' ' ')"
  fi
}

# One temporary container prints key=value facts; nothing in it registers.
probe() { # TAG
  local name="aap-accept-probe-$$"
  containers+=("${name}")
  # shellcheck disable=SC2016
  timeout --foreground "${ACCEPT_RUN_TIMEOUT}" docker run --rm --pull=never --runtime=sysbox-runc --init --name "${name}" \
    --entrypoint /bin/bash "$1" -c '
    echo "pid1=$(cat /proc/1/comm)"
    echo "runner=$(runuser -u runner -- /opt/actions-runner/bin/Runner.Listener --version 2>&1 | head -n 1)"
    echo "node=$(node --version 2>&1)"
    echo "npm=$(npm --version > /dev/null 2>&1 && echo present || echo missing)"
    echo "jq=$(jq --version 2>&1)"
    echo "zccache=$('"${ZC_DIR}"'/bin/zccache --version 2>&1 | head -n 1)"
    echo "sccache=$(command -v sccache || echo absent)"
    echo "sudo=$(id -nG runner | tr " " "\n" | grep -qx sudo && echo member || echo none)"
    install -d -o runner -g runner -m 0700 /tmp/zcroot
    if runuser -u runner -- env -i PATH=/usr/bin:/bin HOME=/home/runner \
      '"${ZC_DIR}"'/aap-zccache.sh init '"${ZC_DIR}"' /tmp/zcroot '"${ZC_PROBE_BUDGET}"' > /dev/null 2>&1; then
      echo "zcstate=$(runuser -u runner -- '"${ZC_DIR}"'/aap-zccache.sh state /tmp/zcroot 2>&1)"
    else
      echo "zcstate=init-failed"
    fi
  ' > "${work}/probe.txt" 2>&1 || true
}

fact() { sed -n "s/^$1=//p" "${work}/probe.txt" | head -n 1; }

expect() { # NAME GOT WANT exact|prefix [DETAIL]
  local name=$1 got=$2 want=$3
  if [[ -n "${want}" && ("$4" == exact && "${got}" == "${want}" || "$4" == prefix && "${got}" == "${want}"*) ]]; then
    check "${name}" ok "${5:-${got}}"
  else
    check "${name}" fail "want '${want}', got '${got}'"
  fi
}

verify() { # CONTEXT [TAG]
  local ctx=$1 tag=${2:-aap-accept:$(date +%Y%m%d%H%M%S)} df
  df=${ctx}/Dockerfile
  [[ -f "${df}" ]] || { echo "refusing: ${ctx} has no Dockerfile" >&2; return 2; }
  [[ "${tag}" =~ ^aap-accept:[a-z0-9._-]+$ ]] || { echo "refusing: tag ${tag} is not aap-accept:<name>" >&2; return 2; }
  if [[ "${ACCEPT_ALLOW_LIVE_POOL:-0}" != 1 ]] && systemctl is-active --quiet aap-runner-manager.service 2> /dev/null; then
    echo "refusing: aap-runner-manager is active; its per-job image prune breaks a build. Drain and let it exit first" >&2
    return 2
  fi
  exec 9> "${ACCEPT_LOCK}"
  flock -n 9 || { echo "refusing: another acceptance run holds ${ACCEPT_LOCK}" >&2; return 2; }
  remove_leftovers
  if [[ -n "$(docker images -q "${tag}")" ]]; then
    echo "refusing: ${tag} already exists" >&2
    return 2
  fi
  work=$(mktemp -d "${ACCEPT_TMP}/aap-accept.XXXXXX")
  trap cleanup EXIT

  built_tag=${tag}
  if ! timeout --foreground "${ACCEPT_BUILD_TIMEOUT}" docker build -q -t "${tag}" "${ctx}" > "${work}/build.log" 2>&1; then
    check build fail "$(tail -n 5 "${work}/build.log" | tr '\n' ' ')"
    say "FAIL (${failures}); log ${work}"
    return 1
  fi
  check build ok "${tag}"

  preflight "${tag}"
  probe "${tag}"
  expect init "$(fact pid1)" docker-init exact "PID 1 is docker-init"
  expect runner "$(fact runner)" "$(dockerfile_pin "${df}" 's/^COPY actions-runner-linux-x64-([0-9.]+)\.tar\.gz .*/\1/p')" exact
  expect node "$(fact node)" "v$(dockerfile_pin "${df}" 's#.*nodejs\.org/dist/v([0-9.]+)/.*#\1#p')" exact
  expect npm "$(fact npm)" present exact
  expect jq "$(fact jq)" jq- prefix
  expect zccache "$(fact zccache)" "zccache $(dockerfile_pin "${df}" 's#.*releases/download/([0-9.]+)/\$\{archive\}.*#\1#p')" exact
  expect sccache "$(fact sccache)" absent exact
  expect sudo "$(fact sudo)" none exact "runner has no sudo"
  expect zccache-init "$(fact zcstate)" '{"state":"direct"' prefix "direct"

  if ((failures > 0)); then
    say "FAIL (${failures}); log ${work}"
    return 1
  fi
  say "PASS"
}

main() {
  case "${1:-}" in
    assemble)
      [[ $# -eq 3 ]] || { echo "usage: $0 assemble SRC CONTEXT" >&2; exit 2; }
      assemble "$2" "$3"
      ;;
    verify)
      [[ $# -ge 2 && $# -le 3 ]] || { echo "usage: $0 verify CONTEXT [TAG]" >&2; exit 2; }
      verify "$2" "${3:-}"
      ;;
    *)
      echo "usage: $0 assemble SRC CONTEXT | verify CONTEXT [TAG]" >&2
      exit 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
