#!/bin/bash
# linux/java: the default JDK found through JAVA_HOME (how setup-java consumers, Maven and Gradle find it) compiles,
# jars and runs a program; every JAVA_HOME_<n>_X64 the image sets runs java -version.
# linux/java-gradle: the image's Gradle builds the same program with only core plugins, --offline and its user home
# in the work folder, and runs the jar. Maven is not driven: its first build downloads plugins.
# Sabotage no-java-home unsets JAVA_HOME; sabotage empty-java-home points it at an empty folder (Gradle's own check).
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"

if [ -z "${SABOTAGE}" ]; then
  fact env.JAVA_HOME "${JAVA_HOME:-}" "$(oracle env/JAVA_HOME)"
fi
export JAVA_TOOL_OPTIONS=-XX:-UsePerfData  # no hsperfdata files in the shared temp folder
case ${SABOTAGE} in
  no-java-home)
    unset JAVA_HOME
    line "sabotage no-java-home applied"
    # the sabotage holds: the JDK is still installed, only the variable is gone
    fact sabotage.jdk_17_installed "$([ -x "${JAVA_HOME_17_X64:-}/bin/javac" ] && echo yes)" yes
    ;;
  empty-java-home) export JAVA_HOME="${WORK}/no-jdk"; mkdir -p "${JAVA_HOME}"; line "sabotage empty-java-home applied" ;;
  '') ;;
  *) die "unknown sabotage ${SABOTAGE}" ;;
esac

if [ "${ARG_tool:-}" = gradle ]; then
  export GRADLE_USER_HOME="${WORK}/gradle-home"
  [ -z "${SABOTAGE}" ] || fact sabotage.java_home_has_java "$([ -x "${JAVA_HOME}/bin/java" ] && echo yes)" ''
  cp -R "${WL_LIB_DIR}/java/gradle" proj
  cd proj || die 'no project folder'
  run gradle --version
  fact gradle.version "$(sed -n 's/^Gradle //p' <<< "${OUT}")" "$(oracle versions/gradle)"
  run gradle --offline --no-daemon --console=plain -q jar
  run "${JAVA_HOME}/bin/java" -jar build/libs/aap-parity.jar
  out=$(grep -v '^Picked up JAVA_TOOL_OPTIONS' <<< "${OUT}")
  fact app.output "${out}" 'hello from java sum=10 amd64=true'
  run python3 -B -I "${WL_LIB_DIR}/wl.py" zip build/libs/aap-parity.jar
  mapfile -t entries <<< "${OUT}"
  report "output=${out}" "${entries[@]/#/jar.entry=}"
  wl_end
fi

[ -n "${JAVA_HOME:-}" ] || die 'JAVA_HOME is not set'
for t in javac jar java; do [ -x "${JAVA_HOME}/bin/${t}" ] || die "${t} not found under JAVA_HOME"; done
if [ -z "${SABOTAGE}" ]; then
  fact env.JAVA_HOME_17_X64 "${JAVA_HOME_17_X64:-}" "$(oracle env/JAVA_HOME_17_X64)"
  for n in $(oracle_list java_home_vars); do
    h=$(printenv "${n}")
    fact "${n}.has_java" "$([ -n "${h}" ] && [ -x "${h}/bin/java" ] && echo yes)" yes
    try_run "${h}/bin/java" -version
    observe "${n}.version" "$(grep -v '^Picked up' <<< "${OUT}" | head -n 1)"
  done
fi
run "${JAVA_HOME}/bin/javac" --release 17 -d classes "${WL_LIB_DIR}/java/src/parity/Main.java"
run "${JAVA_HOME}/bin/jar" --create --file app.jar --main-class parity.Main -C classes .
run "${JAVA_HOME}/bin/java" -jar app.jar
out=$(grep -v '^Picked up JAVA_TOOL_OPTIONS' <<< "${OUT}")
fact app.output "${out}" 'hello from java sum=10 amd64=true'
run python3 -B -I "${WL_LIB_DIR}/wl.py" zip app.jar
mapfile -t entries <<< "${OUT}"
report "output=${out}" "${entries[@]/#/jar.entry=}"
wl_end
