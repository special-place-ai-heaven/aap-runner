#!/usr/bin/env python3
"""P05 differential certification harness (stdlib only; run as `python -I certify.py <cmd>`).

Commands
  parse-hosted-log LOG --out F     hosted capture log (hosted-reference-*.yml output) -> job-inventory.json
  parse-readme INVENTORY --out F   P01 inventory.json (Readme) -> job-inventory.json, overlapping categories only
  compare --reference F --candidate F   inventory diff + identity checks (inventory section only)
  run-workloads --defs P --out F   run workload definitions, write workload-results.json (+ logs)
  certify ...                      inventory + identity + behaviour -> report + evidence records -> verdict.json

Exit: 0 pass, 1 certification failed, 2 bad input, 3 evidence records invalid or not validated.
Inventory and behaviour are separate sections; neither can substitute for the other (see certify).
verdict.json is written LAST, after the evidence records validated; no verdict.json means not certified.
"""
import argparse, datetime, fnmatch, glob, hashlib, json, os, re, shutil, signal, subprocess, sys, tempfile, time

SCHEMA = 1
# Differences in these classes fail certification. `extra` and `documented-rig-difference` never do.
FAILING = {"missing-required", "version-mismatch", "default-mismatch", "path-order", "env-mismatch",
           "service-mismatch", "identity-mismatch"}
# the archived logs carry the escape as a literal "^[" (cat -v form); a real ESC is handled too
ESC = r"(?:\x1b|\^\[)"
ANSI = re.compile(ESC + r"\[[0-9;]*[A-Za-z]")
TS = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")
UNKNOWN = ("<denied>", None)
SHA1 = re.compile(r"^[0-9a-f]{40}$")
ACTION = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$")
PIN_FORMAT = {"image_version": re.compile(r"^\d{8}\.\d+\.\d+$"), "runner_version": re.compile(r"^\d+\.\d+\.\d+$"),
              "source_sha": SHA1, "workflow_sha": SHA1}


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


def require_complete(ref, sections=None):
    """A reference whose covered section is empty compares as 'nothing to differ from'. Refuse it instead."""
    def need(ok, what):
        if not ok:
            die(f"reference inventory covers '{what}' but it is empty or incomplete; fix the reference instead of comparing against it")
    for s in ref["coverage"]:
        if sections is not None and s not in sections:
            continue
        if s == "path":
            need(ref["path"]["process"] and ref["path"]["machine"], s)
        elif s == "tool_cache":
            need(ref["tool_cache"]["versions"], s)
        elif s == "docker":
            need(ref["docker"].get("client"), s)
        elif s == "image":
            need(ref["image"].get("label") and ref["image"].get("image_version"), s)
        elif s in ("user", "env", "shells", "tools", "services", "hardware", "limits"):
            need(ref[s], s)


# ---------------------------------------------------------------- hosted-log parser

def _steps(path):
    steps = {}
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
        steps.setdefault(step, []).append(t)
    return steps


def _step(steps, prefix):
    for k, v in steps.items():
        if k.startswith(prefix):
            return v
    return []


def _need(steps, prefix):
    """Output of an expected step; a missing or empty step dies instead of yielding an empty section."""
    lines = [l for l in _step(steps, prefix) if l.strip()]
    if not lines:
        die(f"hosted log: step '{prefix}' is missing or has no output; refusing to build a reference from it")
    return lines


