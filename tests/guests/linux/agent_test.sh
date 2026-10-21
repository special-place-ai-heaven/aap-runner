#!/bin/bash
# Hermetic checks of the P15 guest agent (guests/linux): the envelope and every refusal, first boot step by step, the
# registration path (the JIT config only in the runner's environment: never on a command line or in a file), the job
# environment and limits, the runner's state in status and collect, the compile cache's wiring, and the static unit,
# sshd and install files. Every system command the agent calls is a stub on a private PATH and every system path sits
# under a temporary root (AAP_SYSROOT), so nothing on this machine changes. Each reply is checked against
# parity/contracts/validate.py (as an exchange with its command) and the backend's per-command state table.
# Needs bash, python3, jq, flock, setsid and coreutils. AAP_GUEST_DIR points it at another copy (the mutation run does).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "${here}/../../.." && pwd)
guest=${AAP_GUEST_DIR:-${repo}/guests/linux}
tmp=$(mktemp -d)
S="${tmp}/sys"
K="${tmp}/knob"
ST="${S}/var/lib/aap-guest"
stub="${tmp}/bin"
stop_runners() {
  printf 0 > "${tmp}/finish"
  for _ in $(seq 50); do pgrep -f "${S}/opt/actions-runner" > /dev/null || break; sleep 0.1; done
  rm -f "${tmp}/finish"
}
cleanup() { stop_runners 2> /dev/null || true; pkill -f "${tmp}/" 2> /dev/null || true; rm -rf "${tmp}"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 10; }   # 10: a check failed (agent_mutations.sh tells it from a harness error)
[ "$(id -u)" != 0 ] || fail 'run the suite unprivileged (an unwritable file must stay unwritable to the agent)'
VM=6f1d2c3b-4a59-4e6f-8a7b-9c0d1e2f3a4b
RID=r-1a2b3c4d000000b1
HK="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5$(printf 'Ab%.0s' {1..24})"
JIT=$(printf 'SYNTHETIC-JIT-MARKER-%s' "${RANDOM}${RANDOM}${RANDOM}" | base64 -w0)

# --- stubs: every call is logged with its arguments; behaviour comes from knob files ----------------------------------
mkdir -p "${stub}"
cat > "${tmp}/stublib" <<EOF
K='${K}'
S='${S}'
printf '%s\n' "\${0##*/} \$*" >> '${tmp}/calls'
EOF
stubs() { # NAME BODY...
  local n=$1; shift
  printf '#!/bin/bash\n. "$(dirname "$0")/../stublib"\n%s\n' "$@" > "${stub}/${n}"
  chmod +x "${stub}/${n}"
}
stubs systemctl 'case "$1" in is-active) [ ! -e "${K}/inactive-$3" ] ;; start) [ ! -e "${K}/fail-start-$2" ] ;; esac'
stubs systemd-run 'ulimit -c > "${K}/core"' 'case " $* " in *" --scope "*) ;; *) exit 0 ;; esac' 'while [ "$1" != -- ]; do shift; done; shift; exec "$@"'
stubs setpriv 'while [ "$1" != -- ]; do shift; done; shift; exec "$@"'
stubs runuser 'while [ "$1" != -- ]; do shift; done; shift; exec "$@"'
stubs setsid 'exec "$@"'
stubs getent '[ "$1" = passwd ] || exit 2' 'if [ $# = 1 ]; then cat "${S}/etc/passwd"; else grep "^$2:" "${S}/etc/passwd" || exit 2; fi'
stubs id 'cat "${K}/groups"'
stubs sudo '[ ! -e "${K}/no-sudo" ]'
stubs make-ssl-cert '[ ! -e "${K}/no-tls" ] || exit 1' '[ -e "${K}/tls-empty" ] && exit 0' \
  'mkdir -p "${S}/etc/ssl/private" "${S}/etc/ssl/certs"; echo key > "${S}/etc/ssl/private/ssl-cert-snakeoil.key"; echo pem > "${S}/etc/ssl/certs/ssl-cert-snakeoil.pem"'
