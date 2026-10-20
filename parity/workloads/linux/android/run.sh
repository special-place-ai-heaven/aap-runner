#!/bin/bash
# linux/android: the Android SDK and NDK the image installs (variables, NDK, build-tools and platform folders,
# platform-tools and command-line tools revisions), and a C program cross-compiled with the default NDK's clang for
# arm64 (API 24) and ELF-inspected. Nothing runs on a device and sdkmanager is not used (it contacts Google).
# Sabotage missing-ndk points ANDROID_NDK_HOME at an NDK version that is not installed.
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"

rev() { sed -n 's/^Pkg.Revision *= *//p' "$1/source.properties" 2>/dev/null; }
sorted() { printf '%s\n' "$@" | sort; }
if [ -z "${SABOTAGE}" ]; then
  for n in $(oracle_keys android_env); do fact "env.${n}" "$(printenv "${n}")" "$(oracle "android_env/${n}")"; done
  sdk=${ANDROID_HOME:-}
  fact sdk.ndk "$(sorted "$(ls "${sdk}/ndk")")" "$(sorted "$(oracle_list android/ndk)")"
  fact sdk.build_tools "$(sorted "$(ls "${sdk}/build-tools")")" "$(sorted "$(oracle_list android/build_tools)")"
  observe sdk.platforms "$(ls "${sdk}/platforms")"
  fact sdk.platform_tools "$(rev "${sdk}/platform-tools")" "$(oracle android/platform_tools)"
  fact sdk.cmdline_tools "$(rev "${sdk}/cmdline-tools/latest")" "$(oracle android/cmdline_tools)"
  fact ndk.default "$(rev "${ANDROID_NDK_HOME:-}")" "$(oracle android/ndk_default)"
elif [ "${SABOTAGE}" = missing-ndk ]; then
  export ANDROID_NDK_HOME="${ANDROID_HOME:-}/ndk/99.0.0"
  line "sabotage missing-ndk applied"
  fact sabotage.ndk_dir "$([ -e "${ANDROID_NDK_HOME}" ] && echo yes)" ''
else
  die "unknown sabotage ${SABOTAGE}"
fi
[ -n "${ANDROID_NDK_HOME:-}" ] || die 'ANDROID_NDK_HOME is not set'
clang="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang"
[ -x "${clang}" ] || die "NDK clang not found under ANDROID_NDK_HOME: ${clang}"
run "${clang}" -O2 -Wall -Werror "${WL_LIB_DIR}/android/hello.c" -o hello-arm64
run python3 -B -I "${WL_LIB_DIR}/wl.py" elf hello-arm64
mapfile -t elf <<< "${OUT}"
fact ndk.elf "${elf[0]}" 'class=elf64 machine=aarch64 type=dyn'
report "${elf[@]/#/elf.}"
wl_end
