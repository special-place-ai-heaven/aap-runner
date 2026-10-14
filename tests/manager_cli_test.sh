#!/bin/bash
# The argument guard: only no argument starts the pool, which first removes
# every job container. An unknown argument exits 2 and never reaches docker,
# even as root. --version prints the marker the supervisor checks.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
manager="${here}/../distro/manager.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

# cli ARG...: main in a new bash as root, with docker and the config loader
# recording any call. Prints the output; returns main's exit code.
cli() {
  bash -c '
    source "$1"
    marker=$2
    shift 2
    id() { echo 0; }
    docker() { echo "docker $*" >> "${marker}"; return 99; }
    load_config() { echo load_config >> "${marker}"; return 99; }
    main "$@"
  ' _ "${manager}" "${work}/touched" "$@" 2>&1
}

for arg in --bogus --help -x --drain-now --check-limit start; do
  rc=0
  out=$(cli "${arg}") || rc=$?
  [[ "${rc}" -eq 2 ]] || fail "argument ${arg} exited ${rc}; want 2: ${out}"
  [[ "${out}" == "unknown argument: ${arg}" ]] || fail "argument ${arg} printed: ${out}"
  [[ ! -e "${work}/touched" ]] || fail "argument ${arg} reached docker or the config: $(cat "${work}/touched")"
done
echo "unknown argument exits 2 without docker ok"

rc=0
out=$(cli --version) || rc=$?
[[ "${rc}" -eq 0 && "${out}" == "aap-runner-manager 2" ]] || fail "--version exited ${rc}: ${out}"
[[ ! -e "${work}/touched" ]] || fail "--version reached docker or the config"
out=$(bash "${manager}" --version) || fail "--version as a plain user failed"
[[ "${out}" == "aap-runner-manager 2" ]] || fail "--version as a plain user printed: ${out}"
echo "version marker ok"

echo "manager cli tests ok"
