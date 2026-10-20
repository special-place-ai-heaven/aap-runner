#!/bin/bash
# linux/gcc, linux/clang: C (libm, pthreads, OpenSSL from libssl-dev), a static and a shared library (rpath $ORIGIN)
# and C++17 with libstdc++, built with -Wall -Werror, run and inspected (ELF machine, type, DT_NEEDED).
# --cc gcc uses gcc/g++ and GNU ld; --cc clang uses clang/clang++ (default version) and LLVM lld (-fuse-ld=lld).
# Sabotage no-openssl-headers compiles against a sysroot that has every /usr/include entry except OpenSSL's (what a
# missing libssl-dev looks like). Sabotage no-lld gives clang an lld path that does not exist.
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"

src="${WL_LIB_DIR}/gcc/src"
case ${ARG_cc:-} in
  gcc) cc=gcc cxx=g++ ld=() ver=-dumpfullversion ;;
  clang) cc=clang cxx=clang++ ld=(-fuse-ld=lld) ver=-dumpversion ;;
  *) die "unknown --cc ${ARG_cc:-}" ;;
esac
run "${cc}" "${ver}"
fact "${cc}.version" "${OUT}" "$(oracle "versions/${cc}")"
run "${cxx}" "${ver}"
fact "${cxx}.version" "${OUT}" "$(oracle "versions/${cc}")"

sysroot=()
case ${SABOTAGE} in
  no-openssl-headers)
    s="${WORK}/sysroot"
    mkdir -p "${s}/usr/include/x86_64-linux-gnu"
    for e in /usr/include/* /usr/include/x86_64-linux-gnu/*; do
      [ "${e##*/}" = openssl ] || [ "${e}" = /usr/include/x86_64-linux-gnu ] || ln -s "${e}" "${s}${e}"
    done
    sysroot=(--sysroot="${s}")
    line "sabotage no-openssl-headers applied"
    # the sabotage holds: the sysroot still has the C library headers, the host still has OpenSSL's
    fact sabotage.sysroot_has_stdio_h "$([ -r "${s}/usr/include/stdio.h" ] && echo yes)" yes
    fact sabotage.sysroot_has_openssl "$([ -e "${s}/usr/include/openssl" ] || [ -e "${s}/usr/include/x86_64-linux-gnu/openssl" ] && echo yes)" ''
    fact sabotage.host_has_openssl_evp_h "$([ -r /usr/include/openssl/evp.h ] && echo yes)" yes
    ;;
  no-lld)
    ld=(--ld-path="${WORK}/no-lld/ld.lld")
    line "sabotage no-lld applied"
    fact sabotage.ld_path_exists "$([ -e "${WORK}/no-lld/ld.lld" ] && echo yes)" ''
    ;;
  '') ;;
  *) die "unknown sabotage ${SABOTAGE}" ;;
esac

flags=(-O2 -Wall -Wextra -Werror)
run "${cc}" "${flags[@]}" "${sysroot[@]}" -c "${src}/hello.c" -o hello.o
run "${cc}" "${ld[@]}" hello.o -o hello -lcrypto -lm -pthread
run ./hello
c_out=${OUT}
run "${cc}" "${flags[@]}" -c "${src}/parity.c" -o parity.o
run ar rcs libparity_static.a parity.o
run "${cc}" "${flags[@]}" -fPIC -shared -Wl,-soname,libparity.so "${ld[@]}" "${src}/parity.c" -o libparity.so
run "${cc}" "${flags[@]}" "${ld[@]}" "${src}/use_lib.c" libparity_static.a -o use_static
run ./use_static
static_out=${OUT}
run "${cc}" "${flags[@]}" "${ld[@]}" "${src}/use_lib.c" -L. -lparity '-Wl,-rpath,$ORIGIN' -o use_shared
run ./use_shared
shared_out=${OUT}
run "${cxx}" "${flags[@]}" -std=c++17 -pthread "${ld[@]}" "${src}/hello.cpp" -o hellocpp
run ./hellocpp
cxx_out=${OUT}

fact c.output "${c_out}" 'hello from c cos=1 thread=42 sha256=65966f0faeeff2d783a9e9766d96bafb9ce7ea133ccabd263106f6d7ff1ddd14'
fact static.output "${static_out}" 'parity_add(2, 3) = 5'
fact shared.output "${shared_out}" 'parity_add(2, 3) = 5'
fact cxx.output "${cxx_out}" 'hello from c++ sorted=1234 sum=10'
lines=("c.output=${c_out}" "static.output=${static_out}" "shared.output=${shared_out}" "cxx.output=${cxx_out}")
for f in hello use_shared hellocpp libparity.so; do
  run python3 -B -I "${WL_LIB_DIR}/wl.py" elf "${f}"
  while IFS= read -r l; do lines+=("${f}.${l}"); done <<< "${OUT}"
done
fact c.needs_libcrypto "$(grep -c '^hello.needed=libcrypto.so.3$' <<< "$(printf '%s\n' "${lines[@]}")")" 1
report "${lines[@]}"
wl_end
