#!/bin/bash
# Called by the Windows SYSTEM task. Writes one line: "<unix epoch> <free GB>".
# Both arguments are integers. Nothing else is accepted.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: aap-record-c-free-gb EPOCH GB" >&2
  exit 1
fi

epoch=$1
gb=$2
if [[ ! "${epoch}" =~ ^[0-9]+$ || ! "${gb}" =~ ^[0-9]+$ ]]; then
  echo "refusing non-integer C: free-space reading" >&2
  exit 1
fi

install -d -m 755 -o root -g root /run/aap-runner
umask 077
printf '%s %s\n' "${epoch}" "${gb}" > /run/aap-runner/c-free-gb
chmod 0400 /run/aap-runner/c-free-gb
chown root:root /run/aap-runner/c-free-gb
