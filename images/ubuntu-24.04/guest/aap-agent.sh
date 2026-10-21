#!/bin/bash
# P07 guest agent: answers one request from the host per hvsocket connection and exits. It runs as root, started by the
# systemd socket unit aap-agent.socket (ListenStream=vsock::5223, Accept=yes) with the connection as stdin and stdout.
# The build guest gets it from the host-built seed (cloud-init write_files); deprovision removes it, its units and its state
# (the token included) before sealing and the seal check refuses an image with any of them left, and the verification and
# scan guests get their own copy from their own seed. The scanner's seed also holds the build token to look for ($ROOT/known).
# The channel has no sequence number or nonce: every connection is host-initiated and token-gated, one request each.
#
# Wire format, host to guest: one header line, then exactly <length> payload bytes.
#   aap1 <token> <verb> <name> <length>
#     token   64 hex, compared with $ROOT/token (written by the seed, root 0600); anything else ends the connection
#     verb    ready | bootid | put | get | run | reboot
#     name    file name for put and get ([A-Za-z0-9._-], no leading dot), else -
#     length  payload bytes: put up to 1 GiB, run up to 64 KiB, else 0
# Guest to host: get streams the file; every other verb writes one line (run: one JSON object of fixed fields, printable
# ASCII). The host treats every byte that comes back as hostile: size-capped while received and validated.
# Nothing here runs host-supplied code: run executes upstream scripts only after their SHA-256 matches the pinned value the
# request carries, and named actions only. Script output goes to $ROOT/logs, never to the reply.
set -u
export LC_ALL=C
umask 022
ROOT=${AAP_AGENT_ROOT:-/var/lib/aap-build}
S=${AAP_SYSROOT:-}   # tests only: a fake system root for the seal steps; empty in a guest
PUT_MAX=1073741824
RUN_MAX=65536
SEAL_RULES='install-user-absent no-password-hash no-authorized-keys no-ssh-host-keys no-agent no-cloud-state no-build-sudoers'

# --- reply helpers ---------------------------------------------------------------------------------------------------
printable() { # $1 -> printable ASCII, at most $2 characters
  local s="${1//[^[:print:]]/?}"
  s="${s//[^ -~]/?}"
  printf '%s' "${s:0:${2:-400}}"
}
js() { # JSON string of a printable value
  local s
  s=$(printable "$1" "${2:-400}")
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf '"%s"' "${s}"
}
jlist() { # JSON array of the words in $1
  local first=1 w
  printf '['
  for w in $1; do
    [ "${first}" = 1 ] || printf ','
    first=0
    js "${w}"
  done
  printf ']'
}
reply() { # phase status message [scripts-json] [data-json]
  printf '{"schema":1,"phase":%s,"status":%s,"message":%s' "$(js "$1" 16)" "$(js "$2" 16)" "$(js "$3" 400)"
  [ -z "${4:-}" ] || printf ',"scripts":%s' "$4"
  [ -z "${5:-}" ] || printf ',"data":%s' "$5"
  printf '}\n'
}

