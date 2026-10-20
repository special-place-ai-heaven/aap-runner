#!/bin/bash
# linux/dotnet-*: .NET SDK build, run, framework-dependent publish (apphost) and pack (nupkg) with no package source,
# so every targeting, host and runtime pack must already be installed. global.json selects the SDK feature band.
# Sabotage missing-targeting-pack targets net7.0, whose targeting pack the profile does not install.
# shellcheck source-path=SCRIPTDIR source=../lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
wl_start "$@"

tfm=${ARG_tfm:-} band=${ARG_sdk_band:-}
export DOTNET_CLI_HOME="${WORK}/dotnet-home" NUGET_PACKAGES="${WORK}/nuget-packages" DOTNET_CLI_TELEMETRY_OPTOUT=1 \
  DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 MSBUILDDISABLENODEREUSE=1
if [ "${SABOTAGE}" = missing-targeting-pack ]; then
  tfm=net7.0
  line "sabotage missing-targeting-pack applied (net7.0)"
elif [ -n "${SABOTAGE}" ]; then
  die "unknown sabotage ${SABOTAGE}"
fi
cp -R "${WL_LIB_DIR}/dotnet/app" app
cd app || die 'no app folder'
sed -i "s/@TFM@/${tfm}/" ParityApp.csproj
printf '{ "sdk": { "version": "%s", "rollForward": "latestFeature" } }\n' "${band}" > global.json
run dotnet --version
sdk=${OUT##*$'\n'}
fact_re dotnet.sdk_band "${sdk}" "^${band%.*}\."
[ -n "${SABOTAGE}" ] || fact dotnet.sdk_in_baseline "$(oracle_list versions/dotnet_sdks | grep -cxF "${sdk}")" 1
common=(-c Release -nodeReuse:false -p:UseSharedCompilation=false)
run dotnet build "${common[@]}"
run dotnet run -c Release --no-build
run_out=${OUT}
run dotnet publish -o pub "${common[@]}"
run ./pub/ParityApp
pub_out=${OUT}
run dotnet pack -o pkg --no-build "${common[@]}"
want='hello from dotnet sum=10 x64=True linux=True'
fact dotnet.run.output "${run_out}" "${want}"
fact publish.apphost.output "${pub_out}" "${want}"
run python3 -B -I "${WL_LIB_DIR}/wl.py" elf pub/ParityApp
mapfile -t elf <<< "${OUT}"
run python3 -B -I "${WL_LIB_DIR}/wl.py" zip pkg/Aap.Parity.App.1.0.0.nupkg
# the core-properties part name is random per pack; keep its folder
mapfile -t entries < <(sed -E 's#/[0-9a-f]{32}\.psmdcp$#/<id>.psmdcp#' <<< "${OUT}")
fact pack.contains_dll "$(printf '%s\n' "${entries[@]}" | grep -cx "lib/${tfm}/ParityApp.dll")" 1
report "tfm=${tfm}" "run.output=${run_out}" "apphost.output=${pub_out}" "${elf[@]/#/apphost.}" "${entries[@]/#/nupkg.entry=}"
wl_end
