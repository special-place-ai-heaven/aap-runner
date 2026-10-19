#!/usr/bin/env python3
"""P05 differential certification harness (stdlib only; run as `python -I certify.py <cmd>`).

Commands
  parse-hosted-log LOG --out F     hosted capture log (hosted-reference-*.yml output) -> job-inventory.json
  parse-readme INVENTORY --out F   P01 inventory.json (Readme) -> job-inventory.json, overlapping categories only
  compare --reference F --candidate F   inventory diff + identity checks (inventory section only)
  run-workloads --defs P --out F   run workload definitions, write workload-results.json (+ logs)
  certify ...                      inventory + identity + behaviour -> report + evidence records (validated)

Exit: 0 pass, 1 certification failed, 2 bad input, 3 evidence records invalid.
Inventory and behaviour are separate sections; neither can substitute for the other (see certify).
"""
import argparse, datetime, fnmatch, glob, hashlib, json, os, re, shutil, subprocess, sys, tempfile, time

SCHEMA = 1
# Differences in these classes fail certification. `extra` and `documented-rig-difference` never do.
FAILING = {"missing-required", "version-mismatch", "default-mismatch", "path-order", "env-mismatch",
           "service-mismatch", "identity-mismatch"}
# the archived logs carry the escape as a literal "^[" (cat -v form); a real ESC is handled too
ESC = r"(?:\x1b|\^\[)"
ANSI = re.compile(ESC + r"\[[0-9;]*[A-Za-z]")
TS = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")
UNKNOWN = ("<denied>", None)


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def load(p):
    with open(p, "rb") as f:
        return json.loads(f.read().decode("utf-8-sig"))


def dump(obj, p):
    os.makedirs(os.path.dirname(os.path.abspath(p)), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, indent=2, ensure_ascii=True)
        f.write("\n")


