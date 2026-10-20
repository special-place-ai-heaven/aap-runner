#!/bin/bash
# linux/go: the default Go (go on PATH) tests, builds and runs a module with cgo, offline (GOPROXY=off,
# GOTOOLCHAIN=local), with its caches in the work folder; the binary is ELF-inspected.
# Sabotage no-gcc runs go with PATH reduced to GOROOT/bin, so cgo's C compiler (gcc) does not resolve.
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"

export GOPROXY=off GOTOOLCHAIN=local GOFLAGS=-mod=mod CGO_ENABLED=1
export GOCACHE="${WORK}/go-cache" GOPATH="${WORK}/gopath" GOMODCACHE="${WORK}/gopath/mod"
run go env GOROOT
goroot=${OUT}
run go version
fact go.version "$(awk '{ print $3 }' <<< "${OUT}")" "go$(oracle versions/go)"
fact go.goroot "${goroot}" "$(oracle env/GOROOT_1_24_X64)"
cp -R "${WL_LIB_DIR}/go/mod" mod
cd mod || die 'no module folder'
if [ "${SABOTAGE}" = no-gcc ]; then
  export PATH="${goroot}/bin"
  line "sabotage no-gcc applied"
  fact sabotage.gcc_on_path "$(command -v gcc)" ''
elif [ -n "${SABOTAGE}" ]; then
  die "unknown sabotage ${SABOTAGE}"
fi
run go test ./...
run go build -trimpath -o app .
run ./app
out=${OUT}
fact app.output "${out}" 'hello from go sum=10 cgo_mul=42'
run python3 -B -I "${WL_LIB_DIR}/wl.py" elf app
mapfile -t elf <<< "${OUT}"
report "app.output=${out}" "${elf[@]/#/elf.}"
wl_end
