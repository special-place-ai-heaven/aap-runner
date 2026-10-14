#!/bin/bash
# systemd text: the work-disk oneshot runs after the fstab mount unit, the
# manager needs the work disk and sysbox, sysbox restarts, and bootstrap
# installs every unit and drop-in as 0644, never executable.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dir="${here}/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

has_line() {
  grep -qx -- "$2" "${dir}/$1" || fail "$1 has no line '$2'"
}

has_line aap-workdisk.service 'After=local-fs-pre.target var-lib-ghrunner.mount'
has_line aap-workdisk.service 'Restart=on-failure'
has_line aap-runner-manager.service 'Requires=docker.service aap-workdisk.service'
has_line aap-runner-manager.service 'Wants=sysbox.service'
has_line aap-runner-manager.service 'SuccessExitStatus=143'
if grep -q '^Requires=.*sysbox' "${dir}/aap-runner-manager.service"; then
  fail "the manager Requires= sysbox; a sysbox-mgr crash would stop it for good"
fi
has_line aap-runner-manager.service 'After=docker.service sysbox.service aap-workdisk.service network-online.target'
has_line aap-runner-manager.service 'Restart=on-failure'
has_line aap-runner-manager.service 'TimeoutStopSec=90'
has_line docker-workdisk.conf 'Requires=aap-workdisk.service'
has_line docker-workdisk.conf 'After=aap-workdisk.service'
has_line sysbox-restart.conf 'Restart=on-failure'
has_line sysbox-restart.conf 'RestartSec=5'
has_line sysbox-restart.conf 'StartLimitIntervalSec=0'
echo "unit lines ok"

# systemd-analyze verify on the units and drop-ins as installed. ExecStart
# points at /bin/true and docker and sysbox are stubs, so only this text is
# judged. verify exits 0 on an unknown key or a bad value, so any output fails.
if command -v systemd-analyze >/dev/null 2>&1; then
  sd=$(mktemp -d)
  for u in aap-runner-manager.service aap-workdisk.service; do
    sed 's|^ExecStart=.*|ExecStart=/bin/true|' "${dir}/${u}" > "${sd}/${u}"
  done
  for u in docker containerd sysbox sysbox-mgr sysbox-fs; do
    printf '[Service]\nType=oneshot\nExecStart=/bin/true\n' > "${sd}/${u}.service"
    mkdir "${sd}/${u}.service.d"
    cp "${dir}/docker-workdisk.conf" "${sd}/${u}.service.d/workdisk.conf"
  done
  for u in sysbox sysbox-mgr sysbox-fs; do
    cp "${dir}/sysbox-restart.conf" "${sd}/${u}.service.d/restart.conf"
  done
  # cp from /mnt/c keeps drvfs exec bits; install them as bootstrap does.
  find "${sd}" -type d -exec chmod 0755 {} +
  find "${sd}" -type f -exec chmod 0644 {} +
  rc=0
  out=$(SYSTEMD_UNIT_PATH="${sd}:" systemd-analyze verify --man=no \
    "${sd}/aap-runner-manager.service" "${sd}/aap-workdisk.service" \
    "${sd}/docker.service" "${sd}/sysbox.service" "${sd}/sysbox-mgr.service" 2>&1) || rc=$?
  rm -rf "${sd}"
  [[ "${rc}" -eq 0 && -z "${out}" ]] || fail "systemd-analyze verify (exit ${rc}): ${out}"
  echo "systemd-analyze verify ok"
else
  echo "systemd-analyze verify skipped: systemd-analyze is not installed"
fi

boot="${dir}/bootstrap.sh"
for unit in sysbox sysbox-mgr sysbox-fs; do
  grep -qx "  copy_staged sysbox-restart.conf /etc/systemd/system/${unit}.service.d/restart.conf" "${boot}" \
    || fail "bootstrap does not install restart.conf for ${unit}"
done
for unit in docker containerd sysbox sysbox-mgr sysbox-fs; do
  grep -qx "  copy_staged docker-workdisk.conf /etc/systemd/system/${unit}.service.d/workdisk.conf" "${boot}" \
    || fail "bootstrap does not install workdisk.conf for ${unit}"
done
# Join continuation lines, then every systemd file bootstrap copies must be
# in a chmod 644 and in no chmod 755.
joined=$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "${boot}")
mode644=$(grep -E "^ *chmod 644 " <<< "${joined}" | tr -s "[:space:]" " ")
mode755=$(grep -E "^ *chmod 755 " <<< "${joined}" | tr -s "[:space:]" " ")
n=0
while read -r dest; do
  n=$((n + 1))
  [[ " ${mode644} " == *" ${dest} "* ]] || fail "bootstrap does not chmod 644 ${dest}"
  [[ " ${mode755} " != *" ${dest} "* ]] || fail "bootstrap makes ${dest} executable"
done < <(awk '$1 == "copy_staged" && $3 ~ /^\/etc\/systemd\/system\// { print $3 }' "${boot}")
[[ "${n}" -eq 10 ]] || fail "expected 10 systemd files from copy_staged; found ${n}"
echo "bootstrap installs units 0644 ok"

grep -qE '^[0-9a-f]{64}  sysbox-restart.conf$' "${dir}/staging.sha256" || fail "sysbox-restart.conf is not in staging.sha256"
echo "staging list ok"

# Git modes. A file that is not committed yet has no mode to check.
if command -v git >/dev/null 2>&1 \
  && git -c safe.directory='*' -C "${dir}" rev-parse --git-dir >/dev/null 2>&1; then
  for f in "${dir}"/*.service "${dir}"/*.conf; do
    mode=$(git -c safe.directory='*' -C "${dir}" ls-files -s -- "${f##*/}" | awk '{ print $1 }')
    if [[ -z "${mode}" ]]; then
      echo "not tracked yet: ${f##*/}"
      continue
    fi
    [[ "${mode}" == 100644 ]] || fail "${f##*/} is mode ${mode} in git; want 100644"
  done
  echo "git modes ok"
else
  echo "git modes skipped: not a git checkout"
fi

echo "unit tests ok"