def _require(cond, what):
    if not cond:
        die(f"hosted log: could not read {what}; refusing to build a reference from it")


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
    su = _need(steps, "Set up job")
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
    _require(inv["image"].get("runner_version") and inv["image"].get("label") and inv["image"].get("image_version"),
             "the runner version and Runner Image group under 'Set up job'")
    inv["infra"] = {"provisioner_version": prov.get("Version"), "provisioner_commit": prov.get("Commit"),
                    "region": prov.get("Region"), "cloud": prov.get("Cloud"), "worker_id": prov.get("Worker ID")}
    win = inv["image"]["label"].startswith("windows")

    ident = _need(steps, "Image identity")
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
    _require(inv["image"].get("image_os") and inv["image"].get("os_name"), "ImageOS and the OS name from 'Image identity'")

    hw = _need(steps, "Hardware class")
    h = _kv(hw)
    if win:
        _require("logical_processors" in h and "total_ram_bytes" in h, "the Windows hardware class")
        inv["hardware"] = {"logical_processors": int(h["logical_processors"]), "memory_bytes": int(h["total_ram_bytes"])}
        for l in hw:
            t = l.split()
            if len(t) == 3 and t[0] == "C" and t[2].isdigit():
                inv["hardware"]["root_disk_free_bytes"] = int(t[2])
    else:
        _require("nproc" in h, "the Linux hardware class")
        inv["hardware"] = {"logical_processors": int(h["nproc"])}
        for l in hw:
            m = re.match(r"^(MemTotal|SwapTotal):\s+(\d+) kB", l)
            if m:
                inv["hardware"]["memory_bytes" if m.group(1) == "MemTotal" else "swap_bytes"] = int(m.group(2)) * 1024
            t = l.split()
            if len(t) == 6 and t[5] == "/" and "root_disk_free_bytes" not in inv["hardware"]:
                inv["hardware"]["root_disk_free_bytes"] = _bytes(t[3])
    _require("root_disk_free_bytes" in inv["hardware"], "the root disk free space")

    us = _need(steps, "User, privileges")
    u = _kv(us)
    if win:
        who = next((l for l in us if "\\" in l and "=" not in l), "")
        host, _, name = who.partition("\\")
        _require(name and "ConsentPromptBehaviorAdmin" in u, "the Windows user and UAC setting")
        inv["infra"]["hostname"] = host
        ep = {}
        for l in us:
            t = l.split()
            if len(t) == 2 and t[0] in ("MachinePolicy", "UserPolicy", "Process", "CurrentUser", "LocalMachine"):
                ep[t[0]] = t[1]
        inv["user"] = {"name": name, "is_admin": u.get("is_administrator") == "True",
                       "uac_consent": int(u["ConsentPromptBehaviorAdmin"]), "execution_policy": ep}
    else:
        uid = next((l for l in us if l.startswith("uid=")), "")
        m = re.match(r"^uid=(\d+)\((\w+)\) gid=(\d+)\((\w+)\) groups=(.*)$", uid)
        _require(m, "the uid line")
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
        _require(len(lim) >= 2 and sysctl, "the limits and sysctl values")
        inv["limits"].update({"nofile": int(lim[0]), "stack": int(lim[1]), "sysctl": sysctl, "read_ahead_kb": sorted(set(ra))})

    envl = _need(steps, "Allow-listed environment")
    inv["env"] = {k: v for k, v in _kv(envl).items()}
    for l in envl:
        m = re.match(r"^([A-Za-z0-9_]+) present=(True|False)$", l)
        if m:
            inv["credential_env"][m.group(1)] = m.group(2) == "True"
    _require("AGENT_TOOLSDIRECTORY" in inv["env"], "the allow-listed environment")
    inv["tool_cache"]["root"] = inv["env"].get("AGENT_TOOLSDIRECTORY") if inv["env"].get("AGENT_TOOLSDIRECTORY") != "<unset>" else None

    pl = _need(steps, "PATH order")
    inv["path"]["process"] = _path_list(pl, "process PATH")
    inv["path"]["machine"] = _path_list(pl, "machine PATH") or _path_list(pl, "/etc/environment PATH")
    _require(inv["path"]["process"] and inv["path"]["machine"], "both PATH lists")

    sh = _need(steps, "Shells and versions")
    semvers = [l for l in sh if re.match(r"^\d+\.\d+\.\d+(\.\d+)?$", l)]
    _require(len(semvers) >= (2 if win else 1), "the PowerShell versions")
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
    _require(inv["shells"].get("bash"), "the bash version")
    links = {}
    for l in sh:
        t = l.split(None, 1)
        if len(t) and re.match(r"^\S+\.(exe|cmd)$", t[0]):
            links[t[0]] = t[1].strip() if len(t) > 1 else ""
    if links:
        inv["tools"]["shell_links"] = links

    if win:
        vs = _need(steps, "Visual Studio")
        _require("[" in vs and "]" in vs, "the vswhere output")
        v = json.loads("\n".join(vs[vs.index("["):len(vs) - vs[::-1].index("]")]))
        _require(v, "a Visual Studio installation")
        inv["tools"]["visual_studio"] = v[0]["installationVersion"]
        inv["tools"]["visual_studio_product"] = v[0]["productId"]
        inv["tools"]["visual_studio_path"] = v[0]["installationPath"]
        for l in vs:
            m = re.match(r"^(\S+\.exe)\s+([A-Za-z]:\\.*)$", l)
            if m:
                inv["command_paths"][m.group(1)] = m.group(2).strip()

    sv = _need(steps, "Services of interest")
    for l in sv:
        t = l.split()
        if win and len(t) == 3 and t[1] in ("Running", "Stopped", "Paused"):
            inv["services"][t[0]] = {"status": t[1], "start_type": t[2]}
        m = re.match(r"^(\S+) enabled=(\S+) active=(\S+)$", l)
        if m:
            inv["services"][m.group(1)] = {"enabled": m.group(2), "active": m.group(3)}
    _require(inv["services"], "any service row")

    dk = _need(steps, "Docker state")
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
    _require(d.get("client"), "the Docker client and server versions")
    d["images"] = sorted(d["images"])
    inv["docker"] = d

    tcl = _need(steps, "Tool cache layout")
    for l in tcl:
        m = re.match(r"^([^\s/]+)/([^\s/]+)$", l)
        if m:
            inv["tool_cache"]["versions"].setdefault(m.group(1), []).append(m.group(2))
        m = re.match(r"^d\S+\s+\d+\s+\S+\s+\S+\s+\d+ \w+\s+\d+ [\d:]+ (\S+)$", l)
        if m and m.group(1) not in (".", ".."):
            inv["action_archive_cache"].append(m.group(1))
    _require(inv["tool_cache"]["versions"], "any tool cache version")
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

