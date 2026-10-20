#!/bin/bash
# P07 secret scan of the sealed Ubuntu disk. Runs as root in the SCANNER guest: the pinned Ubuntu live-server ISO booted with
# no network and no disk; the host hot-adds the sealed disk (a differencing child) once this live system answers, so firmware
# never boots the sealed image in its place. This script, the agent and the build token to look for come from host-built
# seeds. The host never mounts a guest file system; this guest's own (trusted, pinned) kernel parses the guest-authored ext4,
# mounted read-only without journal replay, and the EFI partition, mounted read-only over the image's /boot/efi. Writes one
# JSON document (--out) with rule and path findings, never matched values.
#   aap-scan.sh --known-file <file holding the 64 hex token> --out <file> [--disk /dev/sda] [--target <dir>]
# --target (tests only) scans an existing folder instead of mounting --disk. AAP_SCAN_WAIT: seconds to wait for the disk.
set -u
export LC_ALL=C
KNOWN_FILE=''
OUT=''
DISK=/dev/sda
TARGET=''
MNT=/mnt/aap-target
LARGE_SIZE=33554432   # files over 32 MiB are content-scanned like every other file and also listed with size and SHA-256
LIST_MAX=200
LARGE_MAX=10000
WAIT=${AAP_SCAN_WAIT:-120}
EFI_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
ROOT_TYPE=0fc63daf-8483-4772-8e79-3d69d8477de4
while [ $# -gt 0 ]; do
  case "$1" in
    --known-file) KNOWN_FILE=${2:-}; shift 2 ;;
    --out) OUT=${2:-}; shift 2 ;;
    --disk) DISK=${2:-}; shift 2 ;;
    --target) TARGET=${2:-}; shift 2 ;;
    *) echo "aap-scan: unknown argument $1"; exit 2 ;;
  esac
done
KNOWN=''
[ ! -r "${KNOWN_FILE}" ] || KNOWN=$(head -c 65 "${KNOWN_FILE}")
[[ ${KNOWN} =~ ^[0-9a-f]{64}$ ]] || { echo 'aap-scan: --known-file must hold the 64 hex build token'; exit 2; }   # check:scan-known
[ -n "${OUT}" ] || { echo 'aap-scan: --out is required'; exit 2; }

js() { # JSON string of $1 as printable ASCII, at most 400 characters
  local s="${1//[^ -~]/?}"
  s="${s:0:400}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf '"%s"' "${s}"
}
layout_refused() {
  printf '{"schema":1,"layout":"unexpected","detail":%s}\n' "$(js "$1")" > "${OUT}"
  echo "aap-scan: layout: $1"
  exit 3
}

