#!/bin/bash
# linux/toolchain-versions: the version every build tool on PATH reports equals the inventory (compilers side by
# side, Rust, Go, Node/npm/Yarn, Python/pip, Java, Maven, Gradle, Ant, the .NET SDK set, PowerShell, bash, Git, Git
# LFS, Perl, Ruby, yq). Facts only, no report.
# Sabotage no-cargo-bin removes ~/.cargo/bin from PATH (where rustup puts rustc and cargo).
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"
# the version queries write nothing outside the work folder
export GRADLE_USER_HOME="${WORK}/gradle-home" DOTNET_CLI_HOME="${WORK}/dotnet-home" JAVA_TOOL_OPTIONS=-XX:-UsePerfData

# check KEY SED-EXPR CMD...: the tool's output, filtered by sed -n -E 'EXPR', equals oracle versions/KEY
check() {
  local key=$1 expr=$2
  shift 2
  try_run "$@"
  fact "version.${key}" "$(sed -n -E "${expr}" <<< "${OUT}" | head -n 1)" "$(oracle "versions/${key}")"
}
num='s/^[^0-9]*([0-9]+(\.[0-9]+)+).*/\1/p'
if [ "${SABOTAGE}" = no-cargo-bin ]; then
  PATH=$(tr ':' '\n' <<< "${PATH}" | grep -v '/\.cargo/bin$' | paste -sd: -)
  export PATH
  line "sabotage no-cargo-bin applied"
  fact sabotage.rustc_on_path "$(command -v rustc)" ''
elif [ -n "${SABOTAGE}" ]; then
  die "unknown sabotage ${SABOTAGE}"
fi
check rustc "${num}" rustc --version
check cargo "${num}" cargo --version
check rustup "${num}" rustup --version
check gcc_12 '/./p' gcc-12 -dumpfullversion
check gcc_14 '/./p' gcc-14 -dumpfullversion
check clang_16 "${num}" clang-16 --version
check clang_17 "${num}" clang-17 --version
check go 's/^go version go([0-9.]+) .*/\1/p' go version
check node 's/^v//p' node --version
check npm '/./p' npm --version
check yarn '/./p' yarn --version
check python "${num}" python3 --version
check pip "${num}" pip --version
check java 's/.*\(build ([0-9.+]+)\).*/\1/p' java -version
check maven "${num}" mvn -v
check gradle 's/^Gradle ([0-9.]+)$/\1/p' gradle --version
check ant 's/.*version ([0-9.]+) .*/\1/p' ant -version
check pwsh "${num}" pwsh --version
check bash '/./p' bash -c 'echo "${BASH_VERSION}"'
check git "${num}" git --version
check git_lfs 's#^git-lfs/([0-9.]+) .*#\1#p' git lfs version
check perl 's/^v//p' perl -e 'print $^V'
check ruby "${num}" ruby --version
check yq "${num}" yq --version
try_run dotnet --list-sdks
fact version.dotnet_sdks "$(awk '{ print $1 }' <<< "${OUT}" | sort -V)" "$(oracle_list versions/dotnet_sdks | sort -V)"
wl_end
