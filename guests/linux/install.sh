#!/bin/bash
# Installs the P15 guest overlay (the catalog's guest-agent overlay) into an image root: P21's overlay step runs it as
# root in the build guest, or against another root as DEST. Files are root's; the units are enabled by the symlinks
# systemctl enable makes. Nothing here holds a key, a token or registration material.
#   install.sh [DEST]
set -euo pipefail
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
d=${1:-}
sd="${d}/etc/systemd/system"
install -D -m 0755 "${src}/agent.sh" "${d}/usr/local/libexec/aap-guest/agent"
install -D -m 0644 "${src}/sshd_config" "${d}/etc/ssh/aap-guest/sshd_config"
for u in aap-guest-ssh.socket aap-guest-ssh@.service aap-guest-firstboot.service; do
  install -D -m 0644 "${src}/units/${u}" "${sd}/${u}"
done
mkdir -p "${sd}/sockets.target.wants" "${sd}/multi-user.target.wants"
ln -sfn /etc/systemd/system/aap-guest-ssh.socket "${sd}/sockets.target.wants/aap-guest-ssh.socket"
ln -sfn /etc/systemd/system/aap-guest-firstboot.service "${sd}/multi-user.target.wants/aap-guest-firstboot.service"
