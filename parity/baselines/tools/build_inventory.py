"""Parse an actions/runner-images software Readme into inventory.json.

Usage (treat the inputs as untrusted data, run with -I):
  python -I build_inventory.py <readme.md> <toolset.json> <out.json> <profile> <commit> <readme_url>

Every content line of the Readme becomes one entry carrying its source line number
and the verbatim text (`raw`), so tools/verify_inventory.py can prove line coverage.
Lines that contain a password are masked (policy: no secret values in this repo).
"""
import fnmatch
import hashlib
import json
import re
import sys

MASK = "<<REDACTED: upstream-documented credential, see source line>>"
DOTTED = re.compile(r"^\d[\w.+~()\-]*\.\d[\w.+~()\-]*$")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def clean_default(text):
    if "(default)" in text:
        return text.replace("(default)", "").strip(), True
    return text, False


def parse_bullet(raw, cat):
    text, default = clean_default(raw)
    e = {"raw": raw}
    if default:
        e["default"] = True
    m = re.match(r"^(.*?) \(build from commit (\w+)\)$", text)
    if m:
        e.update(name=m.group(1), versions=["build from commit " + m.group(2)])
        return e
    m = re.match(r"^([^:]+):\s+(.+)$", text)
    if m and "http" not in text:
        e.update(name=m.group(1), versions=[v.strip() for v in m.group(2).split(",")])
        return e
    if cat.startswith("Cached Tools/") or cat == "Installed Windows SDKs" or cat.endswith("Installed Windows SDKs"):
        e.update(name=cat.split("/")[-1], versions=[text])
        return e
    toks = text.split(" ")
    for i in range(1, len(toks)):
        if DOTTED.match(toks[i]):
            e["name"] = " ".join(toks[:i])
            e["versions"] = [toks[i]]
            rest = " ".join(toks[i + 1:]).strip()
            if rest:
                e["notes"] = rest.lstrip("- ").strip()
            return e
    e.update(name=text, versions=[], unparsed=True)
    return e


def split_row(line):
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    return cells


def parse_table_row(cols, cells, raw, cat):
    e = {"raw": raw}
    attrs = dict(zip(cols, cells))
    first = cols[0]
    if first in ("Name", "Package", "Package Name", "Property"):
        e["name"] = cells[0]
    elif first == "Version":
        e["name"] = cat.split("/")[-1]
    else:
        e["name"] = cells[0]
    vcol = next((c for c in cols if c in ("Version", "Versions")), None)
    if vcol:
        v = attrs[vcol]
        parts = [p.strip() for p in v.split("<br>")]
        if e["name"] == "Android SDK Build-tools":
            parts = [x for p in parts for x in p.split()]
        vs, defs = [], []
        for p in parts:
            p2, d = clean_default(p)
            vs.append(p2)
            if d:
                defs.append(p2)
        e["versions"] = vs
        if defs:
            e["default"] = True
            e["default_versions"] = defs
    if e["name"] == "Password" or "password" in e["name"].lower():
        for k in list(attrs):
            if k != first:
                attrs[k] = MASK
        e["redacted"] = True
        e["raw"] = "| " + " | ".join(
            [cells[0]] + [MASK] * (len(cells) - 1)) + " |"
    e["attrs"] = {k: v for k, v in attrs.items() if not (vcol and k == vcol)}
    return e


def toolset_default_match(tool, version):
    d = tool.get("default")
    if not d:
        return False
    if any(ch in d for ch in "*?"):
        return fnmatch.fnmatch(version, d)
    return version == d or version.startswith(d + ".")


