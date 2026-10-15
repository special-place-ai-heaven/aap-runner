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

# --check-token: load_config and check_key run, one token is minted and
# discarded, and the output never carries it.
token_cli() {
  bash -c '
    source "$1"
    marker=$2
    rc=$3
    shift 3
    id() { echo 0; }
    docker() { echo "docker $*" >> "${marker}"; return 99; }
    load_config() { echo load_config >> "${marker}"; }
    check_key() { echo check_key >> "${marker}"; }
    mint_installation_token() { echo "ghs_notasecret_but_must_not_print"; return "${rc}"; }
    main "$@"
  ' _ "${manager}" "${work}/token" "$@" 2>&1
}
rc=0
out=$(token_cli 0 --check-token) || rc=$?
[[ "${rc}" -eq 0 && "${out}" == "app token: ok" ]] || fail "--check-token ok exited ${rc}: ${out}"
[[ "$(cat "${work}/token")" == $'load_config\ncheck_key' ]] || fail "--check-token skipped a check: $(cat "${work}/token")"
rm -f "${work}/token"
rc=0
out=$(token_cli 1 --check-token) || rc=$?
[[ "${rc}" -eq 1 && "${out}" == "app token: failed" ]] || fail "--check-token failure exited ${rc}: ${out}"
[[ "${out}" != *ghs_* ]] || fail "--check-token printed the token"
[[ ! -e "${work}/touched" ]] || fail "--check-token reached docker"
echo "check-token ok"

# AAP_MANAGER_CONF moves the config path for one call (the identity verb's
# pre-swap check); unset, the path is the installed file.
out=$(AAP_MANAGER_CONF=/tmp/x.conf bash -c 'source "$1"; echo "${CONFIG_PATH}"' _ "${manager}")
[[ "${out}" == "/tmp/x.conf" ]] || fail "AAP_MANAGER_CONF ignored: ${out}"
out=$(env -u AAP_MANAGER_CONF bash -c 'source "$1"; echo "${CONFIG_PATH}"' _ "${manager}")
[[ "${out}" == "/etc/aap-runner/manager.conf" ]] || fail "default CONFIG_PATH: ${out}"
echo "config path override ok"

echo "manager cli tests ok"
