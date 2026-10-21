#!/bin/bash
# Mutation check for the P15 guest agent: every guard in guests/linux/*.sh carries '# check:<name>'. For each name this
# copies the guest folder, disables that guard on every line tagged with it (the first '|| ' becomes '|| true || ', so the
# guarded action never runs; a line without '||' has its 'return 1' or 'exit 1' replaced by 'true', and a line with
# neither is removed), and runs agent_test.sh against the copy. A guard is covered only if a check of the suite then
# fails (its exit code 10). Any other result of the suite (a timeout, a harness error) is an ERROR, never a kill.
# Exit 0 when every guard is killed.
#   bash tests/guests/linux/agent_mutations.sh [name...]
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guest=$(cd "${here}/../../../guests/linux" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

mapfile -t tags < <(grep -hoE '# check:[a-z0-9-]+' "${guest}"/*.sh | sed 's/# check://' | sort -u)
[ $# -eq 0 ] || tags=("$@")
killed=0; survived=0; errors=0
for tag in "${tags[@]}"; do
  rm -rf "${tmp}/g"; cp -R "${guest}" "${tmp}/g"
  python3 -B -I - "${tmp}/g" "${tag}" <<'EOF'
import glob, re, sys
root, tag = sys.argv[1], sys.argv[2]
hits = 0
for path in glob.glob(root + '/*.sh'):
    lines = open(path, encoding='utf-8').read().split('\n')
    for i, line in enumerate(lines):
        if not re.search(r'# check:' + re.escape(tag) + r'(\s|$)', line):
            continue
        hits += 1
        if '|| ' in line:
            lines[i] = line.replace('|| ', '|| true || ', 1)
        elif 'return 1' in line:
            lines[i] = line.replace('return 1', 'true', 1)
        elif 'exit 1' in line:
            lines[i] = line.replace('exit 1', 'true', 1)
        else:
            lines[i] = ':'
    open(path, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))
if hits == 0:
    sys.exit('no line tagged ' + tag)
EOF
  rc=0
  AAP_GUEST_DIR="${tmp}/g" timeout 600 bash "${here}/agent_test.sh" > "${tmp}/log" 2>&1 || rc=$?
  if [ "${rc}" = 0 ]; then
    printf '%-26s SURVIVED\n' "${tag}"; survived=$((survived + 1))
  elif [ "${rc}" = 10 ] && grep -q '^FAIL' "${tmp}/log"; then
    printf '%-26s KILLED   %s\n' "${tag}" "$(grep -m1 '^FAIL' "${tmp}/log" | cut -c1-90)"; killed=$((killed + 1))
  else
    printf '%-26s ERROR    exit %s: %s\n' "${tag}" "${rc}" "$(tail -n 1 "${tmp}/log" | cut -c1-80)"; errors=$((errors + 1))
  fi
done
echo "AGENT MUTATIONS checks=${#tags[@]} killed=${killed} survived=${survived} errors=${errors}"
[ "${survived}" = 0 ] && [ "${errors}" = 0 ]