def load_allow(path):
    """allowlist.json: `entries` turn a difference into documented-rig-difference; `floors` accept a numeric candidate
    value >= the reference (a candidate below the floor fails)."""
    if not path:
        return {"entries": [], "floors": []}
    d = load(path)
    for kind in ("entries", "floors"):
        for e in d.get(kind, []):
            if not isinstance(e.get("match"), str) or not isinstance(e.get("reason"), str) or not e["reason"].strip():
                die(f"allowlist {kind} need a 'match' pattern and a non-empty 'reason'")
    return {"entries": d.get("entries", []), "floors": d.get("floors", [])}


def _num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


class Cmp:
    def __init__(self, allow):
        self.d, self.entries, self.floors = [], allow["entries"], allow["floors"]

    @staticmethod
    def _match(rules, path):
        for e in rules:
            if fnmatch.fnmatchcase(path, e["match"]):
                return e
        return None

    def add(self, cls, sec, key, r, c, allowable=True, note=None):
        d = {"class": cls, "section": sec, "key": key, "reference": r, "candidate": c}
        if note:
            d["note"] = note
        e = self._match(self.entries, f"{sec}.{key}") if allowable else None
        if e:
            d.update({"class": "documented-rig-difference", "original_class": cls, "reason": e["reason"]})
        self.d.append(d)

    def mapping(self, sec, ref, cand, mismatch, norm=lambda v: v, extra="extra"):
        for k, r in ref.items():
            if r in UNKNOWN:
                continue
            c = cand.get(k)
            fl = self._match(self.floors, f"{sec}.{k}")
            if fl and _num(r) and _num(c):
                if c < r:
                    self.add("env-mismatch", sec, k, r, c, allowable=False, note="below the floor: " + fl["reason"])
                elif c > r:
                    self.d.append({"class": "documented-rig-difference", "original_class": "env-mismatch", "section": sec,
                                   "key": k, "reference": r, "candidate": c, "reason": fl["reason"]})
                continue
            if c is None:
                if r != "<unset>":
                    self.add("missing-required", sec, k, r, None)
            elif norm(c) != norm(r):
                self.add(mismatch, sec, k, r, c)
        for k, c in cand.items():
            if c in UNKNOWN or k in ref:
                continue
            self.add(extra, sec, k, None, c)


def _norm_path(p, win):
    p = p.strip()
    return (p.replace("/", "\\").rstrip("\\").lower() if win else p.rstrip("/"))


def compare_paths(C, sec, ref, cand, win):
    rn, cn = [_norm_path(p, win) for p in ref], [_norm_path(p, win) for p in cand]
    rset, cset = set(rn), set(cn)
    for p, n in zip(ref, rn):
        if n not in cset:
            C.add("missing-required", sec, p, p, None)
    # An extra entry ahead of a reference entry can shadow it: that is an ordering difference and fails.
    # An extra entry after the last reference entry cannot shadow anything and is only reported.
    last_ref = max((i for i, n in enumerate(cn) if n in rset), default=-1)
    for i, (p, n) in enumerate(zip(cand, cn)):
        if n not in rset:
            C.add("path-order" if i < last_ref else "extra", sec, p, None, p)
    common_r = [n for n in rn if n in cset]
    common_c = [n for n in cn if n in rset]
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
        # both sides probe the same fixed names: a command callable on the candidate but not on the reference differs
        C.mapping("command_paths", ref["command_paths"], cand["command_paths"], "path-order",
                  lambda v: v.lower() if win else v, extra="path-order")
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
        # both sides probe the same fixed service names, so a service only one side has is a difference
        C.mapping("services", ref["services"], cand["services"], "service-mismatch", extra="service-mismatch")
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


def load_pin(path, full):
    """full=True (certify): all five identity fields are required. full=False (compare): validate what is present."""
    pin = load(path)
    if not isinstance(pin, dict):
        die("pin must be a JSON object")
    if full:
        missing = [k for k in list(PIN_FORMAT) + ["action_shas"] if pin.get(k) is None]
        if missing:
            die("pin is missing: " + ", ".join(missing))
    for k, rx in PIN_FORMAT.items():
        if k in pin and not (isinstance(pin[k], str) and rx.match(pin[k])):
            die(f"pin.{k} is malformed")
    if "action_shas" in pin and not (isinstance(pin["action_shas"], list) and all(isinstance(x, str) and ACTION.match(x) for x in pin["action_shas"])):
        die("pin.action_shas must be a list of owner/repo@<40-hex>")
    return pin