def die(msg, code=2):
    print("certify: " + msg, file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------- inventory shape

def new_inventory(source_type, ref):
    return {"schema": SCHEMA, "kind": "job-inventory", "source": {"type": source_type, "ref": ref},
            "coverage": [], "image": {}, "infra": {}, "run_identity": {"source_sha": None, "workflow_sha": None, "action_shas": []},
            "user": {}, "env": {}, "credential_env": {}, "path": {"process": [], "machine": []},
            "shells": {}, "tools": {}, "command_paths": {}, "tool_cache": {"root": None, "versions": {}, "defaults": {}},
            "action_archive_cache": [], "services": {}, "docker": {}, "hardware": {}, "limits": {}}


def _norm(p):
    return p.replace("\\", "/").rstrip("/").lower()


def derive_defaults(inv):
    """Default cached version per tool = first process-PATH entry under <root>/<name>/<ver>/, else JAVA_HOME for Java.
    Same rule as both probes."""
    tc = inv["tool_cache"]
    root = tc.get("root")
    out = {}
    if not root:
        return out
    r = _norm(root) + "/"
    paths = [_norm(p) for p in inv["path"]["process"]] + [_norm(inv["env"].get("JAVA_HOME") or "") + "/bin"]
    for p in paths:
        if not p.startswith(r):
            continue
        parts = p[len(r):].split("/")
        if len(parts) < 2:
            continue
        for name, vers in tc["versions"].items():
            if name.lower() == parts[0]:
                for v in vers:
                    if v.lower() == parts[1]:
                        out.setdefault(name, v)
    return out


# ---------------------------------------------------------------- hosted-log parser

def _steps(path):
    steps, order = {}, []
    with open(path, encoding="utf-8-sig") as f:
        text = f.read()
    skip_env = False
    cur = None
    for raw in text.splitlines():
        p = raw.split("\t", 2)
        if len(p) < 3:
            continue
        step, t = p[1], TS.sub("", p[2].lstrip("﻿"), 1)
        if step != cur:
            cur, skip_env = step, False
        if re.search(ESC + r"\[36;1m", t):  # command echo
            continue
        t = ANSI.sub("", t).rstrip("\r")
        if step != "Set up job" and (t.startswith("##[group]") or t.startswith("##[endgroup]") or t.startswith("shell:")):
            continue
        if t.startswith("env:"):
            skip_env = True
            continue
        if skip_env and t.startswith("  "):
            continue
        skip_env = False
        if step not in steps:
            steps[step] = []
            order.append(step)
        steps[step].append(t)
    return steps


def _step(steps, prefix):
    for k, v in steps.items():
        if k.startswith(prefix):
            return v
    return []


def _kv(lines):
    d = {}
    for l in lines:
        m = re.match(r"^([A-Za-z0-9_]+)=(.*)$", l)
        if m:
            d[m.group(1)] = m.group(2)
    return d


def _path_list(lines, header):
    out, on = [], False
    for l in lines:
        if l.startswith("--- "):
            on = header in l
            continue
        m = re.match(r"^\s*\d+[\s\t](.*)$", l) if on else None
        if m and m.group(1):
            out.append(m.group(1))
    return out


def _bytes(s):
    """df -h style size ('86G') -> approximate bytes."""
    m = re.match(r"^([\d.]+)([KMGT]?)$", s)
    return int(float(m.group(1)) * 1024 ** ("BKMGT".index(m.group(2) or "B"))) if m else None


def parse_hosted_log(path, a):
    steps = _steps(path)
    inv = new_inventory("hosted-log", os.path.basename(path))
    su = _step(steps, "Set up job")
    grp, prov = None, {}
    for l in su:
        m = re.match(r"^Current runner version: '([^']+)'", l)
        if m:
            inv["image"]["runner_version"] = m.group(1)
        if l.startswith("##[group]"):
            grp = l[9:]
            continue
        if l.startswith("##[endgroup]"):
            grp = None
            continue
        m = re.match(r"^([A-Za-z ]+): (.*)$", l)
        if grp == "Runner Image Provisioner" and m:
            prov[m.group(1)] = m.group(2)
        if grp == "Runner Image" and m and m.group(1) == "Image":
            inv["image"]["label"] = m.group(2)
        if grp == "Runner Image" and m and m.group(1) == "Version":
            inv["image"]["image_version"] = m.group(2)
    inv["infra"] = {"provisioner_version": prov.get("Version"), "provisioner_commit": prov.get("Commit"),
                    "region": prov.get("Region"), "cloud": prov.get("Cloud"), "worker_id": prov.get("Worker ID")}
    win = inv["image"].get("label", "").startswith("windows")

    ident = _step(steps, "Image identity")
    kv = _kv(ident)
    inv["image"]["image_os"] = kv.get("ImageOS")
    for part in " ".join(l for l in ident if l.startswith("RUNNER_OS=")).split():
        k, _, v = part.partition("=")
        inv["image"][{"RUNNER_OS": "runner_os", "RUNNER_ARCH": "runner_arch", "RUNNER_ENVIRONMENT": "runner_environment"}[k]] = v
    for l in ident:
        m = re.match(r"^Caption\s*:\s*(.*)$", l)
        if m:
            inv["image"]["os_name"] = m.group(1).strip()
        m = re.match(r"^Version\s*:\s*(\S+)$", l)
        if m:
            inv["image"]["os_build"] = m.group(1)
        m = re.match(r"^os=(.*)$", l)
        if m:
            inv["image"]["os_name"] = m.group(1)
        if re.match(r"^\d+\.\d+\.\d+-\S+$", l):
            inv["image"]["kernel"] = l
        m = re.match(r"^systemd \d+ \(([^)]+)\)", l)
        if m:
            inv["tools"]["systemd"] = m.group(1)

    hw = _step(steps, "Hardware class")
    h = _kv(hw)
    if win:
        inv["hardware"] = {"logical_processors": int(h["logical_processors"]), "memory_bytes": int(h["total_ram_bytes"])}
        for l in hw:
            t = l.split()
            if len(t) == 3 and t[0] == "C" and t[2].isdigit():
                inv["hardware"]["root_disk_free_bytes"] = int(t[2])
    else:
        inv["hardware"] = {"logical_processors": int(h["nproc"])}
        for l in hw:
            m = re.match(r"^(MemTotal|SwapTotal):\s+(\d+) kB", l)
            if m:
                inv["hardware"]["memory_bytes" if m.group(1) == "MemTotal" else "swap_bytes"] = int(m.group(2)) * 1024
            t = l.split()
            if len(t) == 6 and t[5] == "/" and "root_disk_free_bytes" not in inv["hardware"]:
                inv["hardware"]["root_disk_free_bytes"] = _bytes(t[3])

    us = _step(steps, "User, privileges")
    u = _kv(us)
    if win:
        who = next((l for l in us if "\\" in l and "=" not in l), "")
        host, _, name = who.partition("\\")
        inv["infra"]["hostname"] = host
        ep = {}
        for l in us:
            t = l.split()
            if len(t) == 2 and t[0] in ("MachinePolicy", "UserPolicy", "Process", "CurrentUser", "LocalMachine"):
                ep[t[0]] = t[1]
        inv["user"] = {"name": name, "is_admin": u.get("is_administrator") == "True",
                       "uac_consent": int(u["ConsentPromptBehaviorAdmin"]), "execution_policy": ep}
    else:
        m = re.match(r"^uid=(\d+)\((\w+)\) gid=(\d+)\((\w+)\) groups=(.*)$", next(l for l in us if l.startswith("uid=")))
        inv["user"] = {"name": m.group(2), "uid": int(m.group(1)), "gid": int(m.group(3)),
                       "groups": sorted(g.split("(")[1].rstrip(")") for g in m.group(5).split(",")),
                       "passwordless_sudo": u.get("passwordless_sudo") == "yes"}
        lim, sysctl, ra, seen_sysctl = [], {}, [], False
        for l in us:
            m = re.match(r"^(\S+) = (.*)$", l)
            if m and "." in m.group(1):
                sysctl[m.group(1)] = m.group(2)
                seen_sysctl = True
            m = re.match(r"^sysctl: permission denied on key '([^']+)'", l)
            if m:
                sysctl[m.group(1)] = "<denied>"
                seen_sysctl = True
            if l.isdigit():
                (ra if seen_sysctl else lim).append(l)
            if re.match(r"^rw\b.*", l):
                inv["limits"]["mount_options"] = l
        inv["limits"].update({"nofile": int(lim[0]), "stack": int(lim[1]), "sysctl": sysctl, "read_ahead_kb": sorted(set(ra))})

    envl = _step(steps, "Allow-listed environment")
    inv["env"] = {k: v for k, v in _kv(envl).items()}
    for l in envl:
        m = re.match(r"^([A-Za-z0-9_]+) present=(True|False)$", l)
        if m:
            inv["credential_env"][m.group(1)] = m.group(2) == "True"
    inv["tool_cache"]["root"] = inv["env"].get("AGENT_TOOLSDIRECTORY") if inv["env"].get("AGENT_TOOLSDIRECTORY") != "<unset>" else None

    pl = _step(steps, "PATH order")
    inv["path"]["process"] = _path_list(pl, "process PATH")
    inv["path"]["machine"] = _path_list(pl, "machine PATH") or _path_list(pl, "/etc/environment PATH")

    sh = _step(steps, "Shells and versions")
    semvers = [l for l in sh if re.match(r"^\d+\.\d+\.\d+(\.\d+)?$", l)]
    if win:
        inv["shells"]["pwsh"], inv["shells"]["powershell"] = semvers[0], semvers[1]
    else:
        inv["shells"]["pwsh"] = semvers[0]
    for l in sh:
        m = re.match(r"^GNU bash, version (\S+)", l)
        if m:
            inv["shells"]["bash"] = m.group(1)
        for rx, key in ((r"^Python (\S+)", "python3"), (r"^v(\d\S*)$", "node"), (r"^Docker version ([^,]+)", "docker"),
                        (r"^gcc \(.*\) (\S+)$", "gcc"), (r"clang version (\S+)", "clang")):
            m = re.search(rx, l)
            if m:
                inv["tools"][key] = m.group(1)
    links = {}
    for l in sh:
        t = l.split(None, 1)
        if len(t) and re.match(r"^\S+\.(exe|cmd)$", t[0]):
            links[t[0]] = t[1].strip() if len(t) > 1 else ""
    if links:
        inv["tools"]["shell_links"] = links

    vs = _step(steps, "Visual Studio")
    if win and "[" in vs and "]" in vs:
        v = json.loads("\n".join(vs[vs.index("["):len(vs) - vs[::-1].index("]")]))
        if v:
            inv["tools"]["visual_studio"] = v[0]["installationVersion"]
            inv["tools"]["visual_studio_product"] = v[0]["productId"]
            inv["tools"]["visual_studio_path"] = v[0]["installationPath"]
        for l in vs:
            m = re.match(r"^(\S+\.exe)\s+([A-Za-z]:\\.*)$", l)
            if m:
                inv["command_paths"][m.group(1)] = m.group(2).strip()

    sv = _step(steps, "Services of interest")
    for l in sv:
        t = l.split()
        if win and len(t) == 3 and t[1] in ("Running", "Stopped", "Paused"):
            inv["services"][t[0]] = {"status": t[1], "start_type": t[2]}
        m = re.match(r"^(\S+) enabled=(\S+) active=(\S+)$", l)
        if m:
            inv["services"][m.group(1)] = {"enabled": m.group(2), "active": m.group(3)}

    dk = _step(steps, "Docker state")
    d = {"images": []}
    for l in dk:
        m = re.match(r"^client=(\S+) server=(\S+)$", l)
        if m:
            d["client"], d["server"] = m.group(1), m.group(2)
        m = re.match(r"^(\S+:\S+) [0-9a-f]{12}$", l)
        if m:
            d["images"].append(m.group(1))
        m = re.match(r"^(s\S+)\s+\d+\s+(\S+)\s+(\S+)\s+\d+ .* /run/docker.sock$", l)
        if m:
            d["socket"] = {"mode": m.group(1), "owner": m.group(2), "group": m.group(3)}
    d["images"] = sorted(d["images"])
    inv["docker"] = d

    tcl = _step(steps, "Tool cache layout")
    for l in tcl:
        m = re.match(r"^([^\s/]+)/([^\s/]+)$", l)
        if m:
            inv["tool_cache"]["versions"].setdefault(m.group(1), []).append(m.group(2))
        m = re.match(r"^d\S+\s+\d+\s+\S+\s+\S+\s+\d+ \w+\s+\d+ [\d:]+ (\S+)$", l)
        if m and m.group(1) not in (".", ".."):
            inv["action_archive_cache"].append(m.group(1))
    inv["tool_cache"]["versions"] = {k: sorted(v) for k, v in inv["tool_cache"]["versions"].items()}
    inv["tool_cache"]["defaults"] = derive_defaults(inv)

    inv["run_identity"] = {"source_sha": a.source_sha, "workflow_sha": a.workflow_sha, "action_shas": sorted(a.action_sha or [])}
    inv["source"]["run_id"] = a.run_id
    inv["coverage"] = ["image", "infra", "run_identity", "user", "env", "credential_env", "path", "shells", "tools",
                       "tool_cache", "services", "docker", "hardware"] + (["command_paths"] if win else ["limits", "action_archive_cache"])
    inv["profile"] = inv["image"]["label"]
    return inv


# ---------------------------------------------------------------- Readme inventory (P01) converter

_CACHE_NAMES = {"Go": "go", "Node.js": "node", "Python": "Python", "PyPy": "PyPy", "Ruby": "Ruby"}


def parse_readme(path):
    d = load(path)
    label = re.sub(r"-x64$", "", d["profile"])
    inv = new_inventory("readme-inventory", d["profile"])
    idt = d["identity"]
    inv["image"] = {"label": label, "image_version": idt["Image Version"]["value"]}
    inv["profile"] = label
    cats = d["categories"]
    for cat, items in cats.items():
        if cat.endswith("Environment variables"):
            for it in items:
                inv["env"][it["attrs"]["Name"]] = it["attrs"]["Value"]
        elif cat.startswith("Cached Tools/"):
            name = _CACHE_NAMES.get(cat.split("/", 1)[1], cat.split("/", 1)[1])
            for it in items:
                v = it["versions"][0].split(" ")[0]
                inv["tool_cache"]["versions"].setdefault(name, []).append(v)
                if it.get("default"):
                    inv["tool_cache"]["defaults"][name] = v
        elif cat in ("Tools", "CLI Tools", "Language and Runtime", "Rust Tools", "PHP Tools", "Haskell Tools", ".NET Tools"):
            for it in items:
                if it.get("versions") and "/" not in cat:
                    inv["tools"].setdefault(it["name"], it["versions"][0] if len(it["versions"]) == 1 else ",".join(it["versions"]))
    inv["tool_cache"]["versions"] = {k: sorted(v) for k, v in inv["tool_cache"]["versions"].items()}
    inv["coverage"] = ["image", "env", "tool_cache", "tools"]
    return inv


# ---------------------------------------------------------------- compare

class Cmp:
    def __init__(self, allow):
        self.d, self.allow = [], allow

    def add(self, cls, sec, key, r, c):
        path = f"{sec}.{key}"
        d = {"class": cls, "section": sec, "key": key, "reference": r, "candidate": c}
        for e in self.allow:
            if fnmatch.fnmatchcase(path, e["match"]):
                d.update({"class": "documented-rig-difference", "original_class": cls, "reason": e["reason"]})
                break
        self.d.append(d)

    def mapping(self, sec, ref, cand, mismatch, norm=lambda v: v):
        for k, r in ref.items():
            if r in UNKNOWN:
                continue
            if k not in cand or cand[k] is None:
                if r != "<unset>":
                    self.add("missing-required", sec, k, r, None)
            elif norm(cand[k]) != norm(r):
                self.add(mismatch, sec, k, r, cand[k])
        for k, c in cand.items():
            if c in UNKNOWN or k in ref:
                continue
            self.add("extra", sec, k, None, c)


def _norm_path(p, win):
    p = p.strip()
    return (p.replace("/", "\\").rstrip("\\").lower() if win else p.rstrip("/"))


def compare_paths(C, sec, ref, cand, win):
    rn, cn = [_norm_path(p, win) for p in ref], [_norm_path(p, win) for p in cand]
    for p, n in zip(ref, rn):
        if n not in cn:
            C.add("missing-required", sec, p, p, None)
    for p, n in zip(cand, cn):
        if n not in rn:
            C.add("extra", sec, p, None, p)
    common_r = [n for n in rn if n in cn]
    common_c = [n for n in cn if n in rn]
    # dedupe preserving first occurrence so repeated entries do not hide a reorder
    seen = set(); common_r = [n for n in common_r if not (n in seen or seen.add(n))]
    seen = set(); common_c = [n for n in common_c if not (n in seen or seen.add(n))]
    if common_r != common_c:
        for i, (a, b) in enumerate(zip(common_r, common_c)):
            if a != b:
                C.add("path-order", sec, f"index {i}", a, b)
                break
    elif len(rn) == len(cn) and rn != cn and not any(d["section"] == sec for d in C.d):
        C.add("path-order", sec, "duplicates", ref, cand)


def compare_inventories(ref, cand, allow, sections=None):
    C = Cmp(allow)
    want = lambda s: sections is None or s in sections
    win = ref.get("profile", "").startswith("windows")
    for s in ref["coverage"]:
        if want(s) and s not in cand["coverage"]:
            C.add("missing-required", "coverage", s, "covered", "not probed")
    cov = lambda s: want(s) and s in ref["coverage"] and s in cand["coverage"]
    if cov("image"):
        C.mapping("image", ref["image"], cand["image"], "version-mismatch")
    if cov("infra"):
        C.mapping("infra", ref["infra"], cand["infra"], "env-mismatch")
    if cov("user"):
        C.mapping("user", ref["user"], cand["user"], "env-mismatch", lambda v: sorted(v) if isinstance(v, list) else v)
    if cov("env"):
        C.mapping("env", ref["env"], cand["env"], "env-mismatch")
    if cov("credential_env"):
        C.mapping("credential_env", ref["credential_env"], cand["credential_env"], "env-mismatch")
    if cov("path"):
        for k in ("process", "machine"):
            compare_paths(C, "path." + k, ref["path"][k], cand["path"][k], win)
    if cov("shells"):
        C.mapping("shells", ref["shells"], cand["shells"], "version-mismatch")
    if cov("tools"):
        C.mapping("tools", ref["tools"], cand["tools"], "version-mismatch")
    if cov("command_paths"):
        C.mapping("command_paths", ref["command_paths"], cand["command_paths"], "path-order", lambda v: v.lower() if win else v)
    if cov("tool_cache"):
        rv, cv = ref["tool_cache"]["versions"], cand["tool_cache"]["versions"]
        for name, vers in rv.items():
            for v in vers:
                if v not in cv.get(name, []):
                    C.add("missing-required", "tool_cache", f"{name}/{v}", v, None)
        for name, vers in cv.items():
            for v in vers:
                if v not in rv.get(name, []):
                    C.add("extra", "tool_cache", f"{name}/{v}", None, v)
        C.mapping("tool_cache.defaults", ref["tool_cache"]["defaults"], cand["tool_cache"]["defaults"], "default-mismatch")
        for d in C.d:  # a default that is absent is a default mismatch, not a missing file
            if d["section"] == "tool_cache.defaults" and d["class"] == "missing-required":
                d["class"] = "default-mismatch"
    if cov("action_archive_cache"):
        for n in ref["action_archive_cache"]:
            if n not in cand["action_archive_cache"]:
                C.add("missing-required", "action_archive_cache", n, n, None)
    if cov("services"):
        C.mapping("services", ref["services"], cand["services"], "service-mismatch")
    if cov("docker"):
        rd, cd = ref["docker"], cand["docker"]
        C.mapping("docker", {k: v for k, v in rd.items() if k != "images"}, {k: v for k, v in cd.items() if k != "images"}, "version-mismatch")
        for i in rd.get("images", []):
            if i not in cd.get("images", []):
                C.add("missing-required", "docker.images", i, i, None)
        for i in cd.get("images", []):
            if i not in rd.get("images", []):
                C.add("extra", "docker.images", i, None, i)
    if cov("hardware"):
        C.mapping("hardware", ref["hardware"], cand["hardware"], "env-mismatch")
    if cov("limits"):
        rl, cl = ref["limits"], cand["limits"]
        C.mapping("limits", {k: v for k, v in rl.items() if k != "sysctl"}, {k: v for k, v in cl.items() if k != "sysctl"}, "env-mismatch")
        C.mapping("limits.sysctl", rl.get("sysctl", {}), cl.get("sysctl", {}), "env-mismatch")
    return C.d


def identity_checks(ref, cand, pin):
    out = []

    def chk(field, r, c, p):
        ok = True
        if p is not None:
            ok = ok and r == p and c == p
        if r is not None:
            ok = ok and c == r
        out.append({"field": field, "reference": r, "candidate": c, "pin": p, "ok": ok})

    pin = pin or {}
    chk("image_version", ref["image"].get("image_version"), cand["image"].get("image_version"), pin.get("image_version"))
    chk("runner_version", ref["image"].get("runner_version"), cand["image"].get("runner_version"), pin.get("runner_version"))
    chk("source_sha", ref["run_identity"].get("source_sha"), cand["run_identity"].get("source_sha"), pin.get("source_sha"))
    chk("workflow_sha", ref["run_identity"].get("workflow_sha"), cand["run_identity"].get("workflow_sha"), pin.get("workflow_sha"))
    chk("action_shas", sorted(ref["run_identity"].get("action_shas") or []) or None,
        sorted(cand["run_identity"].get("action_shas") or []), sorted(pin["action_shas"]) if "action_shas" in pin else None)
    return out


def inventory_section(ref, cand, allow, pin, sections=None):
    diffs = compare_inventories(ref, cand, allow, sections)
    ident = identity_checks(ref, cand, pin)
    counts = {}
    for d in diffs:
        counts[d["class"]] = counts.get(d["class"], 0) + 1
    failing = [d for d in diffs if d["class"] in FAILING]
    id_bad = [i for i in ident if not i["ok"]]
    return {"status": "pass" if not failing and not id_bad else "fail", "counts": counts, "differences": diffs,
            "identity": {"status": "pass" if not id_bad else "fail", "checks": ident}}


# ---------------------------------------------------------------- workloads

CLAIM_OK = re.compile(r"(?i)(BUILD SUCCESS(?:FUL)?|Build succeeded|Job succeeded|result:\s*(?:success|pass(?:ed)?)|^\W*(?:success|succeeded|passed)\W*$)")
CLAIM_BAD = re.compile(r"(?i)(BUILD FAILED|Build FAILED|Job failed|result:\s*(?:fail|failed|failure)|^\W*(?:failed|failure)\W*$)")
ERR = re.compile(r"(?i)(\berror\b\s*(?:[A-Z]{1,4}\d+)?\s*:|##\[error\]|\bfatal error\b)")
LOC = re.compile(r"^(?P<file>(?:[A-Za-z]:)?[^\s:()]+?)[:(](?P<line>\d+)")


def first_error(text):
    for l in text.splitlines():
        m = ERR.search(l)
        if m:
            loc = LOC.match(l.strip())
            return {"message": l.strip()[:300], "file": loc.group("file") if loc else None,
                    "line": int(loc.group("line")) if loc else None}
    return None


def log_claim(text, ok_re=CLAIM_OK, bad_re=CLAIM_BAD):
    ok = any(ok_re.search(l) for l in text.splitlines())
    bad = any(bad_re.search(l) for l in text.splitlines())
    return "success" if ok and not bad else "failure" if bad and not ok else None


def _subst(s, ctx):
    for k, v in ctx.items():
        s = s.replace("{" + k + "}", v)
    return s


def _variant(d):
    for v in d.get("variants", [{}]):
        req = v.get("requires")
        if req is None or shutil.which(req):
            return {**{k: x for k, x in d.items() if k != "variants"}, **v}, req
    return None, None


def run_workload(d, work_root, fixtures, log_dir):
    t0 = time.time()
    started = now()
    res = {"id": d["id"], "variant": None, "status": "skipped", "expected": None, "observed": "skipped", "exit_code": None,
           "expected_exit_codes": None, "started_at": started, "ended_at": started, "duration_s": 0.0, "command": "",
           "artifacts": [], "first_error": None, "log_sha256": None, "log_claim": None, "reasons": []}
    spec, req = _variant(d)
    if spec is None:
        res["reasons"].append("no variant of the workload is runnable on this host")
        return res
    res["variant"] = req or "default"
    codes = spec.get("expected_exit_codes", [0])
    res["expected_exit_codes"] = codes
    res["expected"] = "success" if codes == [0] else "failure"
    wd = tempfile.mkdtemp(prefix="wl-", dir=work_root)
    ctx = {"python": sys.executable, "fixtures": fixtures, "work": wd, "exe": ".exe" if os.name == "nt" else ""}
    log, code, timeout = b"", None, False
    cmds = [[_subst(a, ctx) for a in c] for c in spec["commands"]]
    res["command"] = " && ".join(" ".join(c) for c in cmds)
    for c in cmds:
        try:
            p = subprocess.run(c, cwd=wd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=spec.get("timeout_s", 120))
            log += p.stdout
            code = p.returncode
        except FileNotFoundError:
            log += f"error: command not found: {c[0]}\n".encode()
            code = 127
        except subprocess.TimeoutExpired as e:
            log += e.stdout or b""
            timeout = True
            code = None
        if code != 0:
            break
    text = log.decode("utf-8", "replace")
    os.makedirs(log_dir, exist_ok=True)
    lp = os.path.join(log_dir, d["id"].replace("/", "__") + ".log")
    with open(lp, "wb") as f:
        f.write(log)
    res["log_sha256"] = hashlib.sha256(log).hexdigest()
    res["exit_code"] = code
    res["first_error"] = first_error(text)
    claim = log_claim(text, re.compile(spec["claim_success_regex"]) if "claim_success_regex" in spec else CLAIM_OK,
                      re.compile(spec["claim_failure_regex"]) if "claim_failure_regex" in spec else CLAIM_BAD)
    res["log_claim"] = claim
    for g in spec.get("artifact_globs", []):
        hits = sorted(x for x in glob.glob(os.path.join(wd, g), recursive=True) if os.path.isfile(x))
        if not hits:
            res["reasons"].append(f"artifact glob matched nothing: {g}")
        for x in hits:
            rel = os.path.relpath(x, wd).replace("\\", "/")
            res["artifacts"].append({"name": rel, "bytes": os.path.getsize(x), "sha256": sha256_file(x)})
    got = {a["name"]: a["sha256"] for a in res["artifacts"]}
    for n, h in spec.get("expected_hashes", {}).items():
        if got.get(n) != h:
            res["reasons"].append(f"artifact hash mismatch: {n}")
    ef = spec.get("expected_first_error")
    if ef:
        fe = res["first_error"]
        if not fe or ef.get("contains", "") not in fe["message"] or ("file" in ef and ef["file"] != fe["file"]) or ("line" in ef and ef["line"] != fe["line"]):
            res["reasons"].append("first causal error does not match the expected one")
    res["ended_at"] = now()
    res["duration_s"] = round(time.time() - t0, 3)
    if timeout:
        res["observed"] = "timeout"
        res["reasons"].append("timeout")
        res["status"] = "fail"
        return res
    res["observed"] = "success" if code == 0 else "failure"
    if code not in codes:
        res["reasons"].append(f"exit code {code} not in expected {codes}")
    forged = claim is not None and claim != res["observed"]
    if forged:
        res["reasons"].append(f"log claims {claim} but exit code is {code}")
    res["status"] = "forged-green" if forged else "fail" if res["reasons"] else "pass"
    return res


def load_defs(p):
    files = sorted(glob.glob(os.path.join(p, "*.json"))) if os.path.isdir(p) else [p]
    defs = [load(f) for f in files]
    ids = [d["id"] for d in defs]
    if len(ids) != len(set(ids)):
        die("duplicate workload id")
    return defs


def cmd_run_workloads(a):
    defs = load_defs(a.defs)
    out_dir = os.path.dirname(os.path.abspath(a.out))
    work = a.work or tempfile.mkdtemp(prefix="certify-work-")
    os.makedirs(work, exist_ok=True)
    fixtures = os.path.join(os.path.dirname(os.path.abspath(__file__)), "workloads", "fixtures")
    results = [run_workload(d, work, fixtures, os.path.join(out_dir, "logs")) for d in defs if d["id"] not in (a.skip or [])]
    dump({"schema": SCHEMA, "kind": "workload-results", "results": results}, a.out)
    bad = [r["id"] for r in results if r["status"] != "pass"]
    print(f"workloads: {len(results) - len(bad)}/{len(results)} pass" + (f"; not pass: {', '.join(bad)}" if bad else ""))
    return 1 if bad else 0


def behaviour_section(defs, results, ref_results=None):
    """Every defined workload needs a result with status pass; a missing result is skipped, not a pass."""
    by = {r["id"]: r for r in (results or [])}
    refs = {r["id"]: r for r in (ref_results or [])}
    rows = []
    for d in defs or []:
        r = by.get(d["id"])
        if r is None:
            rows.append({"id": d["id"], "status": "skipped", "reasons": ["no result for this workload"]})
            continue
        row = {"id": d["id"], "status": r["status"], "reasons": list(r.get("reasons", []))}
        rr = refs.get(d["id"])
        if rr and row["status"] == "pass":
            if (rr["exit_code"], (rr["first_error"] or {}).get("message")) != (r["exit_code"], (r["first_error"] or {}).get("message")):
                row.update(status="fail", reasons=row["reasons"] + ["exit code or first error differs from the reference run"])
            elif {a["name"]: a["sha256"] for a in rr["artifacts"]} != {a["name"]: a["sha256"] for a in r["artifacts"]}:
                row.update(status="fail", reasons=row["reasons"] + ["artifact hashes differ from the reference run"])
        rows.append(row)
    if not defs:
        return {"status": "missing", "results": [], "reasons": ["no workloads defined; inventory cannot substitute for behaviour"]}
    return {"status": "pass" if all(r["status"] == "pass" for r in rows) else "fail", "results": rows}


# ---------------------------------------------------------------- evidence

def _ascii(s, n):
    return re.sub(r"[^ -~]", "?", str(s))[:n]


def _art(path, name=None):
    return {"name": re.sub(r"[^A-Za-z0-9._-]", "_", name or os.path.basename(path))[:120], "bytes": os.path.getsize(path), "sha256": sha256_file(path)}


def build_records(a, ref, cand, report, results, defs, out):
    head = a.head_sha or cand["run_identity"].get("source_sha")
    if not head or not re.fullmatch(r"[0-9a-f]{40}", head):
        die("a full 40-hex --head-sha (or candidate run_identity.source_sha) is required for evidence")
    acts = cand["run_identity"].get("action_shas") or []
    for s in acts:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}", s):
            die(f"bad action sha: {s}")
    ri = {"label": ref["image"].get("label"), "image_version": ref["image"].get("image_version")}
    if ri["label"] not in ("windows-2025-vs2026", "ubuntu-24.04") or not re.fullmatch(r"\d{8}\.\d+\.\d+", ri["image_version"] or ""):
        ri = None
    ci = {"generation_id": a.candidate_generation, "base_sha256": a.candidate_base_sha256} if a.candidate_generation else None
    tv = {k: _ascii(v, 120) for k, v in {**cand["shells"], **{k: v for k, v in cand["tools"].items() if isinstance(v, str)}}.items()}
    tv["image_version"] = _ascii(cand["image"].get("image_version"), 120)
    manifest = hashlib.sha256(json.dumps(defs, sort_keys=True).encode()).hexdigest() if defs else None
    base = {"schema": 1, "item": a.item, "contract_revision": a.contract_revision, "head_sha": head, "action_shas": acts,
            "reference_image": ri, "candidate_image": ci, "inputs_manifest_sha256": manifest,
            "os_version": _ascii(f"{cand['image'].get('os_name')} {cand['image'].get('os_build')}", 120),
            "tool_versions": tv, "verifier": a.verifier}
    arts = [_art(os.path.join(out, n)) for n in ("reference-inventory.json", "candidate-inventory.json", "parity-report.json")]
    recs = []
    inv_ok = report["inventory"]["status"] == "pass"
    t = now()
    recs.append({**base, "fixture_id": "inventory/" + (ref.get("profile") or "unknown").lower(),
                 "command": _ascii("certify.py compare reference-inventory.json candidate-inventory.json", 500),
                 "started_at": t, "ended_at": t, "exit_status": 0 if inv_ok else 1,
                 "oracle": {"expected": "success", "observed": "success" if inv_ok else "failure"},
                 "result": "pass" if inv_ok else "fail", "artifacts": arts})
    rows = {r["id"]: r for r in results or []}
    for d in defs or []:
        r = rows.get(d["id"])
        if r is None:
            exp = "success" if d.get("expected_exit_codes", [0]) == [0] else "failure"
            recs.append({**base, "fixture_id": "workload/" + d["id"], "command": "(not run)", "started_at": t, "ended_at": t,
                         "exit_status": None, "oracle": {"expected": exp, "observed": "skipped"}, "result": "skipped", "artifacts": []})
            continue
        st = next(x["status"] for x in report["behaviour"]["results"] if x["id"] == d["id"])
        obs = r["observed"]
        res = "pass" if st == "pass" else "timeout" if obs == "timeout" else "skipped" if obs == "skipped" else "fail"
        if res == "fail" and obs == r["expected"]:
            obs = "unknown"  # the exit code agrees with the oracle but the result is still not trusted
        a2 = [{"name": re.sub(r"[^A-Za-z0-9._-]", "_", x["name"])[:120], "bytes": x["bytes"], "sha256": x["sha256"]} for x in r["artifacts"]]
        lp = os.path.join(os.path.dirname(os.path.abspath(a.results)), "logs", d["id"].replace("/", "__") + ".log")
        if os.path.isfile(lp):
            a2.append(_art(lp, d["id"].replace("/", "__") + ".log"))
        recs.append({**base, "fixture_id": "workload/" + d["id"], "command": _ascii(r["command"], 500) or "(none)",
                     "started_at": r["started_at"], "ended_at": r["ended_at"], "exit_status": r["exit_code"],
                     "oracle": {"expected": r["expected"], "observed": obs}, "result": res, "artifacts": a2[:64]})
    return recs


