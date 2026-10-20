#!/bin/bash
# xwin/*: Linux-to-Windows cross builds with the image's clang and LLVM lld-link. The result is a PE file, its
# inspection (machine, subsystem, imports) and a hand-off record (handoff.py built) that says windows_execution
# 'not-claimed': cross compilation never certifies Windows execution. Only Invoke-HandoffExecution.ps1 on a Windows
# machine, checked with handoff.py verdict, does.
#   --kind freestanding  no C runtime and no SDK: kernel32 imports from an import library made with llvm-lib /def
#   --kind sdk           the Microsoft CRT and Windows SDK as xwin lays them out under $XWIN_SYSROOT
#                        (crt/include, crt/lib/x86_64, sdk/include/{ucrt,um,shared}, sdk/lib/{ucrt,um}/x86_64)
# Sabotage no-import-lib links the freestanding program without its import library; sabotage no-sysroot unsets
# XWIN_SYSROOT.
# shellcheck source-path=SCRIPTDIR source=../linux/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../linux/lib.sh"
wl_start "$@"

src="${REPO}/parity/workloads/xwin/src"
clang=$(command -v clang) || die 'clang not found on PATH'
llvm=$(dirname "$(readlink -f "${clang}")")
for t in lld-link llvm-lib clang-cl; do
  fact "tool.${t}" "$([ -x "${llvm}/${t}" ] && echo yes)" yes
done
case ${ARG_kind:-} in
  freestanding)
    name=parity-freestanding exit_code=42 stdout='hello from xwin freestanding'
    run "${clang}" --target=x86_64-pc-windows-msvc -O2 -ffreestanding -fno-builtin -fno-stack-protector \
      -c "${src}/freestanding.c" -o freestanding.obj
    if [ "${SABOTAGE}" = no-import-lib ]; then
      line "sabotage no-import-lib applied"
      fact sabotage.import_lib "$([ -e kernel32.lib ] && echo yes)" ''
    elif [ -n "${SABOTAGE}" ]; then
      die "unknown sabotage ${SABOTAGE}"
    else
      run "${llvm}/llvm-lib" /nologo /machine:x64 "/def:${src}/kernel32.def" /out:kernel32.lib
    fi
    run "${llvm}/lld-link" /nologo /brepro /subsystem:console /entry:parity_entry /nodefaultlib \
      freestanding.obj kernel32.lib "/out:${name}.exe"
    ;;
  sdk)
    name=parity-sdk exit_code=43 stdout='hello from xwin sdk tick=1'
    if [ "${SABOTAGE}" = no-sysroot ]; then
      unset XWIN_SYSROOT
      line "sabotage no-sysroot applied"
    elif [ -n "${SABOTAGE}" ]; then
      die "unknown sabotage ${SABOTAGE}"
    fi
    x=${XWIN_SYSROOT:-}
    [ -n "${x}" ] || die 'XWIN_SYSROOT is not set (no xwin Windows CRT/SDK sysroot on this machine)'
    for d in crt/include crt/lib/x86_64 sdk/include/ucrt sdk/include/um sdk/include/shared sdk/lib/ucrt/x86_64 sdk/lib/um/x86_64; do
      [ -d "${x}/${d}" ] || die "xwin sysroot ${x} has no ${d}"
    done
    run "${llvm}/clang-cl" --target=x86_64-pc-windows-msvc -fuse-ld=lld-link /nologo /O2 \
      /imsvc "${x}/crt/include" /imsvc "${x}/sdk/include/ucrt" /imsvc "${x}/sdk/include/um" /imsvc "${x}/sdk/include/shared" \
      "${src}/hello.c" "/Fe${name}.exe" /link /brepro "/libpath:${x}/crt/lib/x86_64" \
      "/libpath:${x}/sdk/lib/ucrt/x86_64" "/libpath:${x}/sdk/lib/um/x86_64"
    ;;
  *) die "unknown --kind ${ARG_kind:-}" ;;
esac
run python3 -B -I "${WL_LIB_DIR}/wl.py" pe "${name}.exe"
mapfile -t pe <<< "${OUT}"
fact pe.header "${pe[0]}" 'machine=x64 subsystem=console dll=False'
fact pe.imports_kernel32 "$(printf '%s\n' "${pe[@]}" | grep -cx 'import=kernel32.dll')" 1
run python3 -B -I "${REPO}/parity/workloads/xwin/handoff.py" built "${name}.exe" "${exit_code}" "${stdout}" "${name}.handoff.json"
fact handoff.windows_execution "$(grep -c '"windows_execution": "not-claimed"' "${name}.handoff.json")" 1
report "${pe[@]/#/pe.}" "expected_exit=${exit_code}" "expected_stdout=${stdout}" 'windows_execution=not-claimed'
wl_end
