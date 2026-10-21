#!/bin/bash
# Mutation check for the P07 guest scripts: every guard in images/ubuntu-24.04/guest/*.sh carries '# check:<name>'. For each
# name this copies the guest folder, disables that guard on every line tagged with it (the first '|| ' becomes
# '|| true || ', so the guarded action never runs; a line without '||' has its 'return 1' or 'exit 1' replaced by 'true'),
# and runs guest_test.sh against the copy. A guard is covered only if the tests then fail. Exit 0 when every guard is.
#   bash tests/images/ubuntu-24.04/guest_mutations.sh [name...]
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guest=$(cd "${here}/../../../images/ubuntu-24.04/guest" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

mapfile -t tags < <(grep -ho '# check:[a-z-]*' "${guest}"/*.sh | sed 's/# check://' | sort -u)
[ $# -eq 0 ] || tags=("$@")
killed=0; bad=0
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
        else:
            lines[i] = line.replace('exit 1', 'true', 1)
    open(path, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))
if hits == 0:
    sys.exit('no line tagged ' + tag)
EOF
  if AAP_GUEST_DIR="${tmp}/g" bash "${here}/guest_test.sh" > "${tmp}/log" 2>&1; then
    printf '%-24s SURVIVED\n' "${tag}"; bad=$((bad + 1))
  else
    printf '%-24s KILLED   %s\n' "${tag}" "$(grep -m1 '^FAIL' "${tmp}/log" | cut -c1-90)"; killed=$((killed + 1))
  fi
done
echo "GUEST MUTATIONS checks=${#tags[@]} killed=${killed} not_killed=${bad}"
[ "${bad}" = 0 ]