# --- request -------------------------------------------------------------------------------------------------------
# key=value lines written by the host. Unknown keys or malformed values fail the request.
declare -A R=()
declare -a ENVS=() SCRIPTS=() VARS_K=() VARS_V=()
parse_request() {
  local line k v
  R=(); ENVS=(); SCRIPTS=(); VARS_K=(); VARS_V=()
  while IFS= read -r line || [ -n "${line}" ]; do
    [ -n "${line}" ] || continue
    [[ ${line} =~ ^([a-z_]{1,20})=([ -~]{0,400})$ ]] || return 1
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
    case "${k}" in
      schema|phase|kind|action|exec|pause_before|timeout)
        [[ -z ${R[${k}]+x} ]] || return 1
        R[${k}]=${v} ;;
      env)
        [[ ${v} =~ ^[A-Z0-9_]{1,40}=[A-Za-z0-9_./:+-]{0,200}$ ]] || return 1   # check:agent-env
        ENVS+=("${v}") ;;
      script)
        [[ ${v} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}\.(sh|ps1)\ [0-9a-f]{64}$ ]] || return 1   # check:agent-script
        SCRIPTS+=("${v}") ;;
      var)
        [[ ${v} =~ ^([a-z_]{1,40})=([A-Za-z0-9_./:+-]{0,200})$ ]] || return 1   # check:agent-var
        VARS_K+=("${BASH_REMATCH[1]}"); VARS_V+=("${BASH_REMATCH[2]}") ;;
      *) return 1 ;;   # check:agent-request-key
    esac
  done < "$1"
  [ "${R[schema]:-}" = 1 ] || return 1
  [[ ${R[phase]:-} =~ ^(p[0-9]{2}|verify|scan)$ ]] || return 1   # check:agent-phase
  [[ ${R[pause_before]:-0} =~ ^[0-9]{1,5}$ ]] || return 1
  [[ ${R[timeout]:-0} =~ ^[0-9]{1,6}$ ]] || return 1
  return 0
}
var() { # value of plan variable $1
  local i
  for i in "${!VARS_K[@]}"; do
    if [ "${VARS_K[${i}]}" = "$1" ]; then printf '%s' "${VARS_V[${i}]}"; return 0; fi
  done
  return 1
}
# The VAR='value' prefix Packer puts before the script ({{ .Vars }}); values are restricted to [A-Za-z0-9_./:+-].
env_prefix() {
  local e out=''
  for e in "${ENVS[@]+"${ENVS[@]}"}"; do out+="${e%%=*}='${e#*=}' "; done
  printf '%s' "${out}"
}

# --- running upstream code -------------------------------------------------------------------------------------------
# How Packer ran a provisioner (execute_command in the template) over SSH as the build user: root through sudo, root through
# pwsh, or as the build user. That session had the system locale (C.UTF-8) and /etc/environment from PAM; sudo then reset the
# environment and set SUDO_USER to the build user. The agent runs as root under systemd with LC_ALL=C, so it puts back what
# a provisioner could see: the locale, /etc/environment for the build user, the SUDO_* variables for root.
run_as() { # exec command-string log -> exit code
  local rc=0 user uid gid
  user=$(var install_user) || return 97
  uid=$(id -u "${user}" 2> /dev/null) || uid=''
  gid=$(id -g "${user}" 2> /dev/null) || gid=''
  case "$1" in
    root|root-pwsh) env -u LC_ALL LANG=C.UTF-8 sudo sh -c "export SUDO_USER=${user} SUDO_UID=${uid} SUDO_GID=${gid}; $2" > "$3" 2>&1 || rc=$? ;;
    user)
      (cd "${S}/home/${user}" 2>/dev/null || cd / || exit 97
       env -u LC_ALL LANG=C.UTF-8 sudo -H -u "${user}" sh -c "set -a; [ ! -r ${S}/etc/environment ] || . ${S}/etc/environment; set +a; $2") > "$3" 2>&1 || rc=$? ;;
    *) return 98 ;;
  esac
  return "${rc}"
}

run_scripts() {
  local entry name want path have code start list='' first=1 rc
  local exec=${R[exec]:-}
  case "${exec}" in root|root-pwsh|user) ;; *) reply "${R[phase]}" failed "exec ${exec}"; return ;; esac
  [ "${R[pause_before]:-0}" = 0 ] || sleep "${R[pause_before]}"
  mkdir -p "${ROOT}/run" "${ROOT}/logs"
  for entry in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    name=${entry% *}; want=${entry#* }
    if [ ! -f "${ROOT}/src/images/ubuntu/scripts/build/${name}" ]; then
      reply "${R[phase]}" failed "${name} is not in the staged sources" "[${list}]"; return
    fi
    path="${ROOT}/run/${name}"
    rm -f "${path}"
    cp "${ROOT}/src/images/ubuntu/scripts/build/${name}" "${path}"
    chmod 0755 "${path}"
    have=$(sha256sum "${path}" | cut -d' ' -f1)
    [ "${have}" = "${want}" ] || { reply "${R[phase]}" failed "${name} SHA-256 differs from the plan; not run" "[${list}]"; return; }   # check:agent-hash
    start=${SECONDS}
    rc=0
    if [ "${exec}" = root-pwsh ]; then
      run_as "${exec}" "$(env_prefix)pwsh -f ${path}" "${ROOT}/logs/${R[phase]}-${name}.log" || rc=$?
    else
      run_as "${exec}" "$(env_prefix)${path}" "${ROOT}/logs/${R[phase]}-${name}.log" || rc=$?
    fi
    code=${rc}
    [ "${first}" = 1 ] || list+=','
    first=0
    list+="{\"name\":$(js "${name}" 80),\"sha256\":\"${have}\",\"exit_code\":${code},\"seconds\":$((SECONDS - start))}"
    [ "${code}" = 0 ] || { reply "${R[phase]}" failed "${name} exited ${code}" "[${list}]"; return; }   # check:agent-exit
  done
  reply "${R[phase]}" ok '' "[${list}]"
}