def identity_checks(ref, cand, pin):
    out = []

    def chk(field, r, c, p):
        if p is not None:  # pinned: reference and candidate must both exist and equal the pin
            ok = r is not None and c is not None and r == p and c == p
        else:  # unpinned (compare only): the candidate must agree wherever the reference knows the value
            ok = r is None or c == r
        out.append({"field": field, "reference": r, "candidate": c, "pin": p, "ok": ok})

    pin = pin or {}
    ra, ca = sorted(ref["run_identity"].get("action_shas") or []), sorted(cand["run_identity"].get("action_shas") or [])
    chk("image_version", ref["image"].get("image_version"), cand["image"].get("image_version"), pin.get("image_version"))
    chk("runner_version", ref["image"].get("runner_version"), cand["image"].get("runner_version"), pin.get("runner_version"))
    chk("source_sha", ref["run_identity"].get("source_sha"), cand["run_identity"].get("source_sha"), pin.get("source_sha"))
    chk("workflow_sha", ref["run_identity"].get("workflow_sha"), cand["run_identity"].get("workflow_sha"), pin.get("workflow_sha"))
    chk("action_shas", ra if "action_shas" in pin else (ra or None), ca, sorted(pin["action_shas"]) if "action_shas" in pin else None)
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
CLAIM_BAD = re.compile(r"(?i)(BUILD FAIL(?:ED|URE)|Job failed|result:\s*(?:fail|failed|failure)|^\W*(?:failed|failure)\W*$)")
# gcc/clang `error:`, MSVC `error C2065:`, rustc `error[E0425]:`, GitHub `##[error]`
ERR = re.compile(r"(?i)(\berror(?:\[[A-Za-z0-9]+\]|\s+[A-Z]{1,4}\d+)?\s*:|##\[error\]|\bfatal error\b)")
LOC = re.compile(r"^(?P<file>(?:[A-Za-z]:)?[^\s:()]+?)[:(](?P<line>\d+)")
ARROW = re.compile(r"^\s*-->\s*(?P<file>.+?):(?P<line>\d+)(?::\d+)?\s*$")  # rustc puts the location on the next line
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._/-]{0,100}$")


def first_error(text):
    lines = text.splitlines()
    for i, l in enumerate(lines):
        if ERR.search(l):
            loc = LOC.match(l.strip())
            f, n = (loc.group("file"), int(loc.group("line"))) if loc else (None, None)
            if f is None:
                for nxt in lines[i + 1:i + 4]:
                    m = ARROW.match(nxt)
                    if m:
                        f, n = m.group("file"), int(m.group("line"))
                        break
            return {"message": l.strip()[:300], "file": f, "line": n}
    return None


def log_claim(text, ok_re=CLAIM_OK, bad_re=CLAIM_BAD):
    ok = any(ok_re.search(l) for l in text.splitlines())
    bad = any(bad_re.search(l) for l in text.splitlines())
    return "success" if ok and not bad else "failure" if bad and not ok else None


def _subst(s, ctx):
    for k, v in ctx.items():
        s = s.replace("{" + k + "}", v)
    return s


def def_sha256(d):
    return hashlib.sha256(json.dumps(d, sort_keys=True).encode()).hexdigest()


def variants_of(d):
    return d.get("variants") or [{}]


def spec_of(d, i):
    return {**{k: v for k, v in d.items() if k != "variants"}, **variants_of(d)[i]}


def log_name(wid):
    return wid.replace("/", "__") + ".log"


