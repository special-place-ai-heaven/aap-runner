#!/usr/bin/env python3
"""Test helper: damage a hosted capture log.  logfilter.py IN OUT drop|echo-only STEP_PREFIX...

drop       removes every line of the named steps (the step is missing)
echo-only  keeps only the command-echo lines of the named steps (the step exists but has no output)
"""
import sys

src, dst, mode, *steps = sys.argv[1:]
out = []
for l in open(src, encoding="utf-8-sig", newline="").read().split("\n"):
    p = l.split("\t", 2)
    step = p[1] if len(p) > 2 else ""
    hit = any(step.startswith(s) for s in steps)
    if hit and mode == "drop":
        continue
    if hit and mode == "echo-only" and "[36;1m" not in l:
        continue
    out.append(l)
open(dst, "w", encoding="utf-8", newline="").write("\n".join(out))