# Packer's file provisioner: a folder uploaded to an existing destination lands inside it, to a missing one it becomes it.
# Uploads ran as the build user over SFTP, so the copies belong to that user.
place() { # source destination
  local user
  user=$(var install_user) || return 1
  if [ -d "${S}$2" ]; then
    sudo -u "${user}" cp -R "$1" "${S}$2/" || return 1
  else
    sudo -u "${user}" cp -R "$1" "${S}$2" || return 1
  fi
}

# The P03-verified archive the host sent: exactly one top-level folder, unpacked once into $ROOT/src.
unpack_sources() {
  local tops
  [ -d "${ROOT}/src" ] && return 0
  [ -f "${ROOT}/in/runner-images.tar.gz" ] || return 1
  tops=$(tar -tzf "${ROOT}/in/runner-images.tar.gz" | cut -d/ -f1 | sort -u | wc -l) || return 1
  [ "${tops}" = 1 ] || return 1   # check:agent-archive
  mkdir -p "${ROOT}/src.part"
  tar --no-same-owner -xzf "${ROOT}/in/runner-images.tar.gz" -C "${ROOT}/src.part" --strip-components=1 || return 1
  chmod -R a+rX "${ROOT}/src.part"
  mv "${ROOT}/src.part" "${ROOT}/src"
}

seal_check() { # JSON {checked, findings, unreadable} of the seal rules
  local rule found user f
  local checked='' findings='' unreadable=''
  user=$(var install_user) || user=installer
  for rule in ${SEAL_RULES}; do
    found=0
    case "${rule}" in
      install-user-absent) grep -q "^${user}:" "${S}/etc/passwd" 2>/dev/null && found=1 ;;
      no-password-hash) [ -r "${S}/etc/shadow" ] || { unreadable+=" ${rule}"; continue; }
        cut -d: -f2 "${S}/etc/shadow" | grep -q '^\$' && found=1 ;;
      no-authorized-keys) [ -z "$(find "${S}/root" "${S}/home" -name 'authorized_keys*' -print -quit 2>/dev/null)" ] || found=1 ;;
      no-ssh-host-keys) compgen -G "${S}/etc/ssh/ssh_host_*_key" > /dev/null && found=1 ;;
      no-agent)
        for f in "${ROOT}" "${S}/usr/local/libexec/aap-build" "${S}/etc/systemd/system/aap-agent.socket" "${S}/etc/systemd/system/aap-agent@.service" \
          "${S}/etc/systemd/system/sockets.target.wants/aap-agent.socket"; do
          { [ ! -e "${f}" ] && [ ! -L "${f}" ]; } || found=1   # check:agent-seal-agent
        done ;;
      no-cloud-state) { [ -e "${S}/var/lib/cloud/instance" ] || [ -e "${S}/var/log/installer" ] || [ -e "${S}/etc/cloud/cloud.cfg.d/99-installer.cfg" ]; } && found=1 ;;
      no-build-sudoers) grep -rqs "${user}" "${S}/etc/sudoers.d" && found=1 ;;
    esac
    checked+=" ${rule}"
    [ "${found}" = 0 ] || findings+=" ${rule}"
  done
  printf '{"checked":%s,"findings":%s,"unreadable":%s}' "$(jlist "${checked}")" "$(jlist "${findings}")" "$(jlist "${unreadable}")"
}

