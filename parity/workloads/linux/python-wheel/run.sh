#!/bin/bash
# linux/python-wheel: a CPython extension compiled with gcc against the default python3's headers, packed into a
# wheel that requires a second (pure) wheel, installed offline with pip --no-index --find-links into a target folder
# and imported. No package index is ever contacted.
# Sabotage no-dep-wheel leaves the required wheel out of the local package folder (what an unreachable or incomplete
# package registry looks like).
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"

export PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1 PIP_NO_INPUT=1
run python3 --version
fact python3.version "${OUT}" "Python $(oracle versions/python)"
run python3 -m pip --version
fact pip.version "$(awk '{ print $2 }' <<< "${OUT}")" "$(oracle versions/pip)"
run python3 -c 'import sysconfig; print(sysconfig.get_paths()["include"]); print(sysconfig.get_config_var("EXT_SUFFIX"))'
inc=${OUT%%$'\n'*} suffix=${OUT##*$'\n'}
fact python3.headers "$([ -r "${inc}/Python.h" ] && echo yes)" yes
run gcc -O2 -Wall -Werror -fPIC -shared -I"${inc}" "${WL_LIB_DIR}/python-wheel/parity_ext.c" -o "parity_ext${suffix}"
run python3 -B -I "${WL_LIB_DIR}/wl.py" wheel "parity_ext${suffix}" wheels aap_parity_ext aap-parity-dep
run python3 -B -I "${WL_LIB_DIR}/wl.py" wheel - wheels aap_parity_dep ''
if [ "${SABOTAGE}" = no-dep-wheel ]; then
  rm -f wheels/aap_parity_dep-*.whl
  line "sabotage no-dep-wheel applied"
  fact sabotage.dep_wheels "$(find wheels -name 'aap_parity_dep-*.whl' | wc -l)" 0
  fact sabotage.ext_wheels "$(find wheels -name 'aap_parity_ext-*.whl' | wc -l)" 1
elif [ -n "${SABOTAGE}" ]; then
  die "unknown sabotage ${SABOTAGE}"
fi
run python3 -m pip install --no-index --find-links wheels --target site aap_parity_ext
run python3 -B "${WL_LIB_DIR}/python-wheel/check.py" "${WORK}/site"
out=${OUT}
fact import.output "${out}" 'parity_ext.add(2, 3) = 5 dep=dep-ok'
run python3 -B -I "${WL_LIB_DIR}/wl.py" zip wheels/aap_parity_ext-*.whl
# the extension's file name carries the interpreter version (EXT_SUFFIX); the report carries no versions
mapfile -t entries <<< "${OUT//"parity_ext${suffix}"/parity_ext<EXT_SUFFIX>}"
report "import.output=${out}" "${entries[@]/#/wheel.entry=}"
wl_end
