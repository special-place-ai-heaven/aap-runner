#!/bin/bash
# Hermetic checks of the P07 guest scripts (images/ubuntu-24.04/guest): the agent's wire format, token, header, put, get
# and request checks, script runs with pinned hashes, the Packer upload rule, deprovision and its seal check, verification
# as the job user, and the secret scan over a planted tree. Every system command the scripts call is a stub in a private
# PATH and every system path sits under a temporary root (AAP_AGENT_ROOT, AAP_SYSROOT), so nothing on this machine changes.
# Needs bash, python3 and coreutils only. AAP_GUEST_DIR points it at another copy (the mutation run does).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "${here}/../../.." && pwd)
guest=${AAP_GUEST_DIR:-${repo}/images/ubuntu-24.04/guest}
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
TOKEN=$(printf '%064d' 0 | tr 0 a)
ME=$(id -un)

# --- stubs ------------------------------------------------------------------------------------------------------------
stub="${tmp}/bin"
mkdir -p "${stub}"
cat > "${stub}/sudo" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -H|-n) shift ;; -u) shift 2 ;; *) break ;; esac; done
exec "$@"
EOF
for c in systemd-run systemctl userdel cloud-init fstrim journalctl; do
  printf '#!/bin/bash\necho "%s $*" >> "${STUB_LOG}"\n' "${c}" > "${stub}/${c}"