stubs loginctl 'exit 0'
stubs chown 'exit 0'
stubs pgrep '[ -e "${K}/worker" ]'

cat > "${tmp}/check.py" <<'EOF'
# One reply line: printable, one JSON object, valid with its command as a guest-transport exchange, and a state the
# backend accepts for an ok reply to that command. Prints status|state|code, then diag.
import json, subprocess, sys
conn, out, validate, work = sys.argv[1:5]
raw = open(out, 'rb').read()
assert raw.endswith(b'\n') and raw.count(b'\n') == 1, 'not exactly one reply line'
assert all(32 <= b < 127 for b in raw[:-1]), 'non-printable reply'
r = json.loads(raw)
line = open(conn, 'rb').read().split(b'\n', 1)[0]
c = json.loads(line[3:] if line.startswith(b'\xef\xbb\xbf') else line)
doc = {'schema': 1, 'kind': 'exchange', 'cmd': c, 'reply': r}
if (c['cmd'] == 'deliver_registration') != (c['payload_bytes'] > 0):  # a command outside the contract: the reply alone
    assert all(c[k] == r[k] for k in ('vm_id', 'reservation_id', 'lease_generation', 'seq', 'nonce')), 'wrong echo'
    doc = r
with open(work + '/exchange.json', 'w') as f:
    json.dump(doc, f)
v = subprocess.run([sys.executable, '-B', '-I', validate, 'guest-transport', work + '/exchange.json'], capture_output=True, text=True)
assert v.returncode == 0, v.stdout
answers = {'probe': ['booting', 'ready'], 'deliver_registration': ['registered', 'listening'], 'start_runner': ['listening', 'busy'],
           'status': ['listening', 'busy', 'job_done', 'failed'], 'collect': ['listening', 'busy', 'job_done', 'failed', 'shutting_down']}
assert r['status'] != 'ok' or c['cmd'] not in answers or r['guest_state'] in answers[c['cmd']], 'bad_state ' + r['guest_state']
print('%s|%s|%s' % (r['status'], r['guest_state'], 'null' if r['runner_exit_code'] is None else r['runner_exit_code']))
print(r['diag'])
EOF