def main():
    readme, toolset, out, profile, commit, url = sys.argv[1:7]
    lines = open(readme, encoding="utf-8").read().split("\n")
    ts = json.load(open(toolset, encoding="utf-8"))
    cats = {}
    order = []
    identity = {}
    announcements = []
    cur = None
    h2 = h3 = None
    in_fence = False
    fence_start = 0
    fence_buf = []
    table = None  # [cols, header_line_no]
    unexpected = []

    def add(entry):
        cats[cur]["entries"].append(entry)

    for n, line in enumerate(lines, 1):
        s = line.rstrip()
        if in_fence:
            if s.startswith("```"):
                in_fence = False
                txt = []
                masked = False
                for ln in fence_buf:
                    if "password" in ln.lower():
                        k = ln.split(":")[0]
                        txt.append(k + ": " + MASK)
                        masked = True
                    else:
                        txt.append(ln)
                note = {"kind": "note", "name": "note", "raw": "\n".join(txt),
                        "src_lines": [fence_start, n]}
                if masked:
                    note["redacted"] = True
                if cur is None:
                    unexpected.append((fence_start, "fence outside category"))
                else:
                    add(note)
                fence_buf = []
            else:
                fence_buf.append(s)
            continue
        if s.startswith("```"):
            in_fence = True
            fence_start = n
            fence_buf = []
            continue
        if not s.strip() or s.strip() == "***":
            table = None
            continue
        if s.startswith("# "):
            title = s[2:].strip()
            identity["os_title"] = title
            cur = None
            table = None
            continue
        m = re.match(r"^(#{2,4}) (.+)$", s)
        if m:
            lvl, title = len(m.group(1)), m.group(2).strip()
            table = None
            if lvl == 2:
                h2, h3 = title, None
                cur = title if title != "Installed Software" else None
            elif lvl == 3:
                h3 = title
                cur = title
            else:
                cur = (h3 + "/" + title) if h3 else title
            if cur is not None and cur not in cats:
                cats[cur] = {"heading_line": n, "level": lvl, "entries": []}
                order.append(cur)
            continue
        if s.startswith("|"):
            if table is None:
                table = [split_row(s), n]
                if cur is None and not cats.get("__announce__"):
                    announcements.append(s)
                    table = ["ANN", n]
                    continue
                cats[cur]["columns"] = table[0]
                cats[cur]["columns_line"] = n
                continue
            if table[0] == "ANN":
                announcements.append(s)
                continue
            if re.match(r"^\|[\s\-:|]+\|$", s):
                continue
            cells = split_row(s)
            e = parse_table_row(table[0], cells, s, cur)
            e["src_line"] = n
            add(e)
            continue
        if s.startswith("- "):
            body = s[2:].strip()
            if cur is None:
                k, _, v = body.partition(":")
                identity[k.strip()] = {"value": v.strip(), "src_line": n}
                continue
            e = parse_bullet(body, cur)
            e["src_line"] = n
            if "password" in body.lower():
                e["raw"] = MASK
                e["redacted"] = True
            add(e)
            continue
        if s.startswith("| ") or s.startswith("***"):
            continue
        unexpected.append((n, s[:80]))

    # toolset defaults on cached tools
    tc = {t["name"].lower(): t for t in ts.get("toolcache", [])}
    for c, body in cats.items():
        if c.startswith("Cached Tools/"):
            tool = tc.get(c.split("/")[-1].lower().replace(".", "").replace("js", ""))
            if tool is None:
                tool = tc.get(c.split("/")[-1].lower())
            if tool and tool.get("default"):
                for e in body["entries"]:
                    if e.get("kind") == "note":
                        continue
                    if toolset_default_match(tool, e["versions"][0].split(" ")[0]):
                        e["default"] = True
                        e["default_source"] = "toolset.toolcache[%s].default=%s" % (tool["name"], tool["default"])

    counts = {}
    for c in order:
        es = cats[c]["entries"]
        counts[c] = {
            "entries": len([e for e in es if e.get("kind") != "note"]),
            "notes": len([e for e in es if e.get("kind") == "note"]),
            "versions": sum(len(e.get("versions", [])) for e in es),
        }
    doc = {
        "schema": 1,
        "profile": profile,
        "source": {
            "readme_url": url,
            "runner_images_commit": commit,
            "readme_sha256": sha256(readme),
            "toolset_sha256": sha256(toolset),
        },
        "identity": identity,
        "announcements_not_inventory": announcements,
        "toolset_defaults": {
            "toolcache": ts.get("toolcache"),
            "java": ts.get("java"),
            "node": ts.get("node"),
            "note": "toolset.json at the pin; see README for pin vs build-commit differences",
        },
        "counts": counts,
        "categories": {c: cats[c]["entries"] for c in order},
        "category_meta": {c: {k: v for k, v in cats[c].items() if k != "entries"} for c in order},
        "unexpected_lines": unexpected,
    }
    json.dump(doc, open(out, "w", encoding="utf-8", newline="\n"), indent=1, ensure_ascii=False)
    open(out, "a", encoding="utf-8", newline="\n").write("\n")
    bad = [(c, e["raw"]) for c in order for e in cats[c]["entries"] if e.get("unparsed")]
    print("categories", len(order), "entries", sum(v["entries"] for v in counts.values()),
          "notes", sum(v["notes"] for v in counts.values()), "unparsed", bad, "unexpected", unexpected)


main()
