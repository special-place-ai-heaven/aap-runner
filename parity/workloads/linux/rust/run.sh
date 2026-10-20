#!/bin/bash
# linux/rust: cargo test, release build and run, offline, with a build script that compiles C with cc and ar from
# PATH and links it statically; the binary is ELF-inspected. CARGO_HOME and the target folder are in the work folder.
# Sabotage no-cc runs cargo with PATH reduced to cargo's own folder, so neither the linker rustc calls (cc) nor the
# build script's C compiler resolves.
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"

cargo=$(command -v cargo) || die 'cargo not found on PATH'
run "${cargo}" --version
fact cargo.version "$(awk '{ print $2 }' <<< "${OUT}")" "$(oracle versions/cargo)"
run rustc --version
fact rustc.version "$(awk '{ print $2 }' <<< "${OUT}")" "$(oracle versions/rustc)"
cp -R "${WL_LIB_DIR}/rust/crate" crate
export CARGO_TARGET_DIR="${WORK}/target" CARGO_TERM_COLOR=never
# rustup's proxies find their toolchains through RUSTUP_HOME, which defaults to the real home
export RUSTUP_HOME=${RUSTUP_HOME:-${HOME}/.rustup} CARGO_HOME="${WORK}/cargo-home"
if [ "${SABOTAGE}" = no-cc ]; then
  export PATH="${cargo%/*}"
  line "sabotage no-cc applied"
  fact sabotage.cc_on_path "$(command -v cc)" ''
elif [ -n "${SABOTAGE}" ]; then
  die "unknown sabotage ${SABOTAGE}"
fi
cd crate || die 'no crate folder'
run "${cargo}" test --offline --release
fact cargo.test "$(grep -c '^test result: ok. 2 passed' <<< "${OUT}")" 1
run "${cargo}" build --offline --release
run "${CARGO_TARGET_DIR}/release/parity_rust"
out=${OUT}
fact app.output "${out}" 'hello from rust sum=10 native_mul=42'
run python3 -B -I "${WL_LIB_DIR}/wl.py" elf "${CARGO_TARGET_DIR}/release/parity_rust"
mapfile -t elf <<< "${OUT}"
report "app.output=${out}" "${elf[@]/#/elf.}"
wl_end
