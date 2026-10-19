"""Independently re-count a runner-images Readme and compare with inventory.json.

Usage: python -I verify_inventory.py <readme.md> <inventory.json>
Exit 0 only when every content line is covered and every per-category count matches.
Prints a Markdown table (category | source rows | recorded entries | notes | versions).
"""
import json
import re
import sys

readme, inv = sys.argv[1:3]
lines = open(readme, encoding="utf-8").read().split("\n")
doc = json.load(open(inv, encoding="utf-8"))

# --- independent pass over the Readme -------------------------------------
path = []          # heading stack [(level, title)]
src_rows = {}      # category -> number of bullets + table data rows
src_fences = {}    # category -> number of fenced blocks
content = set()    # line numbers that carry inventory content
first_table_seen = {}
in_fence = False
fence_from = 0
announce = True    # the first table (before any h2) is the announcement banner
for n, raw in enumerate(lines, 1):
    s = raw.strip()
    if in_fence:
        content.add(n)
        if s.startswith("```"):
            in_fence = False
        continue
    if s.startswith("```"):
        in_fence = True
        content.add(n)
        key = " / ".join(t for _, t in path[1:]) if path else ""
        continue
    m = re.match(r"^(#{1,4}) (.*)$", s)
    if m:
        lvl = len(m.group(1))
        while path and path[-1][0] >= lvl:
            path.pop()
        path.append((lvl, m.group(2).strip()))
        announce = False
        continue
    if not s or s == "***":
        continue
    cat = None
    # category = h3 (+ "/" + h4), or the h2 itself when it has no h3 (Windows features)
    h = [t for l, t in path]
    lv = [l for l, t in path]
    if 3 in lv and 4 in lv:
        cat = h[lv.index(3)] + "/" + h[lv.index(4)]
    elif 3 in lv:
        cat = h[lv.index(3)]
    elif 2 in lv and h[lv.index(2)] != "Installed Software":
        cat = h[lv.index(2)]
    if s.startswith("|"):
        if announce:
            continue
        if re.match(r"^\|[\s\-:|]+\|$", s):
            continue
        if cat not in first_table_seen:      # header row of this category's table
            first_table_seen[cat] = n
            content.add(n)
            continue
        src_rows[cat] = src_rows.get(cat, 0) + 1
        content.add(n)
    elif s.startswith("- "):
        if cat is None:
            content.add(n)  # image identity bullet
            continue
        src_rows[cat] = src_rows.get(cat, 0) + 1
        content.add(n)

# fenced blocks per category (count opening fences)
path = []
in_fence = False
for n, raw in enumerate(lines, 1):
    s = raw.strip()
    m = re.match(r"^(#{1,4}) (.*)$", s)
    if m and not in_fence:
        lvl = len(m.group(1))
        while path and path[-1][0] >= lvl:
            path.pop()
        path.append((lvl, m.group(2).strip()))
        continue
    if s.startswith("```"):
        if not in_fence:
            h = [t for l, t in path]
            lv = [l for l, t in path]
            if 3 in lv and 4 in lv:
                cat = h[lv.index(3)] + "/" + h[lv.index(4)]
            elif 3 in lv:
                cat = h[lv.index(3)]
            else:
                cat = h[-1]
            src_fences[cat] = src_fences.get(cat, 0) + 1
        in_fence = not in_fence

# --- compare ----------------------------------------------------------------
covered = set()
for k, v in doc["identity"].items():
    if isinstance(v, dict):
        covered.add(v["src_line"])
for c, es in doc["categories"].items():
    meta = doc["category_meta"][c]
    if meta.get("columns_line"):
        covered.add(meta["columns_line"])
    for e in es:
        if "src_line" in e:
            covered.add(e["src_line"])
        if "src_lines" in e:
            a, b = e["src_lines"]
            covered.update(range(a, b + 1))

problems = []
missing = sorted(content - covered)
if missing:
    problems.append("lines not covered: %s" % missing[:20])
extra = sorted(covered - content)
if extra:
    problems.append("covered lines that are not content: %s" % extra[:20])

print("| Category | Source rows | Recorded entries | Notes (fenced blocks) | Versions recorded |")
print("|---|---:|---:|---:|---:|")
tot_s = tot_e = tot_n = tot_v = 0
for c in doc["categories"]:
    cnt = doc["counts"][c]
    s_rows = src_rows.get(c, 0)
    s_f = src_fences.get(c, 0)
    ok = (s_rows == cnt["entries"]) and (s_f == cnt["notes"])
    if not ok:
        problems.append("%s: source rows %d/%d fences, recorded %d/%d" % (c, s_rows, s_f, cnt["entries"], cnt["notes"]))
    print("| %s | %d | %d | %d | %d |" % (c, s_rows, cnt["entries"], cnt["notes"], cnt["versions"]))
    tot_s += s_rows
    tot_e += cnt["entries"]
    tot_n += cnt["notes"]
    tot_v += cnt["versions"]
print("| **Total** | %d | %d | %d | %d |" % (tot_s, tot_e, tot_n, tot_v))
print()
print("content lines in Readme: %d, covered by entries: %d" % (len(content), len(content & covered)))

# secrets guard: any entry mentioning a password must be masked
blob = open(inv, encoding="utf-8").read()
for e_c, es in doc["categories"].items():
    for e in es:
        if re.search(r"(?i)password", e.get("raw", "")) and "REDACTED" not in e["raw"]:
            problems.append("unmasked password line in %s" % e_c)

if problems:
    print("PROBLEMS:")
    for p in problems:
        print(" -", p)
    sys.exit(1)
print("OK: all counts and line coverage match")
