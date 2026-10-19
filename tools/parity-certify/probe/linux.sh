#!/usr/bin/env bash
# Linux job probe. Runs INSIDE a job (hosted or local) and writes one job-inventory.json.
# Same shape and meaning as `certify.py parse-hosted-log` produces from the hosted capture log, plus a few
# extra facts (dash package version, docker socket, default-version resolution through `command -v`).
# Never dumps the environment: names are fixed below; credential-bearing names are presence only.
#
#   linux.sh --out FILE [--safe] [--runner-version X]
#
# --safe skips Docker (no daemon call) and sudo, and leaves Docker out of `coverage`.
# Run on a real Linux host only; this repository's Windows development host cannot execute it.
set -u

OUT=""
SAFE=0
RUNNER_VERSION_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --safe) SAFE=1; shift ;;
    --runner-version) RUNNER_VERSION_ARG="${2:-}"; shift 2 ;;
    *) echo "linux.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "linux.sh: --out FILE is required" >&2; exit 2; }

# --- JSON helpers (no jq/python dependency) ----------------------------------------------------
export LC_ALL=C  # byte semantics for the escaping below and C-order sorting everywhere
js() { # JSON string of $1; pure bash, no subshell and no external process (matters on slow-fork hosts)
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"; s="${s//$'\n'/\\n}"
  s="${s//[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037']/}"
  printf '"%s"' "$s"
}
jv() { if [ -z "${1:-}" ]; then printf 'null'; else js "$1"; fi; }            # string or null
jn() { if [[ "${1:-}" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; elif [ -z "${1:-}" ]; then printf 'null'; else js "$1"; fi; }
jb() { if [ "$1" = "1" ]; then printf 'true'; else printf 'false'; fi; }
jarr() { # stdin lines -> JSON array of strings
  local first=1 l
  printf '['
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    [ $first -eq 1 ] || printf ','
    first=0
    js "$l"
  done
  printf ']'
}
sub() { local x; x="$("$@" 2>/dev/null | head -n1)"; printf '%s' "$x"; }  # first line of a command, errors dropped

ENV_NAMES="ImageOS ImageVersion AGENT_TOOLSDIRECTORY RUNNER_TOOL_CACHE ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE JAVA_HOME JAVA_HOME_17_X64
GOROOT_1_24_X64 VCPKG_INSTALLATION_ROOT CONDA ANDROID_HOME ANDROID_NDK ANDROID_NDK_HOME ANDROID_NDK_LATEST_HOME ANDROID_NDK_ROOT ANDROID_SDK_ROOT
CHROMEWEBDRIVER EDGEWEBDRIVER GECKOWEBDRIVER SELENIUM_JAR_PATH DOTNET_NOLOGO DOTNET_MULTILEVEL_LOOKUP DOTNET_SKIP_FIRST_TIME_EXPERIENCE
DEBIAN_FRONTEND ACCEPT_EULA XDG_CONFIG_HOME PIPX_BIN_DIR PIPX_HOME NVM_DIR GRADLE_HOME ANT_HOME BAZEL_VERSION USE_BAZEL_FALLBACK_VERSION
HOMEBREW_NO_AUTO_UPDATE CHROME_BIN SWIFT_PATH VCPKG_FORCE_SYSTEM_BINARIES ZCCACHE_DIR"
CRED_NAMES="PGPASSWORD GITHUB_TOKEN ACTIONS_RUNTIME_TOKEN"
SERVICES="docker snapd haveged postgresql mysql apache2 nginx apt-daily.timer apt-daily-upgrade.timer unattended-upgrades"
SYSCTLS="vm.max_map_count fs.inotify.max_user_watches fs.inotify.max_user_instances vm.mmap_rnd_bits"

# --- gather ---------------------------------------------------------------------------------------
LABEL="${AAP_IMAGE_LABEL:-}"
if [ -z "$LABEL" ] && [ -r /imagegeneration/imagedata.json ]; then
  LABEL="$(sed -n 's/.*Image: \([A-Za-z0-9._-]*\).*/\1/p' /imagegeneration/imagedata.json | head -n1)"
fi
. /etc/os-release 2>/dev/null || PRETTY_NAME=""
RUNNER_VER="${RUNNER_VERSION_ARG:-${RUNNER_VERSION:-${AAP_RUNNER_VERSION:-}}}"

# default cached version = first process-PATH entry under <root>/<name>/<ver>/, then the resolved path of a few commands
ROOT="${AGENT_TOOLSDIRECTORY:-}"
declare -A DEFAULTS=()
note_default() { # path
  local p rest n v
  p="${1%/}/"
  case "$p" in "$ROOT"/*) ;; *) return 0 ;; esac
  rest="${p#"$ROOT"/}"
  n="${rest%%/*}"; rest="${rest#*/}"; v="${rest%%/*}"
  [ -n "$n" ] && [ -n "$v" ] && [ -d "$ROOT/$n/$v" ] && [ -z "${DEFAULTS[$n]:-}" ] && DEFAULTS[$n]="$v"
  return 0
}
if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
  IFS=':' read -r -a PATH_ARR <<< "$PATH"
  for p in "${PATH_ARR[@]}"; do note_default "$p"; done
  [ -n "${JAVA_HOME:-}" ] && note_default "$JAVA_HOME/bin"
  for c in go node python3 ruby java; do
    r="$(command -v "$c" 2>/dev/null)" && [ -n "$r" ] && note_default "$(dirname "$(readlink -f "$r")")"
  done
fi

emit() {
  printf '{\n"schema":1,"kind":"job-inventory",\n'
  printf '"source":{"type":"probe","ref":"tools/parity-certify/probe/linux.sh"},\n'
  local cov='"image","infra","run_identity","user","env","credential_env","path","shells","tools","services","hardware","limits","action_archive_cache"'
  [ -n "$ROOT" ] && [ -d "$ROOT" ] && cov="$cov,\"tool_cache\""
  [ $SAFE -eq 0 ] && cov="$cov,\"docker\""
  printf '"coverage":[%s],\n"profile":%s,\n' "$cov" "$(jv "$LABEL")"

  printf '"image":{"label":%s,"image_version":%s,"image_os":%s,"runner_version":%s,"runner_os":%s,"runner_arch":%s,"runner_environment":%s,"os_name":%s,"kernel":%s},\n' \
    "$(jv "$LABEL")" "$(jv "${ImageVersion:-}")" "$(jv "${ImageOS:-}")" "$(jv "$RUNNER_VER")" "$(jv "${RUNNER_OS:-}")" \
    "$(jv "${RUNNER_ARCH:-}")" "$(jv "${RUNNER_ENVIRONMENT:-}")" "$(jv "${PRETTY_NAME:-}")" "$(jv "$(uname -r)")"
  printf '"infra":{"hostname":%s},\n' "$(jv "$(hostname 2>/dev/null | tr 'A-Z' 'a-z')")"
  printf '"run_identity":{"source_sha":%s,"workflow_sha":%s,"action_shas":%s},\n' \
    "$(jv "${GITHUB_SHA:-}")" "$(jv "${GITHUB_WORKFLOW_SHA:-}")" "$(printf '%s' "${AAP_PARITY_ACTION_SHAS:-}" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort | jarr)"

  # --safe never calls sudo, so the answer is unknown (null), not false
  local sudo_json=null
  if [ $SAFE -eq 0 ]; then
    sudo_json="$(jb 0)"
    if command -v sudo >/dev/null 2>&1 && timeout 5 sudo -n true >/dev/null 2>&1; then sudo_json="$(jb 1)"; fi
  fi
  printf '"user":{"name":%s,"uid":%s,"gid":%s,"groups":%s,"passwordless_sudo":%s},\n' \
    "$(jv "$(id -un)")" "$(jn "$(id -u)")" "$(jn "$(id -g)")" "$(id -Gn | tr ' ' '\n' | sort | jarr)" "$sudo_json"

  printf '"env":{'
  local first=1 n v
  for n in $ENV_NAMES; do
    [ $first -eq 1 ] || printf ','
    first=0
    if [ -n "${!n+x}" ]; then v="${!n}"; else v="<unset>"; fi
    printf '%s:%s' "$(js "$n")" "$(js "$v")"
  done
  printf '},\n"credential_env":{'
  first=1
  for n in $CRED_NAMES; do
    [ $first -eq 1 ] || printf ','
    first=0
    if [ -n "${!n+x}" ]; then v=1; else v=0; fi
    printf '%s:%s' "$(js "$n")" "$(jb $v)"
  done
  printf '},\n'

  printf '"path":{"process":%s,"machine":%s},\n' "$(printf '%s' "$PATH" | tr ':' '\n' | jarr)" \
    "$(grep '^PATH=' /etc/environment 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' | tr ':' '\n' | jarr)"

  local pw dashv
  pw="$(sub pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
  dashv="$(dpkg-query -W -f='${Version}' dash 2>/dev/null)"
  printf '"shells":{"bash":%s,"pwsh":%s,"dash":%s},\n' "$(jv "${BASH_VERSION}")" "$(jv "$pw")" "$(jv "$dashv")"

  local py nd dk gc cl sd
  py="$(sub python3 --version | sed 's/^Python //')"
  nd="$(sub node --version | sed 's/^v//')"
  dk=""
  [ $SAFE -eq 0 ] && dk="$(sub docker --version | sed 's/^Docker version \([^,]*\),.*/\1/')"
  gc="$(sub gcc --version | sed 's/.* //')"
  cl="$(sub clang --version | sed 's/.*clang version \([^ ]*\).*/\1/')"
  sd="$(sub systemctl --version | sed -n 's/^systemd [0-9]* (\(.*\))$/\1/p')"
  printf '"tools":{"systemd":%s,"python3":%s,"node":%s,"docker":%s,"gcc":%s,"clang":%s},\n' \
    "$(jv "$sd")" "$(jv "$py")" "$(jv "$nd")" "$(jv "$dk")" "$(jv "$gc")" "$(jv "$cl")"
  printf '"command_paths":{},\n'

  printf '"tool_cache":{"root":%s,"versions":{' "$(jv "$ROOT")"
  first=1
  if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
    local d name
    for d in "$ROOT"/*/; do
      [ -d "$d" ] || continue
      name="$(basename "$d")"
      local vers
      vers="$(for v in "$d"*/; do [ -d "$v" ] && basename "$v"; done | sort)"
      [ -n "$vers" ] || continue
      [ $first -eq 1 ] || printf ','
      first=0
      printf '%s:%s' "$(js "$name")" "$(printf '%s\n' "$vers" | jarr)"
    done
  fi
  printf '},"defaults":{'
  first=1
  for n in "${!DEFAULTS[@]}"; do
    [ $first -eq 1 ] || printf ','
    first=0
    printf '%s:%s' "$(js "$n")" "$(js "${DEFAULTS[$n]}")"
  done
  printf '}},\n'
  printf '"action_archive_cache":%s,\n' "$(ls -A "${ACTIONS_RUNNER_ACTION_ARCHIVE_CACHE:-/opt/actionarchivecache}" 2>/dev/null | sort | jarr)"

  printf '"services":{'
  first=1
  local s en ac
  for s in $SERVICES; do
    en="$(systemctl is-enabled "$s" 2>&1 | head -n1)"
    ac="$(systemctl is-active "$s" 2>&1 | head -n1)"
    [ -n "$en" ] || continue
    [ $first -eq 1 ] || printf ','
    first=0
    printf '%s:{"enabled":%s,"active":%s}' "$(js "$s")" "$(js "$en")" "$(js "$ac")"
  done
  printf '},\n'

  if [ $SAFE -eq 1 ]; then
    printf '"docker":{"skipped":true},\n'
  else
    local dv dc ds sk imgs
    dv="$(sub docker version --format '{{.Client.Version}} {{.Server.Version}}')"
    dc="${dv%% *}"; ds="${dv#* }"; [ "$ds" = "$dv" ] && ds=""
    imgs="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | sort)"
    sk=""
    [ -S /run/docker.sock ] && sk="$(stat -c '%A %U %G' /run/docker.sock 2>/dev/null)"
    printf '"docker":{"client":%s,"server":%s,"images":%s' "$(jv "$dc")" "$(jv "$ds")" "$(printf '%s\n' "$imgs" | jarr)"
    if [ -n "$sk" ]; then
      set -- $sk
      printf ',"socket":{"mode":%s,"owner":%s,"group":%s}' "$(js "$1")" "$(js "$2")" "$(js "$3")"
    fi
    printf '},\n'
  fi

  local mem swap free
  mem="$(awk '/^MemTotal:/{print $2*1024}' /proc/meminfo 2>/dev/null)"
  swap="$(awk '/^SwapTotal:/{print $2*1024}' /proc/meminfo 2>/dev/null)"
  free="$(df -B1 --output=avail / 2>/dev/null | tail -n1 | tr -d ' ')"
  printf '"hardware":{"logical_processors":%s,"memory_bytes":%s,"swap_bytes":%s,"root_disk_free_bytes":%s},\n' \
    "$(jn "$(nproc 2>/dev/null)")" "$(jn "$mem")" "$(jn "$swap")" "$(jn "$free")"

  printf '"limits":{"nofile":%s,"stack":%s,"sysctl":{' "$(jn "$(ulimit -n)")" "$(jn "$(ulimit -s)")"
  first=1
  local k val
  for k in $SYSCTLS; do
    val="$(sysctl -n "$k" 2>/dev/null)" || val="<denied>"
    [ -n "$val" ] || val="<denied>"
    [ $first -eq 1 ] || printf ','
    first=0
    printf '%s:%s' "$(js "$k")" "$(js "$val")"
  done
  printf '},"read_ahead_kb":%s,"mount_options":%s}\n' \
    "$(cat /sys/block/*/queue/read_ahead_kb 2>/dev/null | sort -u | jarr)" "$(jv "$(findmnt --noheadings --output OPTIONS --target / 2>/dev/null)")"
  printf '}\n'
}

mkdir -p "$(dirname "$OUT")"
TMPF="$(mktemp "${OUT}.XXXXXX")" || exit 1
emit > "$TMPF"
mv "$TMPF" "$OUT"
echo "probe: wrote $OUT; label=${LABEL:-<none>} image_version=${ImageVersion:-<unset>} user=$(id -un) uid=$(id -u) docker=$([ $SAFE -eq 1 ] && echo skipped || echo probed)"
