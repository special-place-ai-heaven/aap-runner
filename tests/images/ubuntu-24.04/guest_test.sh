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
for c in systemd-run systemctl userdel cloud-init fstrim; do
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
  mkdir -p "${tmp}/root/logs" "${tmp}/sys/etc/ssh" "${tmp}/sys/etc/sudoers.d" "${tmp}/sys/var/lib/cloud/instance" "${tmp}/sys/root" "${tmp}/sys/home/runner"
  printf 'root:x:0:0::/root:/bin/bash\n' > "${tmp}/sys/etc/passwd"
  printf 'root:*:20000:0:99999:7:::\n' > "${tmp}/sys/etc/shadow"
  echo key > "${tmp}/sys/etc/ssh/ssh_host_ed25519_key"
}
dvars=$'var=install_user=installer\nvar=image_folder=/imagegeneration\n'
seal_world
run $'schema=1\nphase=p30\nkind=action\naction=deprovision\n'"${dvars}"
[ "$(reply 'r["status"], sorted(r["data"]["seal"]["checked"]), r["data"]["seal"]["findings"], r["data"]["seal"]["unreadable"]')" = \
  "('ok', ['install-user-absent', 'no-agent', 'no-authorized-keys', 'no-build-sudoers', 'no-cloud-state', 'no-password-hash', 'no-ssh-host-keys'], [], [])" ] || fail "deprovision: $(out)"
[ ! -e "${tmp}/sys/etc/ssh/ssh_host_ed25519_key" ] && [ ! -e "${tmp}/root" ] && [ ! -e "${tmp}/sys/var/lib/cloud/instance" ] || fail 'deprovision left build state'
grep -qx 'datasource_list: \[ NoCloud, None \]' "${tmp}/sys/etc/cloud/cloud.cfg.d/90-aap-nocloud.cfg" || fail 'cloud-init is not pointed at NoCloud'
grep -q '^waagent -force -deprovision$' "${STUB_LOG}" && grep -q '^userdel -r installer$' "${STUB_LOG}" || fail "deprovision calls: $(cat "${STUB_LOG}")"
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
RC=0
TMPDIR="${tmp}" AAP_AGENT_ROOT="${tmp}/root" AAP_SYSROOT="${tmp}/sys" AAP_ENVIRONMENT_FILE="${tmp}/environment" PATH="${vstub}:${stub}:${PATH}" \
  bash "${guest}/aap-agent.sh" < "${tmp}/conn" > "${tmp}/out" 2> "${tmp}/err" || RC=$?
[ -e "${tmp}/post-generation-ran" ] || fail "the post-generation scripts did not run before the checks: $(out) $(cat "${tmp}/err")"
[ "$(reply 'r["status"], r["data"]["upstream_tests"]')" = "('ok', {'total': 7, 'passed': 5, 'failed': 1, 'skipped': 1})" ] || fail "verify: $(out) $(cat "${tmp}/err")"
[ "$(reply 'sorted(k for k, v in r["data"]["discovery"].items() if v is not True)')" = '[]' ] || fail "discovery: $(out)"
[ "$(reply 'r["data"]["facts"]["kernel"], r["data"]["inventory_sha256"]')" = "('6.17.0-1022-azure', '$(sha "${tmp}/root/out/job-inventory.json")')" ] || fail "facts or inventory hash: $(out)"

# --- secret scan over a planted tree -----------------------------------------------------------------------------------
t="${tmp}/target"
mkdir -p "${t}/home/u" "${t}/etc/ssh" "${t}/var/lib/cloud/seed/nocloud" "${t}/opt/app" "${tmp}/outside"
echo 'ls' > "${t}/home/u/.bash_history"
echo 'not a key' > "${t}/etc/ssh/ssh_host_rsa_key"
echo 'x' > "${t}/var/lib/cloud/seed/nocloud/user-data"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n' > "${t}/opt/app/key.txt"
printf 'token=ghp_%s\n' "$(printf '%036d' 0 | tr 0 Z)" > "${t}/opt/app/tok.txt"
printf 'x %s y\n' "${TOKEN}" > "${t}/opt/app/known.txt"
python3 -B -I -c 'import sys; open(sys.argv[1], "wb").write(("z" + sys.argv[2]).encode("utf-16-le"))' "${t}/opt/app/known16.bin" "${TOKEN}"
printf 'root:$6$salt$hash:20000:0:99999:7:::\n' > "${t}/etc/shadow"
truncate -s 33M "${t}/opt/app/big.bin"
printf -- '-----BEGIN RSA PRIVATE KEY-----\n' > "${tmp}/outside/secret.pem"
ln -s "${tmp}/outside/secret.pem" "${t}/opt/app/link.pem"
ln -s "${tmp}/outside" "${t}/opt/linkdir"
echo 'clean' > "${t}/opt/app/readme"
RC=0; bash "${guest}/aap-scan.sh" --known "${TOKEN}" --out "${tmp}/scan.json" --target "${t}" > "${tmp}/scan.log" 2>&1 || RC=$?
[ "${RC}" = 0 ] || fail "scan: $(cat "${tmp}/scan.log")"
cp "${tmp}/scan.json" "${tmp}/out"
[ "$(reply 'sorted((f["rule"], f["path"]) for f in r["findings"])')" = "$(python3 -B -I -c 'print(sorted([
 ("build-credential", "opt/app/known.txt"), ("build-credential", "opt/app/known16.bin"), ("cloud-init-seed", "var/lib/cloud/seed/nocloud/user-data"),
 ("github-token", "opt/app/tok.txt"), ("pem-private-key", "opt/app/key.txt"), ("shadow-password-hash", "etc/shadow"),
 ("shell-history", "home/u/.bash_history"), ("ssh-host-key", "etc/ssh/ssh_host_rsa_key")]))')" ] || fail "scan findings: $(out)"
[ "$(reply 'r["layout"], r["findings_count"], r["unreadable_count"], r["large_files_count"], [(f["path"], f["bytes"]) for f in r["large_files"]]')" = \
  "('ok', 8, 0, 1, [('opt/app/big.bin', 34603008)])" ] || fail "scan counts: $(out)"
[ "$(reply '[f["sha256"] for f in r["findings"] if f["path"] == "opt/app/key.txt"][0]')" = "$(sha "${t}/opt/app/key.txt")" ] || fail 'a finding lacks its file hash'
[ "$(reply 'r["large_files"][0]["sha256"]')" = "$(sha "${t}/opt/app/big.bin")" ] || fail 'a large file lacks its hash'
! grep -q 'BEGIN\|ghp_\|'"${TOKEN}" "${tmp}/scan.json" || fail 'the scan report carries a matched value'
RC=0; bash "${guest}/aap-scan.sh" --known nothex --out "${tmp}/scan2.json" --target "${t}" > /dev/null 2>&1 || RC=$?
[ "${RC}" = 2 ] && [ ! -e "${tmp}/scan2.json" ] || fail 'a malformed --known was accepted'
echo x > "${tmp}/notablock"
RC=0; bash "${guest}/aap-scan.sh" --known "${TOKEN}" --out "${tmp}/out" --disk "${tmp}/notablock" > /dev/null 2>&1 || RC=$?
[ "${RC}" = 3 ] && [ "$(reply 'r["layout"], r["detail"]')" = "('unexpected', '${tmp}/notablock is not a block device')" ] || fail "a non-disk was scanned: $(out)"

echo 'guest_test: all checks passed'
