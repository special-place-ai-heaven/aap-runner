#!/bin/bash
# linux/containers: Docker and Podman as the image ships them, without pulling anything. Versions (client, server,
# Buildx, Compose, Podman), the daemon's OS and the cached images; then a FROM-scratch image holding a static binary
# is built and run: a plain run, a bind-mounted workspace written from the container (what a container job does), and
# a service container on a user network with a network alias, a health check and a published port (what services:
# do), reached from the host and from a second container by its alias. Runs only inside an Actions job; everything
# it creates is removed at the end.
# Sabotage no-daemon points DOCKER_HOST at a socket that does not exist.
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"
require_actions

tag="aap-parity-${GITHUB_RUN_ID:-0}-$$"
img="localhost/aap-parity-scratch:${tag}"
wl_cleanup() {
  docker rm -f "${tag}-svc" > /dev/null 2>&1
  docker network rm "${tag}-net" > /dev/null 2>&1
  docker rmi -f "${img}" > /dev/null 2>&1
  podman rmi -f "${img}" > /dev/null 2>&1
  return 0
}
if [ "${SABOTAGE}" = no-daemon ]; then
  export DOCKER_HOST="unix://${WORK}/no-docker.sock"
  line "sabotage no-daemon applied"
  fact sabotage.socket_exists "$([ -e "${WORK}/no-docker.sock" ] && echo yes)" ''
elif [ -n "${SABOTAGE}" ]; then
  die "unknown sabotage ${SABOTAGE}"
fi
run docker version --format '{{.Client.Version}} {{.Server.Version}} {{.Server.Os}}'
read -r client server os <<< "${OUT}"
fact docker.client "${client}" "$(oracle versions/docker_client)"
fact docker.server "${server}" "$(oracle versions/docker_server)"
fact docker.server_os "${os}" linux
run docker buildx version
fact buildx.version "$(awk '{ print $2 }' <<< "${OUT}")" "v$(oracle versions/buildx)"
run docker compose version --short
fact compose.version "${OUT}" "$(oracle versions/compose)"
run docker info --format '{{.CgroupVersion}} {{.Driver}}'
observe docker.cgroup_driver "${OUT}"
run docker images --format '{{.Repository}}:{{.Tag}}'
fact docker.cached_images "$(sort <<< "${OUT}")" "$(oracle_list docker_images | sort)"

mkdir -p ctx ws
run gcc -static -O2 -Wall -Werror "${WL_LIB_DIR}/containers/srv.c" -o ctx/srv
cp "${WL_LIB_DIR}/containers/Dockerfile" ctx/
run docker build --network none -t "${img}" ctx
run docker run --rm --network none "${img}" hello
hello=${OUT}
fact container.hello "${hello}" 'hello from a scratch container uid=0'
run docker run --rm --network none -v "${WORK}/ws:/ws" "${img}" write /ws/out.txt
written=$(cat ws/out.txt)
fact container_job.workspace_write "${written}" container-wrote
fact container_job.file_owner_uid "$(stat -c %u ws/out.txt)" 0
run docker network create "${tag}-net"
run docker run -d --name "${tag}-svc" --network "${tag}-net" --network-alias parity-svc -p 127.0.0.1::8080 "${img}" serve 8080
health=''
for _ in $(seq 60); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "${tag}-svc" 2> /dev/null)
  [ "${health}" = healthy ] && break
  sleep 1
done
fact service.health "${health}" healthy
run docker port "${tag}-svc" 8080/tcp
port=${OUT##*:}
run gcc -O2 -Wall -Werror "${WL_LIB_DIR}/containers/srv.c" -o srv-host
run ./srv-host fetch 127.0.0.1 "${port}"
fact service.from_host "${OUT}" service-ok
run docker run --rm --network "${tag}-net" "${img}" fetch parity-svc 8080
fact service.by_alias "${OUT}" service-ok

run podman --version
fact podman.version "$(awk '{ print $3 }' <<< "${OUT}")" "$(oracle versions/podman)"
try_run podman build --network none -t "${img}" ctx
try_run podman run --rm --network none "${img}" hello
fact podman.hello "${OUT}" 'hello from a scratch container uid=0'
report "container.hello=${hello}" "container_job.workspace_write=${written}" "service.health=${health}" \
  "service.by_alias=service-ok" "podman.hello=${OUT}"
wl_end