done
printf '#!/bin/bash\necho "waagent $*" >> "${STUB_LOG}"\nexit "${FAKE_WAAGENT_RC:-0}"\n' > "${stub}/waagent"
chmod +x "${stub}"/*
export STUB_LOG="${tmp}/calls"

reset_root() {
  rm -rf "${tmp}/root" "${tmp}/sys"
  mkdir -p "${tmp}/root" "${tmp}/sys/proc/sys/kernel/random"
  printf '%s' "${TOKEN}" > "${tmp}/root/token"
  chmod 0600 "${tmp}/root/token"
  echo 0b0b0b0b-1111-4222-8333-444455556666 > "${tmp}/sys/proc/sys/kernel/random/boot_id"
  : > "${STUB_LOG}"
}
# agent FILE: runs the agent with FILE as the connection's input; output in ${tmp}/out, exit code in RC
agent() {
  RC=0
  AAP_AGENT_ROOT="${tmp}/root" AAP_SYSROOT="${tmp}/sys" AAP_DEPROVISION_SLEEP=0 PATH="${stub}:${PATH}" \
    bash "${guest}/aap-agent.sh" < "$1" > "${tmp}/out" 2> "${tmp}/err" || RC=$?
}
# send VERB NAME [PAYLOAD-FILE [LENGTH]]: one connection with the test token (or $TOK)
send() {
  local len=0
  [ -z "${3:-}" ] || len=${4:-$(stat -c %s "$3")}
  { printf 'aap1 %s %s %s %s\n' "${TOK:-${TOKEN}}" "$1" "$2" "${len}"; [ -z "${3:-}" ] || cat "$3"; } > "${tmp}/conn"
  agent "${tmp}/conn"
}
# run REQUEST-TEXT: a run request; the reply in ${tmp}/out
run() { printf '%s' "$1" > "${tmp}/request"; send run - "${tmp}/request"; }
out() { cat "${tmp}/out"; }
# reply EXPR: evaluates a Python expression over the JSON reply r
reply() { python3 -B -I -c 'import json, sys; r = json.loads(open(sys.argv[1]).read()); print(eval(sys.argv[2]))' "${tmp}/out" "$1"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# --- wire format, token, header ---------------------------------------------------------------------------------------
reset_root
send ready -
[ "${RC}" = 0 ] && [ "$(out)" = ready ] || fail "ready: rc ${RC} '$(out)'"
TOK=$(printf '%064d' 0 | tr 0 b) send ready -
[ "${RC}" = 1 ] && [ ! -s "${tmp}/out" ] || fail 'a wrong token was answered'
printf 'aap1 %s ready - 0 extra\n' "${TOKEN}" > "${tmp}/conn"; agent "${tmp}/conn"
[ "${RC}" = 1 ] && [ ! -s "${tmp}/out" ] || fail 'a header with an extra field was answered'
mkdir -p "${tmp}/root/out"
printf 'aap1 %s get ../token 0\n' "${TOKEN}" > "${tmp}/conn"; agent "${tmp}/conn"
[ "${RC}" = 1 ] && [ ! -s "${tmp}/out" ] || fail "a get outside out/ was answered: $(out)"
send bootid -
[ "$(out)" = 0b0b0b0b-1111-4222-8333-444455556666 ] || fail "bootid: $(out)"
send reboot -
[ "$(out)" = rebooting ] && grep -q '^systemd-run --on-active=3 --unit=aap-reboot /bin/systemctl reboot' "${STUB_LOG}" || fail 'reboot'

# --- put and get -------------------------------------------------------------------------------------------------------
printf 'ten bytes!' > "${tmp}/p"
send put payload.bin "${tmp}/p"
[ "$(out)" = stored ] && cmp -s "${tmp}/p" "${tmp}/root/in/payload.bin" || fail "put: $(out)"
send put - "${tmp}/p"
[ "${RC}" = 1 ] && [ ! -s "${tmp}/out" ] || fail 'a put without a name was stored'
send put short.bin "${tmp}/p" 20
[ "$(out)" = short ] && [ ! -e "${tmp}/root/in/short.bin" ] && [ ! -e "${tmp}/root/in/short.bin.part" ] || fail "a short put was stored: $(out)"
printf 'report' > "${tmp}/root/out/r.md"
send get r.md
[ "$(out)" = report ] || fail "get: $(out)"
send get missing.md
[ "${RC}" = 1 ] && [ ! -s "${tmp}/out" ] || fail 'a get of a missing file succeeded'
printf 'aap1 %s run - 0\n' "${TOKEN}" > "${tmp}/conn"; agent "${tmp}/conn"
[ "${RC}" = 1 ] && [ ! -s "${tmp}/out" ] || fail 'an empty run was answered'

# --- request checks ----------------------------------------------------------------------------------------------------
base=$'schema=1\nphase=p03\nkind=scripts\nexec=root\n'
for bad in $'evil=1\n' $'env=A=it\'s\n' $'script=../x.sh '"$(printf '%064d' 0)"$'\n' $'var=image_folder=/a b\n' 'not a key value'; do
  run "${base}${bad}"
  [ "$(reply 'r["status"], r["message"]')" = "('failed', 'malformed request')" ] || fail "request line accepted: ${bad}"
done
run $'schema=1\nphase=../x\nkind=scripts\n'
[ "$(reply 'r["message"]')" = 'malformed request' ] || fail 'a phase that names a path was accepted'

# --- scripts: pinned hashes, order, exit codes, Packer's environment prefix --------------------------------------------
reset_root
b="${tmp}/root/src/images/ubuntu/scripts/build"
mkdir -p "${b}"
printf '#!/bin/bash\necho "a HELPER_SCRIPTS=${HELPER_SCRIPTS}" >> "%s/ran"\n' "${tmp}" > "${b}/a.sh"
printf '#!/bin/bash\necho b >> "%s/ran"\nexit 3\n' "${tmp}" > "${b}/b.sh"
printf '#!/bin/bash\necho c >> "%s/ran"\n' "${tmp}" > "${b}/c.sh"
vars=$'var=install_user='"${ME}"$'\nvar=image_folder=/imagegeneration\n'
rm -f "${tmp}/ran"
run "${base}env=HELPER_SCRIPTS=/imagegeneration/helpers"$'\n'"script=a.sh $(sha "${b}/a.sh")"$'\n'"script=b.sh $(sha "${b}/b.sh")"$'\n'"script=c.sh $(sha "${b}/c.sh")"$'\n'"${vars}"
[ "$(reply 'r["status"], r["message"], [(s["name"], s["exit_code"]) for s in r["scripts"]]')" = "('failed', 'b.sh exited 3', [('a.sh', 0), ('b.sh', 3)])" ] || fail "script run: $(out)"
[ "$(cat "${tmp}/ran")" = $'a HELPER_SCRIPTS=/imagegeneration/helpers\nb' ] || fail "scripts ran: $(cat "${tmp}/ran")"
rm -f "${tmp}/ran"
run "${base}script=a.sh $(printf '%064d' 0)"$'\n'"${vars}"
[ "$(reply 'r["status"], r["message"], r["scripts"]')" = "('failed', 'a.sh SHA-256 differs from the plan; not run', [])" ] || fail "hash mismatch: $(out)"
[ ! -e "${tmp}/ran" ] || fail 'a script with the wrong hash ran'
run "${base}script=a.sh $(sha "${b}/a.sh")"$'\n'"${vars}"
[ "$(reply 'r["status"], r["scripts"][0]["sha256"]')" = "('ok', '$(sha "${b}/a.sh")')" ] || fail "a pinned script: $(out)"
# What a provisioner saw under Packer: the system locale, SUDO_USER for root, /etc/environment for the build user.
mkdir -p "${tmp}/sys/etc"; printf 'AAP_ENV_TEST=from-etc-environment\n' > "${tmp}/sys/etc/environment"
printf '#!/bin/bash\necho "$1 SUDO_USER=${SUDO_USER:-} LANG=${LANG:-} LC_ALL=${LC_ALL:-unset} AAP_ENV_TEST=${AAP_ENV_TEST:-unset}" >> "%s/ran"\n' "${tmp}" > "${b}/e.sh"
rm -f "${tmp}/ran"
run "${base}script=e.sh $(sha "${b}/e.sh")"$'\n'"${vars}"
run $'schema=1\nphase=p03\nkind=scripts\nexec=user\n'"script=e.sh $(sha "${b}/e.sh")"$'\n'"${vars}"
[ "$(cat "${tmp}/ran")" = " SUDO_USER=${ME} LANG=C.UTF-8 LC_ALL=unset AAP_ENV_TEST=unset"$'\n'" SUDO_USER= LANG=C.UTF-8 LC_ALL=unset AAP_ENV_TEST=from-etc-environment" ] || fail "provisioner environment: $(cat "${tmp}/ran")"

# --- upload actions: the P03 archive, one top folder, Packer's rule for existing and missing destinations --------------
reset_root
mkdir -p "${tmp}/arc/runner-images-x/images/ubuntu/scripts/helpers" "${tmp}/arc/runner-images-x/images/ubuntu/assets/post-gen"
echo h > "${tmp}/arc/runner-images-x/images/ubuntu/scripts/helpers/install.sh"
echo p > "${tmp}/arc/runner-images-x/images/ubuntu/assets/post-gen/env.sh"
tar -czf "${tmp}/arc.tar.gz" -C "${tmp}/arc" runner-images-x
mkdir -p "${tmp}/root/in"; cp "${tmp}/arc.tar.gz" "${tmp}/root/in/runner-images.tar.gz"
avars=$'var=install_user='"${ME}"$'\nvar=image_folder=/imagegeneration\nvar=helper_script_folder=/imagegeneration/helpers\n'
run $'schema=1\nphase=p01\nkind=action\naction=make-image-folder\n'"${avars}"
[ "$(reply 'r["status"]')" = ok ] && [ -d "${tmp}/sys/imagegeneration" ] || fail "make-image-folder: $(out)"
run $'schema=1\nphase=p02\nkind=action\naction=upload-helpers\n'"${avars}"
[ "$(reply 'r["status"]')" = ok ] && [ -f "${tmp}/sys/imagegeneration/helpers/install.sh" ] || fail "a missing destination must become the folder: $(out)"
run $'schema=1\nphase=p07\nkind=action\naction=upload-image-folder\n'"${avars}"
[ -f "${tmp}/sys/imagegeneration/post-gen/env.sh" ] || fail 'an existing destination must receive the folder inside it'
reset_root
mkdir -p "${tmp}/arc2/one" "${tmp}/arc2/two" "${tmp}/root/in" "${tmp}/sys/imagegeneration"
tar -czf "${tmp}/root/in/runner-images.tar.gz" -C "${tmp}/arc2" one two
run $'schema=1\nphase=p02\nkind=action\naction=upload-helpers\n'"${avars}"
[ "$(reply 'r["status"]')" = failed ] && [ ! -e "${tmp}/root/src" ] || fail 'an archive with two top-level folders was unpacked'

# --- deprovision and the seal check -------------------------------------------------------------------------------------
seal_world() {
  reset_root
  mkdir -p "${tmp}/root/logs" "${tmp}/sys/etc/ssh" "${tmp}/sys/etc/sudoers.d" "${tmp}/sys/var/lib/cloud/instance" "${tmp}/sys/root" "${tmp}/sys/home/runner" \
    "${tmp}/sys/etc/ssl/private" "${tmp}/sys/etc/ssl/certs" "${tmp}/sys/var/lib/systemd" "${tmp}/sys/usr/local/libexec/aap-build" "${tmp}/sys/etc/systemd/system/sockets.target.wants" \
    "${tmp}/sys/etc/netplan" "${tmp}/sys/etc/cloud/cloud.cfg.d"
  printf 'root:x:0:0::/root:/bin/bash\n' > "${tmp}/sys/etc/passwd"
  printf 'root:*:20000:0:99999:7:::\n' > "${tmp}/sys/etc/shadow"
  echo key > "${tmp}/sys/etc/ssh/ssh_host_ed25519_key"
  echo key > "${tmp}/sys/etc/ssl/private/ssl-cert-snakeoil.key"; echo cert > "${tmp}/sys/etc/ssl/certs/ssl-cert-snakeoil.pem"
  echo seed > "${tmp}/sys/var/lib/systemd/random-seed"
  echo agent > "${tmp}/sys/usr/local/libexec/aap-build/agent"
  echo unit > "${tmp}/sys/etc/systemd/system/aap-agent.socket"; echo unit > "${tmp}/sys/etc/systemd/system/aap-agent@.service"
  ln -s /etc/systemd/system/aap-agent.socket "${tmp}/sys/etc/systemd/system/sockets.target.wants/aap-agent.socket"
  # the build VM's static address, as the installer leaves it
  printf 'network: {version: 2, ethernets: {nic: {addresses: [172.31.253.2/24]}}}\n' > "${tmp}/sys/etc/netplan/50-cloud-init.yaml"
  printf 'network: {version: 2}\n' > "${tmp}/sys/etc/cloud/cloud.cfg.d/90-installer-network.cfg"
}
# seal_check alone, sourced, over the current world
seal_only() {
  AAP_AGENT_SOURCE_ONLY=1 AAP_AGENT_ROOT="${tmp}/root" AAP_SYSROOT="${tmp}/sys" \
    bash -c '. "$1"; VARS_K=(install_user); VARS_V=(installer); seal_check' _ "${guest}/aap-agent.sh" > "${tmp}/out"
}
dvars=$'var=install_user=installer\nvar=image_folder=/imagegeneration\n'
seal_world
run $'schema=1\nphase=p30\nkind=action\naction=deprovision\n'"${dvars}"
[ "$(reply 'r["status"], sorted(r["data"]["seal"]["checked"]), r["data"]["seal"]["findings"], r["data"]["seal"]["unreadable"]')" = \
  "('ok', ['install-user-absent', 'no-agent', 'no-authorized-keys', 'no-build-network', 'no-build-sudoers', 'no-cloud-state', 'no-password-hash', 'no-ssh-host-keys'], [], [])" ] || fail "deprovision: $(out)"
[ ! -e "${tmp}/sys/etc/ssh/ssh_host_ed25519_key" ] && [ ! -e "${tmp}/root" ] && [ ! -e "${tmp}/sys/var/lib/cloud/instance" ] || fail 'deprovision left build state'
for f in etc/ssl/private/ssl-cert-snakeoil.key etc/ssl/certs/ssl-cert-snakeoil.pem var/lib/systemd/random-seed usr/local/libexec/aap-build \
  etc/systemd/system/aap-agent.socket etc/systemd/system/aap-agent@.service etc/systemd/system/sockets.target.wants/aap-agent.socket \
  etc/netplan/50-cloud-init.yaml etc/cloud/cloud.cfg.d/90-installer-network.cfg; do
  [ ! -e "${tmp}/sys/${f}" ] && [ ! -L "${tmp}/sys/${f}" ] || fail "deprovision left ${f}"
done
grep -qx 'datasource_list: \[ NoCloud, None \]' "${tmp}/sys/etc/cloud/cloud.cfg.d/90-aap-nocloud.cfg" || fail 'cloud-init is not pointed at NoCloud'
grep -q '^waagent -force -deprovision$' "${STUB_LOG}" && grep -q '^userdel -r installer$' "${STUB_LOG}" || fail "deprovision calls: $(cat "${STUB_LOG}")"
grep -q '^journalctl --rotate --vacuum-time=1s$' "${STUB_LOG}" || fail "the journal was not rotated and vacuumed: $(cat "${STUB_LOG}")"
# Anything of the agent left behind fails the seal check, a dangling unit link included.
for left in root usr/local/libexec/aap-build etc/systemd/system/aap-agent.socket etc/systemd/system/aap-agent@.service etc/systemd/system/sockets.target.wants/aap-agent.socket; do
  seal_world; rm -rf "${tmp}/root" "${tmp}/sys/etc/ssh/ssh_host_ed25519_key" "${tmp}/sys/var/lib/cloud/instance" "${tmp}/sys/usr/local/libexec/aap-build" "${tmp}/sys/etc/systemd/system/aap-agent"* \
    "${tmp}/sys/etc/netplan"/* "${tmp}/sys/etc/cloud/cloud.cfg.d/90-installer-network.cfg"
  rm -f "${tmp}/sys/etc/systemd/system/sockets.target.wants/aap-agent.socket"
  seal_only
  [ "$(reply 'r["findings"]')" = '[]' ] || fail "a clean seal world: $(out)"
  case "${left}" in
    root) mkdir -p "${tmp}/root" ;;
    usr/local/libexec/aap-build) mkdir -p "${tmp}/sys/${left}" ;;
    etc/systemd/system/sockets.target.wants/aap-agent.socket) ln -s /nonexistent "${tmp}/sys/${left}" ;;
    *) echo unit > "${tmp}/sys/${left}" ;;
  esac
  seal_only
  [ "$(reply 'r["findings"]')" = "['no-agent']" ] || fail "the seal check missed ${left}: $(out)"
done
# The build VM's static network configuration left behind fails the seal check: a clone's addressing is its own seed's.
for left in etc/netplan/01-build.yaml etc/cloud/cloud.cfg.d/90-installer-network.cfg; do
  seal_world; rm -rf "${tmp}/root" "${tmp}/sys/etc/ssh/ssh_host_ed25519_key" "${tmp}/sys/var/lib/cloud/instance" "${tmp}/sys/usr/local/libexec/aap-build" "${tmp}/sys/etc/systemd/system/aap-agent"* \
    "${tmp}/sys/etc/netplan"/* "${tmp}/sys/etc/cloud/cloud.cfg.d/90-installer-network.cfg"
  rm -f "${tmp}/sys/etc/systemd/system/sockets.target.wants/aap-agent.socket"
  echo 'network: {version: 2}' > "${tmp}/sys/${left}"
  seal_only
  [ "$(reply 'r["findings"]')" = "['no-build-network']" ] || fail "the seal check missed ${left}: $(out)"
done
seal_world
mkdir -p "${tmp}/sys/home/runner/.ssh"; echo k > "${tmp}/sys/home/runner/.ssh/authorized_keys"
printf 'root:$6$salt$hash:20000:0:99999:7:::\n' > "${tmp}/sys/etc/shadow"
run $'schema=1\nphase=p30\nkind=action\naction=deprovision\n'"${dvars}"
[ "$(reply 'r["status"], r["message"], sorted(r["data"]["seal"]["findings"])')" = "('failed', 'the seal check did not pass', ['no-authorized-keys', 'no-password-hash'])" ] || fail "seal findings: $(out)"
seal_world
FAKE_WAAGENT_RC=1 run $'schema=1\nphase=p30\nkind=action\naction=deprovision\n'"${dvars}"
[ "$(reply 'r["status"], r["message"]')" = "('failed', 'waagent exited 1')" ] || fail "waagent failure: $(out)"

# --- verification as the job user --------------------------------------------------------------------------------------
reset_root
vstub="${tmp}/vbin"
mkdir -p "${vstub}"
cp "${stub}/sudo" "${stub}/systemctl" "${vstub}/"
printf '#!/bin/bash\nfor ((i = 1; i <= $#; i++)); do [ "${!i}" = -OutputDirectory ] && j=$((i + 1)) && d=${!j}; done\n[ -z "${d:-}" ] || printf "<test-results total=\\"7\\" errors=\\"0\\" failures=\\"1\\" not-run=\\"0\\" inconclusive=\\"0\\" ignored=\\"0\\" skipped=\\"1\\" invalid=\\"0\\">\\n" > "${d}/testResults.xml"\nexit 0\n' > "${vstub}/pwsh"
printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && o=$2; shift; done\n[ -z "${o:-}" ] || printf "#!/bin/sh\\nexit 0\\n" > "$o"; chmod +x "${o:-/dev/null}" 2>/dev/null; exit 0\n' > "${vstub}/gcc"
cp "${vstub}/gcc" "${vstub}/clang"
for c in g++ cmake ninja make pkg-config python3 docker; do printf '#!/bin/bash\nexit 0\n' > "${vstub}/${c}"; done
printf '#!/bin/bash\ncase "$1" in -un) echo runner ;; -u) echo 1001 ;; -nG) echo runner adm users docker systemd-journal ;; esac\n' > "${vstub}/id"
printf '#!/bin/bash\n[ "$1" = -r ] && echo 6.17.0-1022-azure\n' > "${vstub}/uname"
printf '#!/bin/bash\ncase "$2" in SOURCE) echo /dev/sda2 ;; OPTIONS) echo rw,relatime,discard,commit=30,data=writeback ;; esac\n' > "${vstub}/findmnt"
printf '#!/bin/bash\necho sda\n' > "${vstub}/lsblk"
chmod +x "${vstub}"/*
mkdir -p "${tmp}/root/in" "${tmp}/sys/imagegeneration/post-generation" "${tmp}/vsrc/runner-images-x/images/ubuntu/toolsets" "${tmp}/vsrc/runner-images-x/images/ubuntu/scripts/tests"
echo '{}' > "${tmp}/vsrc/runner-images-x/images/ubuntu/toolsets/toolset-2404.json"
echo '# tests' > "${tmp}/vsrc/runner-images-x/images/ubuntu/scripts/tests/RunAll-Tests.ps1"
tar -czf "${tmp}/root/in/runner-images.tar.gz" -C "${tmp}/vsrc" runner-images-x
printf '#!/bin/bash\ntouch "%s/post-generation-ran"\n' "${tmp}" > "${tmp}/sys/imagegeneration/post-generation/user.sh"
cp "${guest}/aap-verify.sh" "${tmp}/root/in/aap-verify.sh"
printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = --out ] && o=$2; shift; done\necho "{\\"schema\\":1}" > "$o"\n' > "${tmp}/root/in/linux.sh"
echo 'int main(void) { return 0; }' > "${tmp}/root/in/hello.c"
printf 'PATH=%s:/usr/bin:/bin\nImageVersion=20261012.334.1\n' "${vstub}" > "${tmp}/environment"
printf 'schema=1\nphase=verify\nkind=verify\nvar=job_user=%s\nvar=post_generation=/imagegeneration/post-generation\n' "${ME}" > "${tmp}/request"
{ printf 'aap1 %s run - %s\n' "${TOKEN}" "$(stat -c %s "${tmp}/request")"; cat "${tmp}/request"; } > "${tmp}/conn"
verify_run() {
  RC=0
  TMPDIR="${tmp}" AAP_AGENT_ROOT="${tmp}/root" AAP_SYSROOT="${tmp}/sys" AAP_ENVIRONMENT_FILE="${tmp}/environment" PATH="${vstub}:${stub}:${PATH}" \
    bash "${guest}/aap-agent.sh" < "${tmp}/conn" > "${tmp}/out" 2> "${tmp}/err" || RC=$?
}
verify_run
[ -e "${tmp}/post-generation-ran" ] || fail "the post-generation scripts did not run before the checks: $(out) $(cat "${tmp}/err")"
[ "$(reply 'r["status"], r["data"]["upstream_tests"]')" = "('ok', {'total': 7, 'passed': 5, 'failed': 1, 'skipped': 1})" ] || fail "verify: $(out) $(cat "${tmp}/err")"
[ "$(reply 'sorted(k for k, v in r["data"]["discovery"].items() if v is not True)')" = '[]' ] || fail "discovery: $(out)"
[ "$(reply 'r["data"]["facts"]["kernel"], r["data"]["inventory_sha256"]')" = "('6.17.0-1022-azure', '$(sha "${tmp}/root/out/job-inventory.json")')" ] || fail "facts or inventory hash: $(out)"
# find -exec ignores a script's exit code; the agent must not: one failing post-generation script fails post_generation.
printf '#!/bin/bash\nexit 7\n' > "${tmp}/sys/imagegeneration/post-generation/zz-fails.sh"
rm -f "${tmp}/post-generation-ran"
verify_run
[ -e "${tmp}/post-generation-ran" ] && [ "$(reply 'r["data"]["discovery"]["post_generation"]')" = False ] || fail "a failing post-generation script passed: $(out)"
rm -f "${tmp}/sys/imagegeneration/post-generation/zz-fails.sh"

# --- secret scan over a planted tree -----------------------------------------------------------------------------------
t="${tmp}/target"
e="${tmp}/esp"
mkdir -p "${t}/home/u" "${t}/etc/ssh" "${t}/var/lib/cloud/seed/nocloud" "${t}/opt/app" "${tmp}/outside" "${e}/EFI/ubuntu"
echo 'ls' > "${t}/home/u/.bash_history"
echo 'not a key' > "${t}/etc/ssh/ssh_host_rsa_key"
echo 'x' > "${t}/var/lib/cloud/seed/nocloud/user-data"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n' > "${t}/opt/app/key.txt"
printf 'token=ghp_%s\n' "$(printf '%036d' 0 | tr 0 Z)" > "${t}/opt/app/tok.txt"
printf 'x %s y\n' "${TOKEN}" > "${t}/opt/app/known.txt"
python3 -B -I -c 'import sys; open(sys.argv[1], "wb").write(("z" + sys.argv[2]).encode("utf-16-le"))' "${t}/opt/app/known16.bin" "${TOKEN}"
printf 'root:$6$salt$hash:20000:0:99999:7:::\n' > "${t}/etc/shadow"
truncate -s 33M "${t}/opt/app/big.bin"
# Over 32 MiB is no excuse: the token after 34 MiB of zeros is found, and so is one inside a .gz.
truncate -s 34M "${t}/opt/app/big-known.bin"; printf 'x %s y\n' "${TOKEN}" >> "${t}/opt/app/big-known.bin"
mkdir -p "${t}/var/log" "${t}/usr/share/doc/x" "${t}/home/u/.local/share/powershell/PSReadLine" "${t}/var/lib/aap-build" "${t}/etc/systemd/system/sockets.target.wants" "${t}/etc/sudoers.d" "${t}/boot/efi"
printf 'log %s\n' "${TOKEN}" | gzip -c > "${t}/var/log/old.log.gz"
printf 'token=ghp_%s\n' "$(printf '%036d' 0 | tr 0 Y)" | gzip -c > "${t}/usr/share/doc/x/changelog.gz"
printf 'nothing here\n' | gzip -c > "${t}/usr/share/doc/x/clean.gz"
python3 -B -I -c 'import sys; sys.stdout.buffer.write(("w" + sys.argv[1]).encode("utf-16-le"))' "${TOKEN}" | gzip -c > "${t}/var/log/wide.log.gz"
# A match early in a long .gz: grep stops reading and zcat writes into a closed pipe, which is not an unreadable file.
python3 -B -I -c 'import gzip, sys; gzip.open(sys.argv[1], "wb").write(("token=ghp_" + "X" * 36 + "\n" + "clean filler line\n" * 200000).encode())' "${t}/var/log/long.log.gz"
echo 'Get-ChildItem' > "${t}/home/u/.local/share/powershell/PSReadLine/ConsoleHost_history.txt"
echo 'left over' > "${t}/var/lib/aap-build/token-was-here"
ln -s /etc/systemd/system/aap-agent.socket "${t}/etc/systemd/system/sockets.target.wants/aap-agent.socket"
printf 'installer ALL=(ALL) NOPASSWD:ALL\n' > "${t}/etc/sudoers.d/90-cloud-init-users"
printf '# a comment that mentions NOPASSWD\n' > "${t}/etc/sudoers.d/README"
# The EFI partition is scanned from a mount point of its own (--esp-target here) and reported under boot/efi/; what the root
# file system itself holds in /boot/efi, which a mount over it would hide, is scanned with the root.
printf -- '-----BEGIN EC PRIVATE KEY-----\nesp\n' > "${e}/EFI/esp.key"
echo 'set timeout=0' > "${e}/EFI/ubuntu/grub.cfg"
printf -- '-----BEGIN EC PRIVATE KEY-----\nroot\n' > "${t}/boot/efi/under-the-mount.key"
printf -- '-----BEGIN RSA PRIVATE KEY-----\n' > "${tmp}/outside/secret.pem"
ln -s "${tmp}/outside/secret.pem" "${t}/opt/app/link.pem"
ln -s "${tmp}/outside" "${t}/opt/linkdir"
echo 'clean' > "${t}/opt/app/readme"
printf '%s\n' "${TOKEN}" > "${tmp}/known"
# SIGPIPE ignored, as under systemd (IgnoreSIGPIPE=yes): a writer to a closed pipe gets EPIPE and complains instead of dying.
RC=0; ( trap '' PIPE; exec bash "${guest}/aap-scan.sh" --known-file "${tmp}/known" --out "${tmp}/scan.json" --target "${t}" --esp-target "${e}" ) > "${tmp}/scan.log" 2>&1 || RC=$?
[ "${RC}" = 0 ] || fail "scan: $(cat "${tmp}/scan.log")"
cp "${tmp}/scan.json" "${tmp}/out"
[ "$(reply 'sorted((f["rule"], f["path"]) for f in r["findings"])')" = "$(python3 -B -I -c 'print(sorted([
 ("build-credential", "opt/app/known.txt"), ("build-credential", "opt/app/known16.bin"), ("cloud-init-seed", "var/lib/cloud/seed/nocloud/user-data"),
 ("github-token", "opt/app/tok.txt"), ("pem-private-key", "opt/app/key.txt"), ("shadow-password-hash", "etc/shadow"),
 ("shell-history", "home/u/.bash_history"), ("ssh-host-key", "etc/ssh/ssh_host_rsa_key"),
 ("build-credential", "opt/app/big-known.bin"), ("build-credential", "var/log/old.log.gz"), ("github-token", "usr/share/doc/x/changelog.gz"),
 ("build-credential", "var/log/wide.log.gz"), ("github-token", "var/log/long.log.gz"),
 ("shell-history", "home/u/.local/share/powershell/PSReadLine/ConsoleHost_history.txt"), ("build-agent", "var/lib/aap-build/token-was-here"),
 ("build-agent", "etc/systemd/system/sockets.target.wants/aap-agent.socket"), ("build-sudoers", "etc/sudoers.d/90-cloud-init-users"),
 ("pem-private-key", "boot/efi/EFI/esp.key"), ("pem-private-key", "boot/efi/under-the-mount.key")]))')" ] || fail "scan findings: $(out)"
[ "$(reply 'r["layout"], r["findings_count"], r["unreadable_count"], r["large_files_count"], sorted((f["path"], f["bytes"]) for f in r["large_files"])')" = \
  "('ok', 19, 0, 2, [('opt/app/big-known.bin', $(stat -c %s "${t}/opt/app/big-known.bin")), ('opt/app/big.bin', 34603008)])" ] || fail "scan counts: $(out)"
[ "$(reply '[f["sha256"] for f in r["findings"] if f["path"] == "opt/app/key.txt"][0]')" = "$(sha "${t}/opt/app/key.txt")" ] || fail 'a finding lacks its file hash'
[ "$(reply '[f["sha256"] for f in r["findings"] if f["path"] == "boot/efi/EFI/esp.key"][0]')" = "$(sha "${e}/EFI/esp.key")" ] || fail 'an EFI finding is not hashed from the EFI partition'
[ "$(reply '[f["sha256"] for f in r["findings"] if f["path"].endswith("aap-agent.socket")][0]')" = "$(printf '%s\n' /etc/systemd/system/aap-agent.socket | sha256sum | cut -d' ' -f1)" ] || fail 'a link finding must hash its target text, not follow it'
[ "$(reply '[f["sha256"] for f in r["large_files"] if f["path"] == "opt/app/big.bin"][0]')" = "$(sha "${t}/opt/app/big.bin")" ] || fail 'a large file lacks its hash'
! grep -q 'BEGIN\|ghp_\|'"${TOKEN}" "${tmp}/scan.json" || fail 'the scan report carries a matched value'
# A .gz that cannot be read to its end is unreadable, never clean: a truncated stream, and a gzip bomb whose one line is too
# long for grep's memory (grep exits 2; here a ulimit, in the scanner guest its RAM).
u="${tmp}/unread"
mkdir -p "${u}/var/log"
python3 -B -I -c 'import gzip, sys; d = gzip.compress(b"clean filler line\n" * 50000); open(sys.argv[1], "wb").write(d[:len(d) // 2])' "${u}/var/log/trunc.log.gz"
head -c 536870912 /dev/zero | gzip -1 > "${u}/var/log/bomb.log.gz"
for sigpipe in default ignored; do
  RC=0; ( if [ "${sigpipe}" = ignored ]; then trap '' PIPE; fi; ulimit -v 131072; exec bash "${guest}/aap-scan.sh" --known-file "${tmp}/known" --out "${tmp}/out" --target "${u}" ) > "${tmp}/scan.log" 2>&1 || RC=$?
  [ "${RC}" = 0 ] && [ "$(reply 'r["unreadable_count"], sorted((f["rule"], f["path"]) for f in r["findings"])')" = \
    "(0, [('unreadable-stream', 'var/log/bomb.log.gz'), ('unreadable-stream', 'var/log/trunc.log.gz')])" ] ||
    fail "a .gz not read to its end passed (SIGPIPE ${sigpipe}): $(out) $(cat "${tmp}/scan.log")"
  # with the file's hash, for an exact allowlist entry
  [ "$(reply '[f["sha256"] for f in r["findings"] if f["path"].endswith("trunc.log.gz")][0]')" = "$(sha "${u}/var/log/trunc.log.gz")" ] || fail "an unreadable stream lacks its hash: $(out)"
done
printf 'nothex\n' > "${tmp}/badknown"
RC=0; bash "${guest}/aap-scan.sh" --known-file "${tmp}/badknown" --out "${tmp}/scan2.json" --target "${t}" > /dev/null 2>&1 || RC=$?
[ "${RC}" = 2 ] && [ ! -e "${tmp}/scan2.json" ] || fail 'a malformed known token was accepted'
RC=0; bash "${guest}/aap-scan.sh" --known-file "${tmp}/missing" --out "${tmp}/scan2.json" --target "${t}" > /dev/null 2>&1 || RC=$?
[ "${RC}" = 2 ] && [ ! -e "${tmp}/scan2.json" ] || fail 'a scan ran without the known token'
echo x > "${tmp}/notablock"
RC=0; AAP_SCAN_WAIT=0 bash "${guest}/aap-scan.sh" --known-file "${tmp}/known" --out "${tmp}/out" --disk "${tmp}/notablock" > /dev/null 2>&1 || RC=$?
[ "${RC}" = 3 ] && [ "$(reply 'r["layout"], r["detail"]')" = "('unexpected', '${tmp}/notablock is not a block device')" ] || fail "a non-disk was scanned: $(out)"

echo 'guest_test: all checks passed'
