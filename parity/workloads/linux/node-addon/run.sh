#!/bin/bash
# linux/node-addon: a Node-API addon compiled with gcc against the headers of the installed Node.js (what node-gyp
# would otherwise download), loaded by node and ELF-inspected. Node's own version and its npm are checked too.
# Sabotage no-node-headers compiles with an empty folder as Node's include folder.
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"

node=$(command -v node) || die 'node not found on PATH'
run node --version
fact node.version "${OUT}" "v$(oracle versions/node)"
node_real=$(readlink -f "${node}")
inc="${node_real%/bin/node}/include/node"
fact node.headers "$([ -r "${inc}/node_api.h" ] && echo yes)" yes
if [ "${SABOTAGE}" = no-node-headers ]; then
  inc="${WORK}/empty-include"
  mkdir -p "${inc}"
  line "sabotage no-node-headers applied"
  fact sabotage.node_api_h "$([ -e "${inc}/node_api.h" ] && echo yes)" ''
elif [ -n "${SABOTAGE}" ]; then
  die "unknown sabotage ${SABOTAGE}"
fi
run gcc -O2 -Wall -Werror -fPIC -shared -DNODE_GYP_MODULE_NAME=parity -I"${inc}" "${WL_LIB_DIR}/node-addon/addon.c" -o addon.node
run node "${WL_LIB_DIR}/node-addon/test.js" "${WORK}/addon.node"
out=${OUT}
fact addon.output "${out}" 'hello from a node-api addon'
run python3 -B -I "${WL_LIB_DIR}/wl.py" elf addon.node
mapfile -t elf <<< "${OUT}"
report "addon.output=${out}" "${elf[@]/#/elf.}"
wl_end