# Upstream's last step deprovisions the Azure agent's user; here the install user, the agent with its units and token,
# cloud-init and installer state, the journal, the per-machine snakeoil TLS key and the random seed go (each clone makes its
# own at first boot), cloud-init is pointed at the NoCloud seed each clone gets, free space is trimmed and the seal rules are
# checked.
deprovision() {
  local user seal rc=0
  user=$(var install_user) || { reply "${R[phase]}" failed 'no install_user'; return; }
  sleep "${AAP_DEPROVISION_SLEEP:-30}"
  waagent -force -deprovision > "${ROOT}/logs/${R[phase]}-waagent.log" 2>&1 || rc=$?
  userdel -r "${user}" > /dev/null 2>&1 || true
  rm -f "${S}/etc/sudoers.d/90-cloud-init-users"
  cloud-init clean --logs --seed --machine-id > /dev/null 2>&1 || true
  rm -rf "${S}/var/lib/cloud/instance" "${S}/var/lib/cloud/instances" "${S}/var/lib/cloud/seed" "${S}/var/log/installer"
  rm -f "${S}/etc/cloud/cloud.cfg.d/99-installer.cfg" "${S}/etc/cloud/cloud.cfg.d/90-installer-network.cfg" "${S}/etc/cloud/cloud-init.disabled"
  mkdir -p "${S}/etc/cloud/cloud.cfg.d"
  printf 'datasource_list: [ NoCloud, None ]\n' > "${S}/etc/cloud/cloud.cfg.d/90-aap-nocloud.cfg"
  rm -f "${S}"/etc/ssh/ssh_host_* "${S}/root/.bash_history"
  rm -f "${S}/etc/ssl/private/ssl-cert-snakeoil.key" "${S}/etc/ssl/certs/ssl-cert-snakeoil.pem" "${S}/var/lib/systemd/random-seed"
  journalctl --rotate --vacuum-time=1s > /dev/null 2>&1 || true
  systemctl disable aap-agent.socket > /dev/null 2>&1 || true
  rm -f "${S}/etc/systemd/system/aap-agent.socket" "${S}/etc/systemd/system/aap-agent@.service" "${S}/etc/systemd/system/sockets.target.wants/aap-agent.socket"
  shred -u -z "${ROOT}/token" > /dev/null 2>&1 || true
  rm -rf "${S}/usr/local/libexec/aap-build" "${ROOT}"
  fstrim -av > /dev/null 2>&1 || true
  seal=$(seal_check)
  sync
  if [ "${rc}" != 0 ]; then reply "${R[phase]}" failed "waagent exited ${rc}" '' "{\"seal\":${seal}}"; return; fi
  [[ ${seal} == *'"findings":[],"unreadable":[]}' ]] || { reply "${R[phase]}" failed 'the seal check did not pass' '' "{\"seal\":${seal}}"; return; }   # check:agent-seal
  reply "${R[phase]}" ok '' '' "{\"seal\":${seal}}"
}

