#!/bin/bash
# linux/cmake-ninja, linux/cmake-make: CMake configure, build, ctest and cpack (TGZ) with the Ninja and the Unix
# Makefiles generators and the default C/C++ compilers; the package is read back.
# Sabotage no-ninja runs CMake (by its full path) with PATH set to an empty folder, so no ninja resolves.
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"

case ${ARG_generator:-} in
  ninja) gen=Ninja ;;
  make) gen='Unix Makefiles' ;;
  *) die "unknown --generator ${ARG_generator:-}" ;;
esac
cmake=$(command -v cmake) || die 'cmake not found on PATH'
ctest=$(command -v ctest) cpack=$(command -v cpack)
run "${cmake}" --version
fact cmake.version "$(head -n 1 <<< "${OUT}")" "cmake version $(oracle versions/cmake)"
if [ "${SABOTAGE}" = no-ninja ]; then
  mkdir -p "${WORK}/empty-bin"
  export PATH="${WORK}/empty-bin"
  line "sabotage no-ninja applied"
  fact sabotage.ninja_on_path "$(command -v ninja)" ''
elif [ -n "${SABOTAGE}" ]; then
  die "unknown sabotage ${SABOTAGE}"
elif [ "${gen}" = Ninja ]; then
  run ninja --version
  fact ninja.version "${OUT}" "$(oracle versions/ninja)"
fi
run "${cmake}" -S "${WL_LIB_DIR}/cmake/src" -B build -G "${gen}" -DCMAKE_BUILD_TYPE=Release
run "${cmake}" --build build
run "${ctest}" --test-dir build --output-on-failure
fact ctest.passed "$(grep -c '^100% tests passed, 0 tests failed out of 1$' <<< "${OUT}")" 1
run ./build/app
app=${OUT}
fact app.output "${app}" 'parity_add(2, 3) = 5'
cd build || die 'no build folder'
run "${cpack}"
cd "${WORK}" || die 'cannot return to the work folder'
run python3 -B -I "${WL_LIB_DIR}/wl.py" tar build/aap-parity.tar.gz
fact cpack.has_app "$(grep -cx 'aap-parity/bin/app' <<< "${OUT}")" 1
mapfile -t entries <<< "${OUT}"
report "app.output=${app}" "${entries[@]/#/tgz.entry=}"
wl_end
