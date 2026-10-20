#!/bin/bash
# linux/gxx14-cxx23: g++-14 (installed beside the default g++) builds and runs C++23 <print> with -std=c++23.
# Sabotage default-gxx builds the same program with the default g++, whose libstdc++ has no <print> (missing compiler
# and standard-library support for a flag the project needs).
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"

cxx=g++-14
if [ "${SABOTAGE}" = default-gxx ]; then
  cxx=g++
  line "sabotage default-gxx applied"
  run g++ -dumpfullversion
  fact sabotage.default_gxx_version "${OUT}" "$(oracle versions/gcc)"
elif [ -n "${SABOTAGE}" ]; then
  die "unknown sabotage ${SABOTAGE}"
else
  run g++-14 -dumpfullversion
  fact g++-14.version "${OUT}" "$(oracle versions/gcc_14)"
fi
run "${cxx}" -std=c++23 -O2 -Wall -Werror "${WL_LIB_DIR}/gcc/src/print.cpp" -o print
run ./print
fact cxx23.output "${OUT}" 'hello from c++23 23'
report "cxx23.output=${OUT}"
wl_end