run_action() {
  local f user rc=0 rc2=0 env
  f=$(var image_folder) || { reply "${R[phase]}" failed 'no image_folder'; return; }
  mkdir -p "${ROOT}/logs" "${ROOT}/out"
  case "${R[action]:-}" in
    make-image-folder)
      # shellcheck disable=SC2024 # the agent itself runs as root, so root writes this log either way; sudo only matches Packer's command
      sudo sh -c "mkdir ${S}${f}; chmod 777 ${S}${f}" > "${ROOT}/logs/${R[phase]}.log" 2>&1 || rc=$? ;;
    upload-helpers) { unpack_sources && place "${ROOT}/src/images/ubuntu/scripts/helpers" "$(var helper_script_folder)"; } || rc=1 ;;
    upload-build-scripts) { unpack_sources && place "${ROOT}/src/images/ubuntu/scripts/build" "$(var installer_script_folder)"; } || rc=1 ;;
    upload-image-folder)
      { unpack_sources && place "${ROOT}/src/images/ubuntu/assets/post-gen" "${f}" && place "${ROOT}/src/images/ubuntu/scripts/tests" "${f}" &&
        place "${ROOT}/src/images/ubuntu/scripts/docs-gen" "${f}"; } || rc=1 ;;
    upload-report-base) { unpack_sources && place "${ROOT}/src/helpers/software-report-base" "${f}/docs-gen"; } || rc=1 ;;
    upload-toolset)
      user=$(var install_user) || user=''
      { unpack_sources && sudo -u "${user}" cp "${ROOT}/src/images/ubuntu/toolsets/toolset-2404.json" "${S}$(var installer_script_folder)/toolset.json"; } || rc=1 ;;
    layout-image-folder)
      # shellcheck disable=SC2024 # the agent itself runs as root, so root writes this log either way; sudo only matches Packer's command
      sudo sh -c "mv ${S}${f}/docs-gen ${S}${f}/SoftwareReport && mv ${S}${f}/post-gen ${S}${f}/post-generation" > "${ROOT}/logs/${R[phase]}.log" 2>&1 || rc=$? ;;
    software-report-and-tests)
      # Packer ran this inline block as the build user under sh -e: the report, then the upstream tests, stopping at the first failure.
      env=$(env_prefix)
      run_as user "${env}pwsh -File ${f}/SoftwareReport/Generate-SoftwareReport.ps1 -OutputDirectory ${f}" "${ROOT}/logs/${R[phase]}-report.log" || rc=$?
      [ "${rc}" != 0 ] || run_as user "${env}pwsh -File ${f}/tests/RunAll-Tests.ps1 -OutputDirectory ${f}" "${ROOT}/logs/${R[phase]}-tests.log" || rc2=$?
      cp "${S}${f}/software-report.md" "${S}${f}/software-report.json" "${ROOT}/out/" 2>/dev/null || [ "${rc}${rc2}" != 00 ] || rc=96
      if [ "${rc}" != 0 ] || [ "${rc2}" != 0 ]; then reply "${R[phase]}" failed "report exited ${rc}, tests exited ${rc2}" '' "{\"report_exit\":${rc},\"tests_exit\":${rc2}}"; return; fi
      reply "${R[phase]}" ok '' '' "{\"report_exit\":0,\"tests_exit\":0}"; return ;;
    deprovision) deprovision; return ;;
    *) reply "${R[phase]}" failed 'unknown action'; return ;;
  esac
  if [ "${rc}" = 0 ]; then reply "${R[phase]}" ok ''; else reply "${R[phase]}" failed "${R[action]} failed (${rc})"; fi
}

# A fresh guest of the sealed image: post-generation scripts as root, each the way hosted provisioning runs them (find
# -exec bash, in find's order), then the checks as the job user, whose result and inventory the host fetches. find -exec
# ignores a script's exit code; here any script that fails, or a missing folder, fails post_generation.
run_verify() {
  local user work pg f rc=0
  user=$(var job_user) || { reply verify failed 'no job_user'; return; }
  mkdir -p "${ROOT}/logs" "${ROOT}/out"
  unpack_sources || { reply verify failed 'sources not staged'; return; }
  pg="${S}$(var post_generation)"
  {
    [ -d "${pg}" ] || rc=1
    while IFS= read -r -d '' f; do bash "${f}" || rc=1; done < <(find "${pg}" -mindepth 1 -maxdepth 1 -type f -name '*.sh' -print0 2> /dev/null)   # check:agent-postgen
  } > "${ROOT}/logs/verify-post-generation.log" 2>&1
  work=$(sudo -u "${user}" mktemp -d) || { reply verify failed 'no work folder'; return; }
  cp "${ROOT}/in/aap-verify.sh" "${ROOT}/in/linux.sh" "${ROOT}/in/hello.c" "${work}/" && chown -R "${user}:" "${work}"
  ln -s "${ROOT}/src" "${work}/src"
  # shellcheck disable=SC2024 # the agent runs as root and keeps the job user's output in its own root-only log
  sudo -u "${user}" -H /bin/bash --noprofile --norc "${work}/aap-verify.sh" "${work}" "${rc}" > "${ROOT}/logs/verify.log" 2>&1 || true
  rm -f "${ROOT}/out/job-inventory.json"
  cp "${work}/job-inventory.json" "${ROOT}/out/job-inventory.json" 2>/dev/null || true
  if [ ! -s "${work}/verify.json" ] || [ "$(wc -c < "${work}/verify.json")" -gt 16384 ]; then reply verify failed 'the verification wrote no result'; return; fi
  reply verify ok '' '' "$(tr -d '\n' < "${work}/verify.json")"
}