# --- a fresh clone after cloud-init: the job user, the host key, the seed's copies, post-generation, the runner ---------
reset() {
  stop_runners
  rm -rf "${S}" "${K}" "${tmp}"/listener.* "${tmp}/postgen"
  mkdir -p "${K}" "${S}/sys/class/dmi/id" "${S}/etc/ssh" "${S}/etc/default" "${S}/var/lib/hyperv" "${S}/var/lib/cloud/instances/i-1" \
    "${S}/var/lib/cloud/seed/nocloud" "${S}/imagegeneration/post-generation" "${S}/opt/actions-runner/bin"
  echo "${VM^^}" > "${S}/sys/class/dmi/id/product_uuid"
  printf 'root:x:0:0:root:/root:/bin/bash\nrunner:x:1001:1001::/home/runner:/bin/bash\n' > "${S}/etc/passwd"
  echo 'runner adm users docker systemd-journal' > "${K}/groups"
  echo "${HK} root@aap-l-1" > "${S}/etc/ssh/ssh_host_ed25519_key.pub"
  # pool 1 already holds another item and a stale one of ours
  { printf other; head -c 507 /dev/zero; printf value; head -c 2043 /dev/zero
    printf aap-ssh-host-key-ed25519; head -c 488 /dev/zero; printf stale; head -c 2043 /dev/zero; } > "${S}/var/lib/hyperv/.kvp_pool_1"
  for f in user-data.txt user-data.txt.i cloud-config.txt; do echo seed > "${S}/var/lib/cloud/instances/i-1/${f}"; done
  ln -s instances/i-1 "${S}/var/lib/cloud/instance"
  echo seed > "${S}/var/lib/cloud/seed/nocloud/user-data"
  for f in a b; do printf 'echo %s >> "%s/postgen"\n' "${f}" "${tmp}" > "${S}/imagegeneration/post-generation/${f}.sh"; done
  printf 'LANG=C.UTF-8\n' > "${S}/etc/default/locale"
  cat > "${S}/etc/environment" <<'EOF'
PATH="/home/runner/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ImageOS=ubuntu24
AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
QUOTED='single quoted'
# a comment
not an assignment
EOF
  cat > "${S}/opt/actions-runner/bin/Runner.Listener" <<EOF
#!/bin/bash
env > '${tmp}/listener.env'
echo "\$(ulimit -n) \$(ulimit -s) \$(ulimit -c)" > '${tmp}/listener.limits'
echo "\$*" > '${tmp}/listener.argv'
pwd > '${tmp}/listener.cwd'
while [ ! -s '${tmp}/finish' ]; do sleep 0.1; done
exit "\$(cat '${tmp}/finish')"
EOF
  chmod +x "${S}/opt/actions-runner/bin/Runner.Listener"
  : > "${tmp}/calls"
  CNT=0
}
cache_overlay() { # a stand-in for P13's aap-zccache.sh: init writes runner.env with good and bad lines
  local z="${S}/usr/local/libexec/aap-guest/cache"
  mkdir -p "${z}"
  cat > "${z}/aap-zccache.sh" <<EOF
#!/bin/bash
case "\$1" in
  init) echo "\$*" > '${tmp}/zc.argv'; env > '${tmp}/zc.env'; mkdir -p "\$3/state"; echo '{}' > "\$3/state/config.json"
    printf 'AAP_ZC_STATE=%s\nRUSTC_WRAPPER=relative/zcshim\nLD_PRELOAD=/evil.so\nCMAKE_C_COMPILER_LAUNCHER=${z}/zcshim\n' "\$3/state/config.json" > "\$3/state/runner.env" ;;
  state) echo '{"state":"direct","detail":"no qualified compiler and invocation pair","bytes":null}' ;;
esac
EOF
  chmod +x "${z}/aap-zccache.sh"
}

