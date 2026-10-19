#!/usr/bin/env python3
"""Test helper: copy a job-inventory.json and apply one deliberate change (the negative controls).

  mutate.py IN OUT OP ARGS...
  ops: copy | drop-cache NAME VER | drop-default NAME | swap-path SECTION I J | insert-path SECTION INDEX VALUE
       append-path SECTION VALUE | set-env NAME VALUE | add-env NAME VALUE | set-default NAME VER
       set-service NAME KEY VALUE | add-service NAME STATUS START | add-command NAME PATH | set-image KEY VALUE
       set-shell NAME VER | set-identity KEY VALUE | set-infra KEY VALUE | set-hardware KEY INT
       set-limit KEY VALUE (read_ahead_kb takes a comma list) | drop-coverage SECTION | empty-section SECTION
"""
import json, sys

src, dst, op, *a = sys.argv[1:]
d = json.load(open(src, encoding="utf-8-sig"))
if op == "copy":
    pass
elif op == "drop-cache":
    d["tool_cache"]["versions"][a[0]].remove(a[1])
elif op == "drop-default":
    del d["tool_cache"]["defaults"][a[0]]
elif op == "swap-path":
    p = d["path"][a[0]]
    i, j = int(a[1]), int(a[2])
    p[i], p[j] = p[j], p[i]
elif op == "insert-path":
    d["path"][a[0]].insert(int(a[1]), a[2])
elif op == "append-path":
    d["path"][a[0]].append(a[1])
elif op in ("set-env", "add-env"):
    d["env"][a[0]] = a[1]
elif op == "set-default":
    d["tool_cache"]["defaults"][a[0]] = a[1]
elif op == "set-service":
    d["services"][a[0]][a[1]] = a[2]
elif op == "add-service":
    d["services"][a[0]] = {"status": a[1], "start_type": a[2]} if "status" in next(iter(d["services"].values())) else {"enabled": a[1], "active": a[2]}
elif op == "add-command":
    d["command_paths"][a[0]] = a[1]
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
elif op == "set-limit":
    d["limits"][a[0]] = a[1].split(",") if a[0] == "read_ahead_kb" else a[1]
elif op == "drop-coverage":
    d["coverage"].remove(a[0])
elif op == "empty-cache":
    d["tool_cache"]["versions"] = {}
elif op == "empty-section":
    d[a[0]] = {} if isinstance(d[a[0]], dict) else []
else:
    sys.exit("unknown op " + op)
json.dump(d, open(dst, "w", encoding="utf-8", newline="\n"), indent=2)