if os.name == "nt":
    import ctypes
    from ctypes import wintypes

    class _Basic(ctypes.Structure):
        _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
                    ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                    ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                    ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD)]

    class _Io(ctypes.Structure):
        _fields_ = [(n, ctypes.c_uint64) for n in ("ReadOps", "WriteOps", "OtherOps", "ReadBytes", "WriteBytes", "OtherBytes")]

    class _Ext(ctypes.Structure):
        _fields_ = [("Basic", _Basic), ("Io", _Io), ("ProcessMemoryLimit", ctypes.c_size_t), ("JobMemoryLimit", ctypes.c_size_t),
                    ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]

    class _Acct(ctypes.Structure):
        _fields_ = [("TotalUserTime", ctypes.c_int64), ("TotalKernelTime", ctypes.c_int64),
                    ("ThisPeriodTotalUserTime", ctypes.c_int64), ("ThisPeriodTotalKernelTime", ctypes.c_int64),
                    ("TotalPageFaultCount", wintypes.DWORD), ("TotalProcesses", wintypes.DWORD),
                    ("ActiveProcesses", wintypes.DWORD), ("TotalTerminatedProcesses", wintypes.DWORD)]

    class _WinJob:
        """Kill-on-close job object: every descendant, including a daemon that outlives its parent, is reached."""

        def __init__(self):
            k = self.k = ctypes.WinDLL("kernel32", use_last_error=True)
            k.CreateJobObjectW.restype = wintypes.HANDLE
            k.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
            k.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
            k.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
            k.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
            k.QueryInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p]
            k.CloseHandle.argtypes = [wintypes.HANDLE]
            self.h = k.CreateJobObjectW(None, None)
            if not self.h:
                raise OSError(ctypes.get_last_error(), "CreateJobObject failed")
            info = _Ext()
            info.Basic.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if not k.SetInformationJobObject(self.h, 9, ctypes.byref(info), ctypes.sizeof(info)):
                raise OSError(ctypes.get_last_error(), "SetInformationJobObject failed")

        def adopt(self, proc):
            """Put a process that was created suspended into the job, then let it run."""
            h = int(proc._handle)
            if not self.k.AssignProcessToJobObject(self.h, h):
                raise OSError(ctypes.get_last_error(), "AssignProcessToJobObject failed")
            nt = ctypes.WinDLL("ntdll")
            nt.NtResumeProcess.argtypes = [wintypes.HANDLE]
            if nt.NtResumeProcess(h) != 0:
                raise OSError("NtResumeProcess failed")

        def active(self):
            a = _Acct()
            ok = self.k.QueryInformationJobObject(self.h, 1, ctypes.byref(a), ctypes.sizeof(a), None)
            return a.ActiveProcesses if ok else 0

        def terminate(self):
            self.k.TerminateJobObject(self.h, 1)
            end = time.time() + 10
            while time.time() < end and self.active() > 0:
                time.sleep(0.05)
            self.k.CloseHandle(self.h)
            self.h = None