# The disk the builder's autoinstall made: GPT with exactly an EFI partition (FAT) and an ext4 root, numbers 1 and 2. A
# guest can re-partition its own disk; anything else is refused, so a decoy partition is never scanned in place of the real
# root. A root whose journal still needs replay is refused too: every clone would replay it, this read-only mount would not.
if [ -z "${TARGET}" ]; then
  name=${DISK##*/}
  for ((i = 0; i < WAIT; i++)); do [ -b "${DISK}" ] && break; sleep 1; done
  udevadm settle > /dev/null 2>&1 || true
  [ -b "${DISK}" ] || layout_refused "${DISK} is not a block device"   # check:scan-disk
  parts=$(cd "/sys/block/${name}" && ls -d "${name}"* 2>/dev/null | tr '\n' ' ')
  [ "${parts}" = "${name}1 ${name}2 " ] || layout_refused "partitions are ${parts}"
  [ "$(blkid -p -o value -s PART_ENTRY_TYPE "${DISK}1")" = "${EFI_TYPE}" ] || layout_refused 'partition 1 is not EFI'
  [ "$(blkid -p -o value -s TYPE "${DISK}1")" = vfat ] || layout_refused 'partition 1 is not FAT'
  [ "$(blkid -p -o value -s PART_ENTRY_TYPE "${DISK}2")" = "${ROOT_TYPE}" ] || layout_refused 'partition 2 is not a Linux file system'
  [ "$(blkid -p -o value -s TYPE "${DISK}2")" = ext4 ] || layout_refused 'partition 2 is not ext4'
  if dumpe2fs -h "${DISK}2" 2> /dev/null | grep -q '^Filesystem features:.*needs_recovery'; then layout_refused 'the root file system journal needs recovery'; fi
  mkdir -p "${MNT}"
  mount -t ext4 -o ro,noload,nodev,nosuid,noexec "${DISK}2" "${MNT}" || layout_refused 'the root file system does not mount read-only'
  TARGET=${MNT}
  trap 'umount "${MNT}"' EXIT
  # mount follows links, so /boot/efi must be a plain folder of the image, not a link out of it.
  if [ -L "${MNT}/boot" ] || [ -L "${MNT}/boot/efi" ] || [ ! -d "${MNT}/boot/efi" ] || [ "$(realpath -e "${MNT}/boot/efi")" != "${MNT}/boot/efi" ]; then
    layout_refused '/boot/efi is not a plain folder'
  fi
  mount -t vfat -o ro,nodev,nosuid,noexec "${DISK}1" "${MNT}/boot/efi" || layout_refused 'the EFI partition does not mount read-only'
fi

name_rule() { # leaf -> rule id or nothing
  case "$1" in
    .credentials*) echo runner-credentials ;;
    .runner) echo runner-config ;;
    ssh_host_*_key) echo ssh-host-key ;;
    authorized_keys|authorized_keys2) echo ssh-authorized-keys ;;
    .bash_history|.zsh_history|.python_history|.sh_history|.psql_history|.mysql_history|ConsoleHost_history.txt) echo shell-history ;;
    app.pem) echo app-key ;;
    user-data|meta-data|network-config|vendor-data|user-data.txt|vendor-data.txt) echo cloud-init-seed ;;
    autoinstall-user-data|autoinstall.yaml) echo installer-answers ;;
    ovf-env.xml) echo azure-provisioning-data ;;
  esac
}
path_rule() { # relative path -> rule id or nothing: anything left of the build agent, its state or its units
  case "$1" in
    var/lib/aap-build/*|usr/local/libexec/aap-build/*|etc/systemd/*aap-agent*) echo build-agent ;;
  esac
}
CONTENT_RULES=(
  'pem-private-key|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'github-token|(^|[^A-Za-z0-9_])(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}([^A-Za-z0-9_]|$)'
  'github-pat|github_pat_[A-Za-z0-9_]{22,}'
  'jit-config|ACTIONS_RUNNER_INPUT_JITCONFIG='
  'synthetic-marker|AAP-SYNTHETIC-SECRET-MARKER|SYNTHETIC-JIT-MARKER'
)
wide=''
for ((i = 0; i < ${#KNOWN}; i++)); do wide+="${KNOWN:i:1}\\x00"; done
ANY=()
for r in "${CONTENT_RULES[@]}"; do ANY+=(-e "${r#*|}"); done
ANY+=(-e "${KNOWN}")

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"; if [ "${TARGET}" = "${MNT}" ]; then umount "${MNT}/boot/efi" 2> /dev/null; umount "${MNT}"; fi' EXIT
findings=0; scanned=0; large=0; unreadable=0
: > "${tmp}/findings"; : > "${tmp}/large"; : > "${tmp}/unreadable"; : > "${tmp}/content"; : > "${tmp}/gz"
add_finding() { # rule relative-path; a link is hashed by its target text, never followed
  local sha
  if [ -L "${TARGET}/$2" ]; then sha=$(readlink "${TARGET}/$2" | sha256sum | cut -d' ' -f1)
  else sha=$(sha256sum < "${TARGET}/$2" 2> /dev/null | cut -d' ' -f1); fi
  findings=$((findings + 1))
  [ "${findings}" -gt "${LIST_MAX}" ] || printf '{"rule":%s,"path":%s,"sha256":"%s"}\n' "$(js "$1")" "$(js "$2")" "${sha:-unreadable}" >> "${tmp}/findings"
}

# Every regular file and link, without following any link (find -P); the EFI partition is mounted inside the tree.
find -P "${TARGET}" \( -type f -o -type l \) -printf '%y %s %P\0' 2> "${tmp}/find.err" > "${tmp}/files"
while IFS= read -r -d '' rec; do
  type=${rec%% *}; rec=${rec#* }; size=${rec%% *}; rel=${rec#* }
  rule=$(name_rule "${rel##*/}")
  [ -z "${rule}" ] || add_finding "${rule}" "${rel}"   # check:scan-names
  rule=$(path_rule "${rel}")
  [ -z "${rule}" ] || add_finding "${rule}" "${rel}"   # check:scan-paths
  [ "${type}" = f ] || continue
  [[ ${rel} != etc/sudoers.d/* ]] || ! grep -Eqs '^[^#]*NOPASSWD' "${TARGET}/${rel}" || add_finding build-sudoers "${rel}"   # check:scan-sudoers
  [ "${rel}" != etc/shadow ] || ! cut -d: -f2 "${TARGET}/etc/shadow" | grep -q '^\$' || add_finding shadow-password-hash "${rel}"   # check:scan-shadow
  if [ "${size}" -gt "${LARGE_SIZE}" ]; then
    large=$((large + 1))
    if [ "${large}" -le "${LARGE_MAX}" ]; then
      sha=$(sha256sum < "${TARGET}/${rel}" 2> /dev/null | cut -d' ' -f1) || sha=''
      if [ -z "${sha}" ]; then unreadable=$((unreadable + 1)); printf '%s\n' "$(js "${rel}")" >> "${tmp}/unreadable"
      else printf '{"path":%s,"bytes":%s,"sha256":"%s"}\n' "$(js "${rel}")" "${size}" "${sha}" >> "${tmp}/large"; fi
    fi
  fi
  printf '%s\0' "${rel}" >> "${tmp}/content"
  [[ ${rel} != *.gz ]] || printf '%s\0' "${rel}" >> "${tmp}/gz"
  scanned=$((scanned + 1))
done < "${tmp}/files"
while IFS= read -r line; do
  unreadable=$((unreadable + 1))
  [ "${unreadable}" -gt "${LIST_MAX}" ] || printf '%s\n' "$(js "${line}")" >> "${tmp}/unreadable"
done < "${tmp}/find.err"

# Content rules over every regular file, whatever its size; grep -a reads binary files as text and never follows links.
# Two passes over everything (every text rule and the token at once, then the token in UTF-16) find the candidate files;
# each rule then runs over the candidates only.
grepz() { # grep options... over the NUL-separated list on stdin, relative to the target: matching paths, NUL-separated
  (cd "${TARGET}" && xargs -0 -r grep -l -a -Z "$@" -- 2>> "${tmp}/grep.err")
}
{ grepz -E "${ANY[@]}" < "${tmp}/content"; grepz -P "${wide}" < "${tmp}/content"; } | sort -zu > "${tmp}/cand"
content() { # rule grep-option pattern
  local rel
  while IFS= read -r -d '' rel; do add_finding "$1" "${rel}"; done < <(grepz "$2" -e "$3" < "${tmp}/cand")
}
for r in "${CONTENT_RULES[@]}"; do [ -z "${r}" ] || content "${r%%|*}" -E "${r#*|}"; done   # check:scan-content
[ -z "${KNOWN}" ] || content build-credential -F "${KNOWN}"   # check:scan-known-ascii
[ -z "${wide}" ] || content build-credential -P "${wide}"   # check:scan-known-wide
# Compressed logs and documents: each .gz decompressed in a stream, checked once against everything, then rule by rule.
while IFS= read -r -d '' rel; do
  f="${TARGET}/${rel}"
  zcat -f -- "${f}" 2>> "${tmp}/grep.err" | grep -q -a -E "${ANY[@]}" || zcat -f -- "${f}" 2> /dev/null | grep -q -a -P "${wide}" || continue
  for r in "${CONTENT_RULES[@]}"; do ! zcat -f -- "${f}" 2> /dev/null | grep -q -a -E -e "${r#*|}" || add_finding "${r%%|*}" "${rel}"; done   # check:scan-gz-rules
  ! zcat -f -- "${f}" 2> /dev/null | grep -q -a -F -e "${KNOWN}" || add_finding build-credential "${rel}"   # check:scan-gz-known
  ! zcat -f -- "${f}" 2> /dev/null | grep -q -a -P -e "${wide}" || add_finding build-credential "${rel}"   # check:scan-gz-wide
done < "${tmp}/gz"
if [ -s "${tmp}/grep.err" ]; then
  while IFS= read -r line; do
    unreadable=$((unreadable + 1))
    [ "${unreadable}" -gt "${LIST_MAX}" ] || printf '%s\n' "$(js "${line}")" >> "${tmp}/unreadable"
  done < "${tmp}/grep.err"
fi

joined() { local f=$1; paste -sd, "${f}"; }
{
  printf '{"schema":1,"layout":"ok","files_scanned":%s,' "${scanned}"
  printf '"findings_count":%s,"findings":[%s],' "${findings}" "$(joined "${tmp}/findings")"
  printf '"unreadable_count":%s,"unreadable":[%s],' "${unreadable}" "$(joined "${tmp}/unreadable")"
  printf '"large_files_count":%s,"large_files":[%s],' "${large}" "$(joined "${tmp}/large")"
  printf '"rules":["runner-credentials","runner-config","ssh-host-key","ssh-authorized-keys","shell-history","app-key","cloud-init-seed",'
  printf '"installer-answers","azure-provisioning-data","shadow-password-hash","pem-private-key","github-token","github-pat","jit-config",'
  printf '"synthetic-marker","build-credential","build-agent","build-sudoers"]}\n'
} > "${OUT}"
echo "aap-scan: ${scanned} files content-scanned, ${findings} findings, ${unreadable} unreadable, ${large} large"