# The scanner guest: the trusted live system checks the sealed disk the host hot-added as its only disk, looking for the
# build token its seed wrote to $ROOT/known.
run_scan() {
  mkdir -p "${ROOT}/out" "${ROOT}/logs"
  rm -f "${ROOT}/out/scan.json"
  if bash "${ROOT}/in/aap-scan.sh" --known-file "${ROOT}/known" --out "${ROOT}/out/scan.json" > "${ROOT}/logs/scan.log" 2>&1; then
    reply scan ok ''
  else
    reply scan failed "$(tail -n 1 "${ROOT}/logs/scan.log")"
  fi
}

main() {
  local header magic tok verb name len rest want
  IFS= read -r -n 600 header || exit 1
  read -r magic tok verb name len rest <<< "${header}"
  [[ ${magic:-} == aap1 && -z ${rest:-} && ${tok:-} =~ ^[0-9a-f]{64}$ && ${verb:-} =~ ^(ready|bootid|put|get|run|reboot)$ &&
     ${name:-} =~ ^(-|[A-Za-z0-9][A-Za-z0-9._-]{0,63})$ && ${len:-} =~ ^[0-9]{1,10}$ ]] || exit 1   # check:agent-header
  [ -r "${ROOT}/token" ] || exit 1
  want=$(< "${ROOT}/token")
  [ "${tok}" = "${want}" ] || exit 1   # check:agent-token
  case "${verb}" in
    ready) [ "${len}" = 0 ] || exit 1; printf 'ready\n' ;;
    bootid) [ "${len}" = 0 ] || exit 1; printf '%s\n' "$(< "${S}/proc/sys/kernel/random/boot_id")" ;;
    reboot) [ "${len}" = 0 ] || exit 1; printf 'rebooting\n'; systemd-run --on-active=3 --unit=aap-reboot /bin/systemctl reboot > /dev/null 2>&1 ;;
    put)
      { [ "${name}" != - ] && [ "${len}" -le "${PUT_MAX}" ]; } || exit 1   # check:agent-put
      mkdir -p "${ROOT}/in"
      rm -f "${ROOT}/in/${name}.part"
      head -c "${len}" > "${ROOT}/in/${name}.part"
      [ "$(stat -c %s "${ROOT}/in/${name}.part")" = "${len}" ] || { rm -f "${ROOT}/in/${name}.part"; printf 'short\n'; exit 1; }   # check:agent-put-size
      mv -f "${ROOT}/in/${name}.part" "${ROOT}/in/${name}"
      printf 'stored\n' ;;
    get)
      { [ "${name}" != - ] && [ "${len}" = 0 ] && [ -f "${ROOT}/out/${name}" ]; } || exit 1   # check:agent-get
      cat "${ROOT}/out/${name}" ;;
    run)
      { [ "${len}" -ge 1 ] && [ "${len}" -le "${RUN_MAX}" ]; } || exit 1   # check:agent-run-size
      mkdir -p "${ROOT}/in"
      head -c "${len}" > "${ROOT}/in/request"
      parse_request "${ROOT}/in/request" || { reply unknown failed 'malformed request'; exit 0; }   # check:agent-parse
      case "${R[kind]:-}" in
        scripts) run_scripts ;;
        action) run_action ;;
        verify) run_verify ;;
        scan) run_scan ;;
        *) reply "${R[phase]}" failed 'unknown kind' ;;
      esac ;;
  esac
  exit 0
}

[ "${AAP_AGENT_SOURCE_ONLY:-0}" = 1 ] || main