class ProcessTree:
    """Owns every process one workload starts, so kill() ends the whole tree.
    Windows: a job object. POSIX: one session per command, killed by process group.
    ponytail: a POSIX daemon that calls setsid escapes the group; use a cgroup if that ever matters (run on real Linux only)."""

    def __init__(self):
        self.pgids = []
        self.job = _WinJob() if os.name == "nt" else None

    def popen(self, argv, cwd, out):
        common = dict(cwd=cwd, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT)
        if self.job is not None:
            # CREATE_SUSPENDED | CREATE_NO_WINDOW: join the job before the first instruction runs
            p = subprocess.Popen(argv, creationflags=0x00000004 | 0x08000000, **common)
            try:
                self.job.adopt(p)
            except OSError:
                p.kill()
                raise
            return p
        p = subprocess.Popen(argv, start_new_session=True, **common)
        self.pgids.append(p.pid)
        return p

    def kill(self):
        if self.job is not None and self.job.h:
            self.job.terminate()
        for pg in self.pgids:
            try:
                os.killpg(pg, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        self.pgids = []


def evaluate(d, r, text):
    """Verdict on one result, recomputed from the definition, the recorded exit code and artifacts, and the log text
    (None = log missing or not matching its recorded hash). The result's own status/expected fields are never read."""
    vs = variants_of(d)
    i = r.get("variant_index")
    valid = isinstance(i, int) and not isinstance(i, bool) and 0 <= i < len(vs)
    spec = spec_of(d, i if valid else 0)
    codes = spec.get("expected_exit_codes", [0])
    out = {"expected": "success" if codes == [0] else "failure", "observed": "skipped", "first_error": None, "log_claim": None}
    if r.get("observed") == "skipped":
        return {**out, "status": "skipped", "reasons": list(r.get("reasons") or ["not run"])}
    reasons = []
    if not valid:
        reasons.append("result names no valid variant of the definition")
    elif r.get("variant") != (vs[i].get("requires") or "default"):
        reasons.append("variant name does not match the definition")
    if r.get("def_sha256") != def_sha256(d):
        reasons.append("result was not produced from this definition")
    code = r.get("exit_code")
    timeout = r.get("observed") == "timeout" or code is None
    if timeout:
        out["observed"] = "timeout"
        reasons.append("timeout")
    else:
        out["observed"] = "success" if code == 0 else "failure"
        if code not in codes:
            reasons.append(f"exit code {code} not in expected {codes}")
    forged = False
    if text is None:
        reasons.append("log missing or does not match the recorded hash")
    else:
        fe = out["first_error"] = first_error(text)
        claim = out["log_claim"] = log_claim(
            text, re.compile(spec["claim_success_regex"]) if "claim_success_regex" in spec else CLAIM_OK,
            re.compile(spec["claim_failure_regex"]) if "claim_failure_regex" in spec else CLAIM_BAD)
        if not timeout and claim is not None and claim != out["observed"]:
            forged = True
            reasons.append(f"log claims {claim} but exit code is {code}")
        ef = spec.get("expected_first_error")
        if ef and (not fe or ef.get("contains", "") not in fe["message"] or ("file" in ef and ef["file"] != fe["file"])
                   or ("line" in ef and ef["line"] != fe["line"])):
            reasons.append("first causal error does not match the expected one")
    arts = r.get("artifacts") or []
    for g in spec.get("artifact_globs", []):
        if not any(a.get("glob") == g for a in arts):
            reasons.append(f"artifact glob matched nothing: {g}")
    got = {a.get("name"): a.get("sha256") for a in arts}
    for n, h in spec.get("expected_hashes", {}).items():
        if got.get(n) != h:
            reasons.append(f"artifact hash mismatch: {n}")
    status = "timeout" if timeout else "forged-green" if forged else "fail" if reasons else "pass"
    return {**out, "status": status, "reasons": reasons}


def run_workload(d, work_root, fixtures, log_dir):
    t0 = time.time()
    started = now()
    res = {"id": d["id"], "variant": None, "variant_index": None, "def_sha256": def_sha256(d), "status": "skipped",
           "expected": None, "observed": "skipped", "exit_code": None, "expected_exit_codes": None, "started_at": started,
           "ended_at": started, "duration_s": 0.0, "command": "", "artifacts": [], "first_error": None, "log_sha256": None,
           "log_claim": None, "reasons": []}
    idx = next((i for i, v in enumerate(variants_of(d)) if v.get("requires") is None or shutil.which(v["requires"])), None)
    if idx is None:
        res["reasons"].append("no variant of the workload is runnable on this host")
        return res
    spec, req = spec_of(d, idx), variants_of(d)[idx].get("requires")
    res["variant"], res["variant_index"] = req or "default", idx
    res["expected_exit_codes"] = spec.get("expected_exit_codes", [0])
    wd = tempfile.mkdtemp(prefix="wl-", dir=work_root)
    ctx = {"python": sys.executable, "fixtures": fixtures, "work": wd, "exe": ".exe" if os.name == "nt" else ""}
    cmds = [[_subst(a, ctx) for a in c] for c in spec["commands"]]
    res["command"] = " && ".join(" ".join(c) for c in cmds)
    os.makedirs(log_dir, exist_ok=True)
    lp = os.path.join(log_dir, log_name(d["id"]))
    code, timeout = None, False
    tree = ProcessTree()
    try:
        # output goes to a file, not a pipe: a daemon grandchild holding the handle cannot block the harness
        with open(lp, "wb") as out:
            for c in cmds:
                try:
                    p = tree.popen(c, wd, out)
                except OSError as e:
                    out.write(f"error: cannot start {c[0]}: {e}\n".encode())
                    code = 127
                    break
                try:
                    code = p.wait(timeout=spec.get("timeout_s", 120))
                except subprocess.TimeoutExpired:
                    timeout, code = True, None
                    tree.kill()
                    p.wait()
                    break
                if code != 0:
                    break
    finally:
        tree.kill()  # also ends daemons a command left behind
    with open(lp, "rb") as f:
        log = f.read()
    res["log_sha256"] = hashlib.sha256(log).hexdigest()
    res["exit_code"] = code
    res["observed"] = "timeout" if timeout else "ran"
    for g in spec.get("artifact_globs", []):
        for x in sorted(glob.glob(os.path.join(wd, g), recursive=True)):
            if os.path.isfile(x):
                res["artifacts"].append({"name": os.path.relpath(x, wd).replace("\\", "/"), "bytes": os.path.getsize(x),
                                         "sha256": sha256_file(x), "glob": g})
    ev = evaluate(d, res, log.decode("utf-8", "replace"))
    res.update({k: ev[k] for k in ("status", "reasons", "expected", "observed", "first_error", "log_claim")})
    res["ended_at"] = now()
    res["duration_s"] = round(time.time() - t0, 3)
    return res


def load_defs(p):
    files = sorted(glob.glob(os.path.join(p, "*.json"))) if os.path.isdir(p) else [p]
    defs = [load(f) for f in files]
    names = set()
    for d in defs:
        wid = d.get("id")
        if not isinstance(wid, str) or not ID_RE.match(wid) or any(s in ("", ".", "..") for s in wid.split("/")):
            die(f"bad workload id: {wid!r}")
        if log_name(wid) in names:
            die(f"duplicate or colliding workload id: {wid}")
        names.add(log_name(wid))
        codes = d.get("expected_exit_codes", [0])
        if not (isinstance(codes, list) and codes and all(isinstance(c, int) and not isinstance(c, bool) for c in codes)
                and (codes == [0] or 0 not in codes)):
            die(f"{wid}: expected_exit_codes must be [0] or a list of nonzero codes")
        for i in range(len(variants_of(d))):
            cmds = spec_of(d, i).get("commands")
            if not (isinstance(cmds, list) and cmds and all(isinstance(c, list) and c and all(isinstance(a, str) for a in c) for c in cmds)):
                die(f"{wid}: every variant needs commands as a list of argv lists")
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


def _results(path):
    rs = load(path).get("results") if path else []
    if not isinstance(rs, list):
        die("results file has no 'results' list")
    by, dup = {}, set()
    for r in rs:
        if r.get("id") in by:
            dup.add(r.get("id"))
        by[r.get("id")] = r
    return by, dup


def _judge(d, r, results_path):
    """Evaluate a result using the log file stored next to its results file."""
    p = os.path.join(os.path.dirname(os.path.abspath(results_path)), "logs", log_name(r["id"]))
    try:
        with open(p, "rb") as f:
            raw = f.read()
    except OSError:
        raw = None
    text = raw.decode("utf-8", "replace") if raw is not None and hashlib.sha256(raw).hexdigest() == r.get("log_sha256") else None
    return evaluate(d, r, text)


def _fail(row, why):
    if row["status"] == "pass":
        row["status"] = "fail"
    row["reasons"].append(why)


def behaviour_section(defs, results_path, ref_path=None):
    """Every defined workload needs a passing result recomputed from its definition. Returns (section, {id: (row, result)})."""
    if not defs:
        return {"status": "missing", "results": [], "reasons": ["no workloads defined; inventory cannot substitute for behaviour"]}, {}
    by, dup = _results(results_path)
    refs, rdup = _results(ref_path) if ref_path else (None, set())
    rows, internal = [], {}
    for d in defs:
        wid, r = d["id"], by.get(d["id"])
        if r is None:
            row = {"id": wid, "status": "skipped", "expected": "success" if d.get("expected_exit_codes", [0]) == [0] else "failure",
                   "observed": "skipped", "reasons": ["no result for this workload"]}
        else:
            ev = _judge(d, r, results_path)
            row = {"id": wid, "status": ev["status"], "reasons": list(ev["reasons"]), "expected": ev["expected"],
                   "observed": ev["observed"], "exit_code": r.get("exit_code"), "variant": r.get("variant"),
                   "variant_index": r.get("variant_index")}
            if wid in dup:
                _fail(row, "more than one result for this workload")
            rr = None
            if refs is not None:
                rr = refs.get(wid)
                if rr is None or wid in rdup:
                    _fail(row, "reference result missing (or duplicated) for this workload")
                    rr = None
                else:
                    rev = _judge(d, rr, ref_path)
                    if rev["status"] != "pass":
                        _fail(row, "reference result does not match its own oracle (invalid reference evidence): " + "; ".join(rev["reasons"]))
                    elif row["status"] == "pass":
                        if (rr.get("exit_code"), (rev["first_error"] or {}).get("message")) != (r.get("exit_code"), (ev["first_error"] or {}).get("message")):
                            _fail(row, "exit code or first causal error differs from the reference run")
                        ra, ca = rr.get("artifacts") or [], r.get("artifacts") or []
                        if spec_of(d, 0).get("compare_artifacts") == "names":
                            same = sorted(x["name"] for x in ra) == sorted(x["name"] for x in ca)
                        else:
                            same = {x["name"]: x["sha256"] for x in ra} == {x["name"]: x["sha256"] for x in ca}
                        if not same:
                            _fail(row, "artifacts differ from the reference run")
            if row["status"] == "pass" and r.get("variant_index") != 0:
                if not (rr is not None and rr.get("variant_index") == r.get("variant_index")):
                    _fail(row, f"variant {r.get('variant_index')} ran; only the first declared variant (or the reference run's variant) can certify")
        rows.append(row)
        internal[wid] = (row, r)
    return {"status": "pass" if all(x["status"] == "pass" for x in rows) else "fail", "results": rows}, internal


# ---------------------------------------------------------------- evidence

def _ascii(s, n):
    return re.sub(r"[^ -~]", "?", str(s))[:n]


def _art(path, name=None):
    return {"name": re.sub(r"[^A-Za-z0-9._-]", "_", name or os.path.basename(path))[:120], "bytes": os.path.getsize(path), "sha256": sha256_file(path)}


def build_records(a, ref, cand, pin, report, internal, defs, out):
    head = a.head_sha or pin["source_sha"]
    if not SHA1.match(head):
        die("--head-sha must be a full 40-hex SHA")
    acts = cand["run_identity"].get("action_shas") or []
    for s in acts:
        if not ACTION.match(s):
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
    for d in defs:
        row, r = internal[d["id"]]
        exp, obs, st = row["expected"], row["observed"], row["status"]
        fid = "workload/" + d["id"]
        if r is None or st == "skipped":
            recs.append({**base, "fixture_id": fid, "command": "(not run)", "started_at": t, "ended_at": t, "exit_status": None,
                         "oracle": {"expected": exp, "observed": "skipped"}, "result": "skipped", "artifacts": []})
            continue
        result = "pass" if st == "pass" else "timeout" if obs == "timeout" else "fail"
        if result == "fail" and obs == exp:
            obs = "unknown"  # the exit code agrees with the oracle but the result is still not trusted
        seen, a2 = set(), []
        for x in r.get("artifacts") or []:
            n = re.sub(r"[^A-Za-z0-9._-]", "_", x["name"])[:120]
            if (n, x["sha256"]) not in seen:
                seen.add((n, x["sha256"]))
                a2.append({"name": n, "bytes": x["bytes"], "sha256": x["sha256"]})
        lp = os.path.join(os.path.dirname(os.path.abspath(a.results)), "logs", log_name(d["id"]))
        if os.path.isfile(lp) and sha256_file(lp) == r.get("log_sha256"):
            a2.append(_art(lp, log_name(d["id"])))
        recs.append({**base, "fixture_id": fid, "command": _ascii(r.get("command") or "", 500) or "(none)",
                     "started_at": r["started_at"], "ended_at": r["ended_at"], "exit_status": r.get("exit_code"),
                     "oracle": {"expected": exp, "observed": obs}, "result": result, "artifacts": a2[:64]})
    return recs


def validate_records(files):
    """Run the contract validator over the evidence records. Fails closed: no validator means not validated."""
    validator = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "parity", "contracts", "validate.py")
    if not os.path.isfile(validator):
        print("certify: parity/contracts/validate.py not found; evidence records are NOT validated", file=sys.stderr)
        return "unavailable"
    p = subprocess.run([sys.executable, "-I", validator, "evidence-bundle"] + files, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(p.stdout.strip())
    if p.returncode:
        print("certify: evidence records failed validate.py evidence-bundle", file=sys.stderr)
    return "pass" if p.returncode == 0 else "fail"


def cmd_certify(a):
    allow = load_allow(a.allowlist)
    pin = load_pin(a.pin, full=True)
    ref, cand = load(a.reference), load(a.candidate)
    require_complete(ref)
    defs = load_defs(a.defs) if a.defs else []
    inv = inventory_section(ref, cand, allow, pin)
    beh, internal = behaviour_section(defs, a.results, a.reference_results)
    out = a.out
    os.makedirs(out, exist_ok=True)
    for stale in ("verdict.json", "parity-report.json"):  # a failed run must never leave an older pass behind
        if os.path.exists(os.path.join(out, stale)):
            os.remove(os.path.join(out, stale))
    shutil.rmtree(os.path.join(out, "evidence"), ignore_errors=True)
    shutil.copyfile(a.reference, os.path.join(out, "reference-inventory.json"))
    shutil.copyfile(a.candidate, os.path.join(out, "candidate-inventory.json"))
    report = {"schema": SCHEMA, "kind": "parity-report", "generated_at": now(), "pin": pin,
              "reference": {"source": ref["source"], "image": ref["image"]}, "candidate": {"source": cand["source"], "image": cand["image"]},
              "inventory": inv, "behaviour": beh}
    dump(report, os.path.join(out, "parity-report.json"))
    recs = build_records(a, ref, cand, pin, report, internal, defs, out)
    ev = os.path.join(out, "evidence")
    os.makedirs(ev, exist_ok=True)
    files = []
    for r in recs:
        f = os.path.join(ev, r["fixture_id"].replace("/", "__") + ".json")
        dump(r, f)
        files.append(f)
    validation = validate_records(files)
    sections_ok = inv["status"] == "pass" and beh["status"] == "pass"
    verdict = "pass" if sections_ok and validation == "pass" else "fail"
    dump({"schema": SCHEMA, "kind": "parity-verdict", "verdict": verdict, "inventory": inv["status"], "behaviour": beh["status"],
          "evidence_validation": validation, "report_sha256": sha256_file(os.path.join(out, "parity-report.json")),
          "evidence_records": sorted(os.path.basename(f) for f in files)}, os.path.join(out, "verdict.json"))
    print(f"inventory: {inv['status']} {inv['counts']}; identity: {inv['identity']['status']}; behaviour: {beh['status']}; "
          f"evidence: {validation}; verdict: {verdict}")
    if validation != "pass":
        return 3
    return 0 if verdict == "pass" else 1


def cmd_compare(a):
    ref, cand = load(a.reference), load(a.candidate)
    sections = a.sections.split(",") if a.sections else None
    require_complete(ref, sections)
    sec = inventory_section(ref, cand, load_allow(a.allowlist), load_pin(a.pin, full=False) if a.pin else None, sections)
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
    for n in ("reference", "candidate", "out", "pin"):
        p.add_argument("--" + n, required=True)
    for n in ("allowlist", "defs", "results", "reference-results", "head-sha", "candidate-generation", "candidate-base-sha256"):
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
