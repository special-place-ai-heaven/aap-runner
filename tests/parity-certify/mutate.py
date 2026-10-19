#!/usr/bin/env python3
"""Test helper: copy a job-inventory.json and apply one deliberate change (the negative controls).

  mutate.py IN OUT OP ARGS...
  ops: copy | drop-cache NAME VER | swap-path SECTION I J | set-env NAME VALUE | set-default NAME VER
       set-service NAME KEY VALUE | set-image KEY VALUE | set-shell NAME VER | set-identity KEY VALUE
       set-infra KEY VALUE | set-hardware KEY INT | add-env NAME VALUE | drop-coverage SECTION
"""
import json, sys

src, dst, op, *a = sys.argv[1:]
d = json.load(open(src, encoding="utf-8-sig"))
if op == "copy":
    pass
elif op == "drop-cache":
    d["tool_cache"]["versions"][a[0]].remove(a[1])
elif op == "swap-path":
    p = d["path"][a[0]]
    i, j = int(a[1]), int(a[2])
    p[i], p[j] = p[j], p[i]
elif op == "set-env":
    d["env"][a[0]] = a[1]
elif op == "add-env":
    d["env"][a[0]] = a[1]
elif op == "set-default":
    d["tool_cache"]["defaults"][a[0]] = a[1]
elif op == "set-service":
    d["services"][a[0]][a[1]] = a[2]
elif op == "set-image":
    d["image"][a[0]] = a[1]
elif op == "set-shell":
    d["shells"][a[0]] = a[1]
elif op == "set-identity":
    d["run_identity"][a[0]] = a[1].split(",") if a[0] == "action_shas" else a[1]
elif op == "set-infra":
    d["infra"][a[0]] = a[1]
elif op == "set-hardware":
    d["hardware"][a[0]] = int(a[1])
elif op == "drop-coverage":
    d["coverage"].remove(a[0])
else:
    sys.exit("unknown op " + op)
json.dump(d, open(dst, "w", encoding="utf-8", newline="\n"), indent=2)