# agent IN [MODE]: the agent as sshd's forced command (or a mode) with IN as stdin; stdout in out, exit code in RC. It starts
# with core dumps allowed (1024 blocks), so only its own limit keeps the JIT config out of a core file.
(ulimit -c 1024) 2> /dev/null || fail 'this host does not allow a core limit of 1024 blocks; the core-dump check needs it'
agent() {
  local in=$1; shift
  RC=0
  (ulimit -c 1024 && exec env AAP_SYSROOT="${S}" AAP_START_WAIT=5 SSH_CONNECTION='192.0.2.1 50000 192.0.2.2 5222' PATH="${stub}:${PATH}" \
    bash "${guest}/agent.sh" "$@") < "${in}" > "${tmp}/out" 2> "${tmp}/err" || RC=$?
}
firstboot() { agent /dev/null firstboot; }
# send CMD SEQ [PAYLOAD]: one connection; VMX GENX NONCE EXPX LENX BOM override the envelope's fields
send() {
  local p=${3:-}
  CNT=$((CNT + 1))
  printf '%s{"schema":1,"kind":"host_cmd","vm_id":"%s","reservation_id":"%s","lease_generation":%s,"seq":%s,"nonce":"%s","cmd":"%s","payload_bytes":%s,"expires_at":"%s"}\n%s' \
    "${BOM:-}" "${VMX:-${VM}}" "${RID}" "${GENX:-7}" "$2" "${NONCE:-$(printf '%032x' "$((CNT + 4096))")}" "$1" "${LENX:-${#p}}" \
    "${EXPX:-$(date -u -d '+60 sec' +%Y-%m-%dT%H:%M:%SZ)}" "${p}" > "${tmp}/conn"
  agent "${tmp}/conn"
  [ "${RC}" = 0 ] || fail "$1 seq $2 exited ${RC}"
}
expect() { # STATUS STATE CODE LABEL: the last reply
  local got
  got=$(python3 -B -I "${tmp}/check.py" "${tmp}/conn" "${tmp}/out" "${repo}/parity/contracts/validate.py" "${tmp}" 2>&1) || fail "$4: reply rejected: ${got} $(cat "${tmp}/out")"
  DIAG=${got#*$'\n'}
  [ "${got%%$'\n'*}" = "$1|$2|$3" ] || fail "$4: got ${got%%$'\n'*} (${DIAG}), want $1|$2|$3"
}
noreply() { [ "${RC}" = 0 ] && [ ! -s "${tmp}/out" ] || fail "$1: answered '$(cat "${tmp}/out")' rc ${RC}"; }
wait_for() { for _ in $(seq 100); do [ ! -e "$1" ] || return 0; sleep 0.1; done; fail "$2: ${1#"${tmp}"/} never appeared"; }
env_of() { grep -m1 "^$1=" "${tmp}/listener.env" | cut -d= -f2-; }

# --- envelope ---------------------------------------------------------------------------------------------------------
reset
send probe 1
expect ok booting null 'probe before first boot'
BOM=$'\xef\xbb\xbf' send probe 2
expect ok booting null 'a leading BOM'
line='{"schema":1,"kind":"host_cmd","vm_id":"'${VM}'","reservation_id":"'${RID}'","lease_generation":7,"seq":3,"nonce":"0000000000000000000000000000000e","cmd":"probe","payload_bytes":0,"expires_at":"2999-01-01T00:00:00Z"'
for bad in "${line},\"extra\":1}" "${line}} ${line}}" "${line/\"seq\":3/\"seq\":\"3\"}}" "${line/probe/reset}}" "${line/r-1a2b/r-1A2B}}" "${line}" 'not json'; do
  printf '%s\n' "${bad}" > "${tmp}/conn"; agent "${tmp}/conn"; noreply "malformed envelope ${bad:0:60}"
done
printf '%s%*s}\n' "${line}" $((1025 - ${#line})) '' > "${tmp}/conn"; agent "${tmp}/conn"
noreply 'an envelope line over 1024 bytes'
VMX=00000000-0000-4000-8000-000000000000 send probe 3
expect refused booting null 'another vm_id'
send probe 2
expect refused booting null 'a replayed seq'
send probe 10
expect ok booting null 'a seq gap'
send probe 5
expect refused booting null 'a lower seq'
NONCE=$(printf '%032x' 4097) send probe 11
expect refused booting null 'a reused nonce'
GENX=8 send probe 12
expect refused booting null 'another lease generation'
EXPX=$(date -u -d '-10 sec' +%Y-%m-%dT%H:%M:%SZ) send probe 13
expect refused booting null 'an expired command'
LENX=4 send probe 14 abcd
expect refused booting null 'a payload on probe'
send deliver_registration 15
expect refused booting null 'deliver_registration without a payload'
send deliver_registration 16 "${JIT}"
expect error booting null 'deliver_registration before first boot'
send deliver_registration 17 "${JIT}"
expect refused booting null 'a second deliver_registration'

# --- first boot: each step fails closed and probe says where -----------------------------------------------------------
fb_fails() { # STEP LABEL: first boot stops at STEP, and probe reports it
  firstboot
  [ "${RC}" = 1 ] && [ "$(cat "${ST}/firstboot.failed" 2> /dev/null)" = "$1" ] || fail "$2: first boot rc ${RC}, failed at '$(cat "${ST}/firstboot.failed" 2> /dev/null)'"
  [ ! -e "${ST}/firstboot.done" ] || fail "$2: first boot finished"
  send probe 1
  expect error booting null "$2"
  [ "${DIAG}" = "first boot failed at $1" ] || fail "$2: diag ${DIAG}"
}
reset; echo "ssh-rsa ${HK#* } root@x" > "${S}/etc/ssh/ssh_host_ed25519_key.pub"; fb_fails host_key 'a host key of another type'
reset; echo "ssh-ed25519 ${HK#* }A" > "${S}/etc/ssh/ssh_host_ed25519_key.pub"; fb_fails host_key 'an ed25519 key of the wrong length'
reset; touch "${K}/inactive-hv-kvp-daemon.service"; fb_fails host_key 'no KVP daemon to publish through'
reset; sed -i 's/:1001:1001:/:1002:1002:/' "${S}/etc/passwd"; fb_fails identity 'a job user without uid 1001'
reset; echo 'ubuntu:x:1000:1000::/home/ubuntu:/bin/bash' >> "${S}/etc/passwd"; fb_fails identity 'an account with uid 1000'
reset; echo 'runner adm users systemd-journal' > "${K}/groups"; fb_fails identity 'a job user outside docker'
reset; touch "${K}/no-sudo"; fb_fails identity 'a job user without passwordless sudo'
reset; touch "${K}/no-tls"; fb_fails tls 'make-ssl-cert failed'
reset; touch "${K}/tls-empty"; fb_fails tls 'no snakeoil pair after make-ssl-cert'
reset; rm -rf "${S}/imagegeneration/post-generation"; fb_fails post_generation 'no post-generation folder'
reset; printf 'exit 3\n' >> "${S}/imagegeneration/post-generation/a.sh"; fb_fails post_generation 'a post-generation script that fails'
[ "$(sort "${tmp}/postgen" | tr '\n' ' ')" = 'a b ' ] || fail "every post-generation script runs even after one failed: $(cat "${tmp}/postgen")"
reset; touch "${K}/fail-start-docker.service"; fb_fails docker 'Docker does not start'
reset; rm -f "${S}/opt/actions-runner/bin/Runner.Listener"; fb_fails runner_root 'no runner in the overlay'
reset; echo '{}' > "${S}/opt/actions-runner/.credentials"; fb_fails runner_root 'registration material in the image'
reset; mkdir -p "${ST}"; : > "${ST}/firstboot.started"; fb_fails interrupted 'an interrupted first boot'
[ ! -e "${tmp}/postgen" ] || fail 'post-generation ran again after an interrupted first boot'

# a good first boot
reset
firstboot
[ "${RC}" = 0 ] && [ -e "${ST}/firstboot.done" ] || fail "first boot: rc ${RC} $(cat "${tmp}/out" "${tmp}/err")"
python3 -B -I - "${S}/var/lib/hyperv/.kvp_pool_1" "${HK}" <<'EOF' || fail 'the KVP pool'
import sys
raw = open(sys.argv[1], 'rb').read()
recs = [(raw[i:i + 512].rstrip(b'\0').decode(), raw[i + 512:i + 2560].rstrip(b'\0').decode()) for i in range(0, len(raw), 2560)]
assert len(raw) % 2560 == 0 and recs == [('other', 'value'), ('aap-ssh-host-key-ed25519', sys.argv[2])], recs
EOF
[ "$(find "${S}/var/lib/hyperv" -mindepth 1 | wc -l)" = 1 ] && [ "$(stat -c %a "${S}/var/lib/hyperv/.kvp_pool_1")" = 644 ] || fail 'the KVP pool was not swapped in whole'
[ -z "$(find "${S}/var/lib/cloud" -name 'user-data*' -o -name cloud-config.txt -o -name seed)" ] || fail "the seed's copies survived first boot"
[ "$(sort "${tmp}/postgen" | tr '\n' ' ')" = 'a b ' ] || fail "post-generation: $(cat "${tmp}/postgen")"
for c in 'make-ssl-cert generate-default-snakeoil --force-overwrite' 'loginctl enable-linger runner' 'systemctl start docker.service' \
  "chown -R runner:runner ${S}/opt/actions-runner"; do
  grep -qxF "${c}" "${tmp}/calls" || fail "first boot did not run: ${c}"
done
[ ! -e "${ST}/runner.env" ] || fail 'cache variables without a cache overlay'
[ "$(stat -c %a "${ST}")" = 700 ] || fail 'agent state is not 0700'
firstboot
[ "${RC}" = 0 ] && [ "$(wc -l < "${tmp}/postgen")" = 2 ] || fail 'a second first boot ran the post-generation scripts again'
send probe 1
expect ok ready null 'probe after first boot'

# --- registration, runner, status, collect ----------------------------------------------------------------------------
# a mark that cannot be written stops the command before it runs, and the same command is not fresh afterwards
: > "${ST}/shots"; chmod 0444 "${ST}/shots"   # unwritable (the suite runs unprivileged); /dev/full would also break reads
send deliver_registration 2 "${JIT}"
noreply 'deliver_registration with a full state file system'
! grep -q '^systemd-run' "${tmp}/calls" && [ ! -e "${ST}/runner.pid" ] || fail 'deliver_registration ran without its one-shot mark'
chmod 0644 "${ST}/shots"
agent "${tmp}/conn"
expect refused ready null 'the same deliver_registration after the state file system recovered'
mkdir "${ST}/seq.tmp"
send probe 3
noreply 'a seq that cannot be saved'
rmdir "${ST}/seq.tmp"
agent "${tmp}/conn"
expect refused ready null 'the same probe after the seq could be saved again'
send start_runner 4
expect error ready null 'start_runner before any registration'
send deliver_registration 5 'not base64!'
expect error ready null 'a payload that is not an encoded JIT config'
reset; firstboot; send probe 1
mkdir -p "${S}/var/lib/cloud/instances/i-1/user-data.txt.d"
send deliver_registration 2 "${JIT}"
expect error ready null 'seed copies that cannot be removed'
reset; firstboot; send probe 1
echo seed > "${S}/var/lib/cloud/instances/i-1/user-data.txt"
send deliver_registration 2 "${JIT}"
expect ok registered null 'deliver_registration'
[ ! -e "${S}/var/lib/cloud/instances/i-1/user-data.txt" ] || fail 'the seed copy survived deliver_registration'
start=${SECONDS}
send start_runner 3
expect ok listening null 'start_runner'
[ $((SECONDS - start)) -lt 8 ] || fail 'the launcher kept the agent lock'
[ "$(cat "${K}/core")" = 0 ] || fail "the agent held the JIT config with a core limit of $(cat "${K}/core")"
wait_for "${tmp}/listener.env" 'the runner'
[ "$(env_of ACTIONS_RUNNER_INPUT_JITCONFIG)" = "${JIT}" ] || fail 'the runner did not get the JIT config in its environment'
python3 -B -I -c '
import os, sys
jit = sys.stdin.read().strip().encode()
for p in os.listdir("/proc"):
    try:
        assert jit not in open("/proc/%s/cmdline" % p, "rb").read(), "JIT config on the command line of pid " + p
    except OSError:
        pass
' <<< "${JIT}" || fail 'the JIT config is on a command line'
! grep -rqF "${JIT}" "${S}" "${tmp}/calls" "${tmp}/err" || fail "the JIT config is in a file: $(grep -rlF "${JIT}" "${S}" "${tmp}/calls" "${tmp}/err")"
grep -qxF "setpriv --reuid=runner --regid=runner --init-groups -- ${S}/opt/actions-runner/bin/Runner.Listener run" "${tmp}/calls" || fail 'the runner does not run as runner'
grep -qxF "systemd-run --scope --quiet --collect --unit=aap-runner -- /bin/bash ${guest}/agent.sh launch" "${tmp}/calls" || fail 'the launcher does not run in its own scope'
[ "$(cat "${tmp}/listener.argv")" = run ] && [ "$(cat "${tmp}/listener.cwd")" = "${S}/opt/actions-runner" ] || fail 'Runner.Listener run in its root'
[ "$(cat "${tmp}/listener.limits")" = '65536 16384 0' ] || fail "runner limits: $(cat "${tmp}/listener.limits")"
names=$(cut -d= -f1 "${tmp}/listener.env" | grep -vx -e PWD -e SHLVL -e _ | sort | tr '\n' ' ')
[ "${names}" = 'ACTIONS_RUNNER_INPUT_JITCONFIG AGENT_TOOLSDIRECTORY HOME ImageOS LANG LOGNAME PATH QUOTED SHELL USER ' ] || fail "runner environment: ${names}"
[ "$(env_of PATH)" = /home/runner/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ] && [ "$(env_of QUOTED)" = 'single quoted' ] &&
  [ "$(env_of HOME)" = /home/runner ] && [ "$(env_of LANG)" = C.UTF-8 ] || fail "runner environment values: $(cat "${tmp}/listener.env")"
send status 4
expect ok listening null 'status while the runner listens'
touch "${K}/worker"
send status 5
expect ok busy null 'status while a job runs'
rm -f "${K}/worker"
send deliver_registration 6 "${JIT}"
expect refused listening null 'a second registration'
printf 0 > "${tmp}/finish"
wait_for "${ST}/runner.exit" 'the exit record'
send status 7
expect ok job_done 0 'status after the job'
send collect 8
expect ok job_done 0 'collect'
[ "${DIAG}" = 'runner exited 0; cache unknown' ] || fail "collect diag: ${DIAG}"

# a failing runner, with the compile cache
reset; cache_overlay; firstboot
[ "$(cat "${tmp}/zc.argv")" = "init ${S}/usr/local/libexec/aap-guest/cache ${S}/var/lib/aap-cache 10737418240" ] || fail "cache init: $(cat "${tmp}/zc.argv")"
[ "$(cut -d= -f1 "${tmp}/zc.env" | grep -vx -e PWD -e SHLVL -e _ | sort | tr '\n' ' ')" = 'HOME PATH ' ] && grep -qx PATH=/usr/bin:/bin "${tmp}/zc.env" ||
  fail "cache init environment: $(cat "${tmp}/zc.env")"
grep -qxF "runuser -u runner -- env -i PATH=/usr/bin:/bin HOME=/home/runner ${S}/usr/local/libexec/aap-guest/cache/aap-zccache.sh init ${S}/usr/local/libexec/aap-guest/cache ${S}/var/lib/aap-cache 10737418240" "${tmp}/calls" ||
  fail 'cache init does not run as the job user'
[ "$(cut -d= -f1 "${ST}/runner.env" | tr '\n' ' ')" = 'AAP_ZC_STATE CMAKE_C_COMPILER_LAUNCHER ' ] || fail "cache variables: $(cat "${ST}/runner.env")"
[ "$(stat -c %a "${S}/var/lib/aap-cache")" = 700 ] || fail 'the cache job root is not 0700'
send probe 1
send deliver_registration 2 "${JIT}"
send start_runner 3
expect ok listening null 'start_runner with the cache'
wait_for "${tmp}/listener.env" 'the runner'
[ "$(env_of AAP_ZC_STATE)" = "${S}/var/lib/aap-cache/state/config.json" ] && [ -z "$(env_of RUSTC_WRAPPER)" ] && [ -z "$(env_of LD_PRELOAD)" ] ||
  fail "cache variables in the runner: $(grep -e ZC -e WRAPPER -e PRELOAD "${tmp}/listener.env")"
printf 3 > "${tmp}/finish"
wait_for "${ST}/runner.exit" 'the exit record'
send collect 4
expect ok failed 3 'collect after a failed runner'
[ "${DIAG}" = 'runner exited 3; cache direct' ] || fail "collect diag: ${DIAG}"

# the launcher alone: input that is not a JIT config starts nothing
reset; firstboot
printf 3 > "${tmp}/finish"
printf 'not a JIT config!\n' > "${tmp}/in"; agent "${tmp}/in" launch
[ "$(cat "${ST}/runner.exit")" = 97 ] && [ ! -e "${tmp}/listener.argv" ] || fail 'the launcher started a runner without a JIT config'
rm -f "${ST}/runner.exit" "${ST}/runner.pid"
send probe 1; send deliver_registration 2 "${JIT}"
wait_for "${ST}/runner.exit" 'the exit record'
send start_runner 3
expect error failed 3 'start_runner after the runner ended'
# a recorded runner pid that now names another process
reset; firstboot; send probe 1
echo "$$ 1" > "${ST}/runner.pid"
send status 2
expect ok failed null 'a runner pid reused by another process'
[ "${DIAG}" = 'runner ended without an exit record' ] || fail "lost runner diag: ${DIAG}"

# --- static files -----------------------------------------------------------------------------------------------------
for d in 'HostKey /etc/ssh/ssh_host_ed25519_key' 'PermitRootLogin forced-commands-only' 'ForceCommand /usr/local/libexec/aap-guest/agent' \
  'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PubkeyAuthentication yes' 'AllowTcpForwarding no' 'PermitTunnel no' \
  'X11Forwarding no' 'PrintMotd no' 'PrintLastLog no' 'Banner none' 'PermitTTY no' 'PermitUserEnvironment no' 'AllowUsers root'; do
  grep -qxF "${d}" "${guest}/sshd_config" || fail "sshd_config lacks: ${d}"
done
! grep -qiE '^(Include|Subsystem|AcceptEnv|HostKey .*_(rsa|ecdsa)_key)' "${guest}/sshd_config" || fail 'sshd_config has an Include, a subsystem, AcceptEnv or another host key'
grep -qx 'ListenStream=vsock::5222' "${guest}/units/aap-guest-ssh.socket" && grep -qx 'Accept=yes' "${guest}/units/aap-guest-ssh.socket" || fail 'the vsock socket'
grep -qx 'ExecStart=-/usr/sbin/sshd -i -f /etc/ssh/aap-guest/sshd_config' "${guest}/units/aap-guest-ssh@.service" || fail 'the sshd unit'
grep -qx 'ExecStart=/usr/local/libexec/aap-guest/agent firstboot' "${guest}/units/aap-guest-firstboot.service" &&
  grep -q '^After=cloud-final.service' "${guest}/units/aap-guest-firstboot.service" || fail 'the first-boot unit'
bash "${guest}/install.sh" "${tmp}/dest"
[ "$(stat -c %a "${tmp}/dest/usr/local/libexec/aap-guest/agent")" = 755 ] && cmp -s "${guest}/agent.sh" "${tmp}/dest/usr/local/libexec/aap-guest/agent" &&
  [ -f "${tmp}/dest/etc/ssh/aap-guest/sshd_config" ] && [ -f "${tmp}/dest/etc/systemd/system/aap-guest-ssh@.service" ] &&
  [ "$(readlink "${tmp}/dest/etc/systemd/system/sockets.target.wants/aap-guest-ssh.socket")" = /etc/systemd/system/aap-guest-ssh.socket ] &&
  [ "$(readlink "${tmp}/dest/etc/systemd/system/multi-user.target.wants/aap-guest-firstboot.service")" = /etc/systemd/system/aap-guest-firstboot.service ] ||
  fail 'install.sh'
# The overlay must pass P07's image secret scan (images/ubuntu-24.04/guest/aap-scan.sh, content and file-name rules).
! grep -rqE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' -e '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}' -e 'github_pat_[A-Za-z0-9_]{22,}' \
  -e 'ACTIONS_RUNNER_INPUT_JITCONFIG=' -e 'SYNTHETIC-JIT-MARKER|AAP-SYNTHETIC-SECRET-MARKER' "${tmp}/dest" || fail 'the overlay trips the image secret scan'
[ -z "$(find "${tmp}/dest" -name 'authorized_keys*' -o -name 'user-data*' -o -name '.credentials*' -o -name .runner)" ] || fail 'the overlay holds a scanned file name'

echo "PASS guests/linux agent"