def cmd_certify(a):
    ref, cand = load(a.reference), load(a.candidate)
    allow = load(a.allowlist)["entries"] if a.allowlist else []
    pin = load(a.pin) if a.pin else None
    defs = load_defs(a.defs) if a.defs else []
    results = load(a.results)["results"] if a.results else []
    ref_results = load(a.reference_results)["results"] if a.reference_results else None
    inv = inventory_section(ref, cand, allow, pin)
    beh = behaviour_section(defs, results, ref_results)
    report = {"schema": SCHEMA, "kind": "parity-report", "generated_at": now(),
              "reference": {"source": ref["source"], "image": ref["image"]}, "candidate": {"source": cand["source"], "image": cand["image"]},
              "inventory": inv, "behaviour": beh,
              "verdict": "pass" if inv["status"] == "pass" and beh["status"] == "pass" else "fail"}
    out = a.out
    os.makedirs(out, exist_ok=True)
    shutil.copyfile(a.reference, os.path.join(out, "reference-inventory.json"))
    shutil.copyfile(a.candidate, os.path.join(out, "candidate-inventory.json"))
    dump(report, os.path.join(out, "parity-report.json"))
    recs = build_records(a, ref, cand, report, results, defs, out)
    ev = os.path.join(out, "evidence")
    os.makedirs(ev, exist_ok=True)
    files = []
    for r in recs:
        f = os.path.join(ev, r["fixture_id"].replace("/", "__") + ".json")
        dump(r, f)
        files.append(f)
    validator = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "parity", "contracts", "validate.py")
    if os.path.isfile(validator):
        p = subprocess.run([sys.executable, "-I", validator, "evidence-bundle"] + files, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(p.stdout.strip())
        if p.returncode:
            print("certify: evidence records failed validate.py evidence-bundle", file=sys.stderr)
            return 3
    else:
        print("certify: validate.py not found; evidence records NOT validated", file=sys.stderr)
    bad = sorted(c for c in inv["counts"] if c in FAILING)
    print(f"inventory: {inv['status']} {inv['counts']}; identity: {inv['identity']['status']}; behaviour: {beh['status']}; verdict: {report['verdict']}")
    return 0 if report["verdict"] == "pass" else 1


def cmd_compare(a):
    ref, cand = load(a.reference), load(a.candidate)
    allow = load(a.allowlist)["entries"] if a.allowlist else []
    sec = inventory_section(ref, cand, allow, load(a.pin) if a.pin else None, a.sections.split(",") if a.sections else None)
    if a.out:
        dump({"schema": SCHEMA, "kind": "inventory-report", "inventory": sec}, a.out)
    for d in sec["differences"]:
        if d["class"] != "extra":
            print(f"{d['class']:26} {d['section']}.{d['key']}  ref={d['reference']!r} cand={d['candidate']!r}")
    for i in sec["identity"]["checks"]:
        if not i["ok"]:
            print(f"{'identity-mismatch':26} {i['field']}  ref={i['reference']!r} cand={i['candidate']!r} pin={i['pin']!r}")
    print(f"inventory: {sec['status']} {sec['counts']}")
    return 0 if sec["status"] == "pass" else 1


def main():
    ap = argparse.ArgumentParser(prog="certify.py")
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("parse-hosted-log"); p.add_argument("log"); p.add_argument("--out", required=True)
    p.add_argument("--run-id"); p.add_argument("--source-sha"); p.add_argument("--workflow-sha"); p.add_argument("--action-sha", action="append")
    p = sp.add_parser("parse-readme"); p.add_argument("inventory"); p.add_argument("--out", required=True)
    p = sp.add_parser("compare")
    for n in ("reference", "candidate"):
        p.add_argument("--" + n, required=True)
    p.add_argument("--allowlist"); p.add_argument("--pin"); p.add_argument("--sections"); p.add_argument("--out")
    p = sp.add_parser("run-workloads"); p.add_argument("--defs", required=True); p.add_argument("--out", required=True)
    p.add_argument("--work"); p.add_argument("--skip", action="append")
    p = sp.add_parser("certify")
    for n in ("reference", "candidate", "out"):
        p.add_argument("--" + n, required=True)
    for n in ("allowlist", "pin", "defs", "results", "reference-results", "head-sha", "candidate-generation", "candidate-base-sha256"):
        p.add_argument("--" + n)
    p.add_argument("--item", default="P05"); p.add_argument("--contract-revision", default="evidence-cleanup@1")
    p.add_argument("--verifier", default="parity-certify")
    a = ap.parse_args()
    try:
        if a.cmd == "parse-hosted-log":
            dump(parse_hosted_log(a.log, a), a.out); print("wrote " + a.out); return 0
        if a.cmd == "parse-readme":
            dump(parse_readme(a.inventory), a.out); print("wrote " + a.out); return 0
        if a.cmd == "compare":
            return cmd_compare(a)
        if a.cmd == "run-workloads":
            return cmd_run_workloads(a)
        return cmd_certify(a)
    except (OSError, ValueError, KeyError, IndexError, StopIteration) as e:
        die(f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    sys.exit(main())
