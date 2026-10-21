"""Validate the P02 shared-contract fixtures. Standard library only; run with `python -B -I`.

    python -B -I parity/contracts/validate.py                      # every fixture
    python -B -I parity/contracts/validate.py <contract> <file>...  # real documents

For every `<name>.schema.json` next to this file:
  * fixtures/<name>/valid/*.json must pass the schema and the contract's semantic rules;
  * fixtures/<name>/invalid/*.json hold {"expect": "<substring>", "instance": {...}} and must be
    rejected with an error message containing "expect" (so a fixture cannot pass for the wrong
    reason). Every schema needs at least one valid and three invalid fixtures.

Implements the JSON Schema draft 2020-12 subset these schemas use: type, enum, const,
properties, required, additionalProperties, items, minItems, maxItems, uniqueItems,
minimum, maximum, minLength, maxLength, pattern, $ref (local "#/$defs/..."), oneOf, anyOf,
allOf, not, if/then/else. Unknown keywords in a schema are an error, so a schema can never
rely on a keyword this validator silently ignores. Cross-field rules JSON Schema cannot
express (sums, cross-references) live in SEMANTIC below and are part of the contract.
A pattern's `$` means end of input, as in ECMA-262: Python's `$` would also match before a final
newline, so check() anchors at the end of the string instead. Documents are bounded to 256 KiB.
Exit 0 when everything holds, 1 otherwise.
"""
import ipaddress
import json
import math
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
KNOWN = {
    "$schema", "$id", "$defs", "$comment", "title", "description", "x-contract-version", "x-owner",
    "type", "enum", "const", "properties", "required", "additionalProperties", "items",
    "minItems", "maxItems", "uniqueItems", "minimum", "maximum", "minLength", "maxLength",
    "pattern", "$ref", "oneOf", "anyOf", "allOf", "not", "if", "then", "else",
}


class Invalid(Exception):
    pass


def _type_ok(value, t):
    if t == "null":
        return value is None
    if t == "boolean":
        return isinstance(value, bool)
    if t == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if t == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    if t == "string":
        return isinstance(value, str)
    if t == "array":
        return isinstance(value, list)
    if t == "object":
        return isinstance(value, dict)
    raise Invalid(f"schema uses unknown type {t!r}")


def check(schema, value, root, path="$"):
    """Raise Invalid with a path-qualified message on the first violation."""
    if schema is True:
        return
    if schema is False:
        raise Invalid(f"{path}: not allowed")
    unknown = set(schema) - KNOWN
    if unknown:
        raise Invalid(f"schema at {path} uses unsupported keywords {sorted(unknown)}")
    if "$ref" in schema:
        ref = schema["$ref"]
        if not ref.startswith("#/$defs/"):
            raise Invalid(f"{path}: only local $defs refs are supported, got {ref}")
        check(root["$defs"][ref[len("#/$defs/"):]], value, root, path)
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_type_ok(value, t) for t in types):
            raise Invalid(f"{path}: expected type {'|'.join(types)}")
    if "const" in schema and not _same(value, schema["const"]):
        raise Invalid(f"{path}: must be {json.dumps(schema['const'])}")
    if "enum" in schema and not any(_same(value, e) for e in schema["enum"]):
        raise Invalid(f"{path}: {json.dumps(value)} not in enum")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            raise Invalid(f"{path}: below minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            raise Invalid(f"{path}: above maximum {schema['maximum']}")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            raise Invalid(f"{path}: shorter than {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            raise Invalid(f"{path}: longer than {schema['maxLength']}")
        if "pattern" in schema and not re.search(_ecma(schema["pattern"]), value):
            raise Invalid(f"{path}: does not match pattern {schema['pattern']}")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            raise Invalid(f"{path}: fewer than {schema['minItems']} items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            raise Invalid(f"{path}: more than {schema['maxItems']} items")
        if schema.get("uniqueItems"):
            seen = [json.dumps(v, sort_keys=True) for v in value]
            if len(seen) != len(set(seen)):
                raise Invalid(f"{path}: items not unique")
        if "items" in schema:
            for i, item in enumerate(value):
                check(schema["items"], item, root, f"{path}[{i}]")
    if isinstance(value, dict):
        for name in schema.get("required", []):
            if name not in value:
                raise Invalid(f"{path}: missing required property {name!r}")
        props = schema.get("properties", {})
        for name, sub in value.items():
            if name in props:
                check(props[name], sub, root, f"{path}.{name}")
            elif "additionalProperties" in schema:
                ap = schema["additionalProperties"]
                if ap is False:
                    raise Invalid(f"{path}: unexpected property {name!r}")
                check(ap, sub, root, f"{path}.{name}")
    for sub in schema.get("allOf", []):
        check(sub, value, root, path)
    if "anyOf" in schema:
        errors = _try_all(schema["anyOf"], value, root, path)
        if len(errors) == len(schema["anyOf"]):
            raise Invalid(f"{path}: matches no anyOf branch ({'; '.join(errors)})")
    if "oneOf" in schema:
        errors = _try_all(schema["oneOf"], value, root, path)
        passed = len(schema["oneOf"]) - len(errors)
        if passed != 1:
            raise Invalid(f"{path}: matches {passed} oneOf branches ({'; '.join(errors)})")
    if "not" in schema:
        try:
            check(schema["not"], value, root, path)
        except Invalid:
            pass
        else:
            raise Invalid(f"{path}: matches a forbidden 'not' schema")
    if "if" in schema:
        try:
            check(schema["if"], value, root, path)
            cond = True
        except Invalid:
            cond = False
        branch = schema.get("then" if cond else "else")
        if branch is not None:
            check(branch, value, root, path)


def _ecma(pattern):
    """ECMA-262 `$` is the end of input; Python's `$` also matches before a final newline."""
    return re.sub(r"(?<!\\)\$", r"\\Z", pattern)


def _try_all(subs, value, root, path):
    errors = []
    for sub in subs:
        try:
            check(sub, value, root, path)
        except Invalid as e:
            errors.append(str(e))
    return errors


def _same(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    return a == b


# ---- semantic rules (part of each contract; see the matching .md) ----------------------------

SECRET_KEY = re.compile(r"(token|secret|password|passwd|private_key|jit_config|credential|pem)", re.I)
# Value shapes of GitHub tokens and PEM blocks; never valid in any contract document.
SECRET_VALUE = re.compile(r"(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|SYNTHETIC-JIT-MARKER)")


def _no_secret_values(doc, path="$"):
    if isinstance(doc, dict):
        for k, v in doc.items():
            _no_secret_values(v, f"{path}.{k}")
    elif isinstance(doc, list):
        for i, v in enumerate(doc):
            _no_secret_values(v, f"{path}[{i}]")
    elif isinstance(doc, str) and SECRET_VALUE.search(doc):
        raise Invalid(f"{path}: value has a token or private-key shape")


# _ecma rewrites every `$` not preceded by a backslash to `\Z`. It would miss an anchor after an
# escaped backslash and break a `$` inside a character class, so schemas may use neither form.
ECMA_UNSAFE = re.compile(r"(?<!\\)(?:\\\\)+\$|\[[^\]]*\$")
ENDS_ANCHORED = re.compile(r"(?<!\\)(?:\\\\)*\$\Z")


def _unanchored(pattern):
    """True when a pattern would rely on search semantics: it must start with `^`, end with an
    unescaped `$` and have no `|` outside a group (`^a|b$` matches any string ending in b)."""
    if not pattern.startswith("^") or not ENDS_ANCHORED.search(pattern):
        return True
    depth, i, in_class = 0, 0, False
    while i < len(pattern):
        c = pattern[i]
        if c == "\\":
            i += 2
            continue
        if in_class:
            in_class = c != "]"
        elif c == "[":
            in_class = True
        elif c in "()":
            depth += 1 if c == "(" else -1
        elif c == "|" and depth == 0:
            return True
        i += 1
    return False


def lint_schema(node, path="$", negated=False):
    """Every integer or number in a contract schema has a maximum (security review L1). No
    pattern puts `$` after an escaped backslash or inside a character class (see _ecma), and
    every pattern outside a `not` matches the whole string; under `not` a pattern is a
    deliberate "contains" check (for example a `..` component)."""
    problems = []
    if isinstance(node, dict):
        p = node.get("pattern")
        if isinstance(p, str) and ECMA_UNSAFE.search(p):
            problems.append(f"{path}: pattern form _ecma cannot translate")
        if isinstance(p, str) and not negated and _unanchored(p):
            problems.append(f"{path}: pattern is not anchored as a full-string match")
        t = node.get("type")
        types = t if isinstance(t, list) else [t]
        if ("integer" in types or "number" in types) and "maximum" not in node and "const" not in node and "enum" not in node:
            problems.append(f"{path}: numeric without maximum")
        for k, v in node.items():
            problems += lint_schema(v, f"{path}.{k}", negated or k == "not")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            problems += lint_schema(v, f"{path}[{i}]", negated)
    return problems


def _no_secret_keys(doc, path="$"):
    """Evidence, audit and receipt documents must never carry a field that looks like a secret."""
    if isinstance(doc, dict):
        for k, v in doc.items():
            if k == "secrets" and v == "none recorded":
                continue  # the manual cleanup receipt's explicit attestation, not a secret
            if SECRET_KEY.search(k):
                raise Invalid(f"{path}.{k}: secret-shaped field is forbidden in this document")
            _no_secret_keys(v, f"{path}.{k}")
    elif isinstance(doc, list):
        for i, v in enumerate(doc):
            _no_secret_keys(v, f"{path}[{i}]")


def _profile_caps(doc_host, reserve, mode, profiles):
    """Per-profile caps and per-runner share in (cpus, gib). floor everywhere; the reserve is
    never handed out."""
    pool = (doc_host["cpu_cores"] * (100 - reserve) // 100,
            doc_host["mem_gib"] * (100 - reserve) // 100 - doc_host.get("control_distro_mem_gib", 0))
    total = sum(p["count"] for p in profiles.values())
    caps = {}
    for name, p in profiles.items():
        n = p["count"]
        if mode == "even":
            each = (pool[0] // total, pool[1] // total) if total else (0, 0)
            caps[name] = {"each": each, "cap": (each[0] * n, each[1] * n)}
        else:
            # Memory: the share of the pool after the control VM, so the caps never sum over it.
            cap = (doc_host["cpu_cores"] * p["share_percent"] // 100, pool[1] * p["share_percent"] // (100 - reserve))
            each = (cap[0] // n, cap[1] // n) if n else (0, 0)
            caps[name] = {"each": each, "cap": cap}
    return pool, caps


def _shares(mode, reserve, counts_and_shares):
    if mode == "even":
        if any(s is not None for _, s in counts_and_shares):
            raise Invalid("share_mode even: share_percent must be null")
        return
    if any(s is None for _, s in counts_and_shares):
        raise Invalid("share_mode per_profile: every share_percent is required")
    if sum(s for _, s in counts_and_shares) + reserve != 100:
        raise Invalid("profile shares plus host_reserve_percent must equal 100")
    for count, share in counts_and_shares:
        if (count == 0) != (share == 0):
            raise Invalid("a profile has share 0 exactly when its count is 0")


def _counts(linux, windows):
    if not 1 <= linux + windows <= 5:
        raise Invalid("linux + windows runner counts must be 1..5")


LIVE = {"creating", "ready", "busy", "draining", "collecting", "deleting", "quarantined"}
ADMITTED = {"creating", "ready", "busy"}


def _mem(r):
    """Reserved memory in GiB including the measured VM overhead, rounded up."""
    return r["mem_gib"] + -(-r["mem_overhead_mib"] // 1024)


def vm_name(profile, slot, lease_generation, reservation_id):
    return f"aap-{'w' if profile == 'windows' else 'l'}-{slot}-{lease_generation}-{reservation_id[2:10]}"


def _volumes(volumes, live):
    """Allocator rule 5 for disk: every live reservation's clone and scratch caps count on the volume
    that holds that tier, within available_gib - floor_gib - held_gib of that volume (available_gib is
    measured at admission)."""
    if len(volumes) != len({v["volume_guid"] for v in volumes}):
        raise Invalid("a volume is listed twice")
    tiers = set()
    for v in volumes:
        for t in v["tiers"]:
            if t in tiers:
                raise Invalid(f"tier {t} is on more than one volume")
            tiers.add(t)
    if any(r["backend"] == "hyperv-vm" for r in live) and not {"base", "clone", "scratch"} <= tiers:
        raise Invalid("a VM reservation needs the base, clone and scratch tiers in host.volumes")
    for v in volumes:
        if not {"clone", "scratch"} & set(v["tiers"]):
            continue  # a base or staging volume carries no reservation cap; builds check their own space
        need = sum(r["clone_gib"] * ("clone" in v["tiers"]) + r["scratch_gib"] * ("scratch" in v["tiers"]) for r in live)
        if need > v["available_gib"] - v["floor_gib"] - v["held_gib"]:
            raise Invalid(f"volume {v['volume_guid']}: reservations exceed its disk budget (available minus floor minus held)")


def sem_allocator(doc):
    profiles = doc["profiles"]
    _counts(profiles["linux"]["count"], profiles["windows"]["count"])
    _shares(doc["share_mode"], doc["host_reserve_percent"],
            [(p["count"], p["share_percent"]) for p in profiles.values()])
    if profiles["windows"]["backend"] != "hyperv-vm":
        raise Invalid("the windows profile backend is hyperv-vm")
    live = [r for r in doc["reservations"] if r["state"] in LIVE]
    if len(live) > doc["max_slots"]:
        raise Invalid("more live reservations than max_slots")
    slots = [r["slot"] for r in live]
    if len(slots) != len(set(slots)):
        raise Invalid("two live reservations hold one slot")
    ids = [r["reservation_id"] for r in doc["reservations"]]
    if len(ids) != len(set(ids)):
        raise Invalid("duplicate reservation_id")
    if any(r["backend"] == "hyperv-vm" for r in live) and not doc["legacy_adopted"]:
        raise Invalid("a VM reservation exists before legacy slots were adopted")
    pool, caps = _profile_caps(doc["host"], doc["host_reserve_percent"], doc["share_mode"], profiles)
    for name in ("linux", "windows"):
        # A heartbeat quarantine holds capacity and may still be running its job, so it counts as admitted.
        admitted = [r for r in live if r["profile"] == name and
                    (r["state"] in ADMITTED or (r["state"] == "quarantined" and r["quarantine_kind"] == "heartbeat"))]
        if len(admitted) > profiles[name]["count"]:
            raise Invalid(f"{name}: more admitted reservations than the profile count")
        each = caps[name]["each"]
        for r in admitted:
            if r["backend"] != profiles[name]["backend"]:
                raise Invalid(f"{r['reservation_id']}: admitted on a backend other than the profile's")
            if r["cpus"] > each[0] or _mem(r) > each[1]:
                raise Invalid(f"{r['reservation_id']}: exceeds the per-runner share of {name}")
        if sum(r["cpus"] for r in admitted) > caps[name]["cap"][0] or sum(_mem(r) for r in admitted) > caps[name]["cap"][1]:
            raise Invalid(f"{name}: admitted reservations exceed the profile cap")
    # Draining overhang still occupies the pool: the other profile is admitted only into what is left.
    if sum(r["cpus"] for r in live) > pool[0] or sum(_mem(r) for r in live) > pool[1]:
        raise Invalid("reservations exceed the pool; the host reserve is never given away")
    host = doc["host"]
    _volumes(host["volumes"], live)
    if host["io_mbps"] == 0:
        if any(r["io_mbps"] for r in live):
            raise Invalid("io_mbps reserved while host IO is unmeasured")
    elif sum(r["io_mbps"] for r in live) > host["io_mbps"] * (100 - doc["host_reserve_percent"]) // 100:
        raise Invalid("reservations exceed the IO budget")
    gens = doc["slot_generations"]
    for r in doc["reservations"]:
        rid = r["reservation_id"]
        if r["state"] in LIVE and r["lease_generation"] != gens[r["slot"] - 1]:
            raise Invalid(f"{rid}: lease_generation is not the slot's current generation")
        if r["lease_generation"] > gens[r["slot"] - 1]:
            raise Invalid(f"{rid}: lease_generation ahead of the slot counter")
        if r["backend"] == "wsl-legacy":
            if r["profile"] != "linux" or r["vm_id"] is not None or not r["image_generation"].startswith("legacy-"):
                raise Invalid(f"{rid}: legacy reservations are linux, vm_id null, generation legacy-*")
            if r["clone_gib"] or r["scratch_gib"]:
                raise Invalid(f"{rid}: legacy reservations reserve no VM disk")
        else:
            if r["clone_gib"] < 1:
                raise Invalid(f"{rid}: a VM reservation reserves at least 1 GiB of clone disk")
            if r["state"] not in ("creating", "reconciled") and r["vm_id"] is None:
                raise Invalid(f"{rid}: a VM reservation past creating names its vm_id")
            if r["runner_name"] is not None and r["runner_name"] != vm_name(r["profile"], r["slot"], r["lease_generation"], rid):
                raise Invalid(f"{rid}: runner_name must be the VM name aap-<w|l>-<slot>-<generation>-<reservation hex>")
        if (r["state"] == "quarantined") != (r["quarantine_kind"] is not None) or (r["quarantine_kind"] is None) != (r["quarantine_reason"] is None):
            raise Invalid(f"{rid}: quarantine_kind and quarantine_reason are set exactly when quarantined")
        proof = r["teardown_proof"]
        if (r["state"] == "reconciled") != (proof is not None):
            raise Invalid(f"{rid}: teardown_proof is present exactly when reconciled")
        if proof is not None and proof["kind"] != ("legacy" if r["backend"] == "wsl-legacy" else "vm"):
            raise Invalid(f"{rid}: teardown_proof kind does not match the backend")
        if r["idempotency_key"] != f"{rid}/{r['lease_generation']}":
            raise Invalid(f"{rid}: idempotency_key must be <reservation_id>/<lease_generation>")


RESERVED_NAMES = {"con", "prn", "aux", "nul"} | {f"{p}{i}" for p in ("com", "lpt") for i in range(10)}


DATA_DIR = "c:\\programdata\\aap-runner"


def _storage_roots(roots):
    """Storage tier roots (backend-lifecycle.md, Storage tiers): no reserved device name, no root equal
    to, inside or containing the data folder (%SystemRoot% and C:\\wsl are runtime checks), no two
    roots the same folder or nested, and drive letters and volume GUIDs map one to one.
    Case-insensitive, as NTFS is."""
    named = {k: v for k, v in roots.items() if v is not None}
    for name, r in named.items():
        for part in r["path"].split("\\")[1:]:
            if part.split(".")[0].rstrip(" ").lower() in RESERVED_NAMES:  # "aux .d" is AUX to Win32
                raise Invalid(f"roots.{name}: {part} is a reserved device name")
        p = r["path"].lower()
        if p == DATA_DIR or p.startswith(DATA_DIR + "\\") or DATA_DIR.startswith(p + "\\"):
            raise Invalid(f"roots.{name} overlaps the data folder C:\\ProgramData\\aap-runner")
    names = sorted(named)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            pa, pb = named[a]["path"].lower(), named[b]["path"].lower()
            if pa == pb:
                raise Invalid(f"roots.{a} and roots.{b} are the same folder")
            for inner, outer, pi, po in ((a, b, pa, pb), (b, a, pb, pa)):
                if pi.startswith(po + "\\"):
                    raise Invalid(f"roots.{inner} is inside roots.{outer}")
            if (pa[0] == pb[0]) != (named[a]["volume_guid"] == named[b]["volume_guid"]):
                raise Invalid(f"roots.{a} and roots.{b}: drive letters and volume GUIDs map one to one")


def sem_backend_lifecycle(doc):
    if doc["kind"] == "storage":
        _storage_roots(doc["roots"])
        return
    if doc["kind"] == "budget":
        for tier in ("clone", "scratch"):
            if doc[f"{tier}_gib_max"] < doc[f"{tier}_peak_gib"]:
                raise Invalid(f"{tier}_gib_max is below the measured {tier}_peak_gib")
        return
    if doc["idempotency_key"] != f"{doc['reservation_id']}/{doc['lease_generation']}/{doc['op']}":
        raise Invalid("idempotency_key must be <reservation_id>/<lease_generation>/<op>")
    if (doc["phase"] == "intent") != (doc["result"] is None):
        raise Invalid("an intent record has no result; done/failed records have one")
    if doc["phase"] == "done" and doc["result"]["code"] not in ("ok", "absent"):
        raise Invalid("phase done requires result ok or absent")
    if doc["backend"] == "hyperv-vm" and doc["op"] != "create" and doc["vm"]["vm_id"] is None:
        raise Invalid("every op after create names the vm_id")
    name = doc["vm"]["vm_name"]
    if name is not None and not name.endswith("-" + doc["reservation_id"][2:10]):
        raise Invalid("vm_name must end with the first 8 hex of the reservation_id")
    rid = doc["reservation_id"]
    # Relative to the role's tier root: base_root, clone_root (os_diff, seed) or scratch_root.
    exact = {"base_ref": f"{doc['image_generation']}/base.vhdx", "os_diff": f"{rid}/os.avhdx",
             "seed": f"{rid}/seed.iso", "scratch": f"{rid}/scratch.vhdx"}
    for d in doc["disks"]:
        if d["path"] != exact[d["role"]]:
            raise Invalid(f"disk {d['role']}: path must be exactly {exact[d['role']]}")


def sem_broker(doc):
    kind = doc["kind"]
    if kind.endswith("_request"):
        if len(json.dumps(doc, separators=(",", ":")).encode()) > 4096:
            raise Invalid("request larger than 4096 bytes")
    if kind == "lease_response":
        issued = doc["result"] == "issued"
        fields = (doc["jit_config"], doc["runner_id"], doc["runner_name"], doc["expires_at"])
        if issued and (doc["reason"] != "ok" or any(f is None for f in fields)):
            raise Invalid("an issued lease carries reason ok, jit_config, runner_id, runner_name and expires_at")
        if not issued and (doc["reason"] == "ok" or any(f is not None for f in fields)):
            raise Invalid("a refused lease carries a refusal reason and no registration material")
    if kind == "status_response":
        if (doc["result"] == "ok") != (doc["reason"] == "ok"):
            raise Invalid("status result ok exactly when reason ok")
        if doc["result"] != "ok" and doc["runner"] is not None:
            raise Invalid("a refused status carries no runner state")
    if kind == "audit":
        _no_secret_keys(doc)


def sem_guest_transport(doc):
    if doc["kind"] == "exchange":
        sem_guest_transport(doc["cmd"])
        sem_guest_transport(doc["reply"])
        for k in ("vm_id", "reservation_id", "lease_generation", "seq", "nonce"):
            if doc["cmd"][k] != doc["reply"][k]:
                raise Invalid(f"reply does not echo {k}: hostile guest")
        return
    if doc["kind"] == "host_cmd":
        if (doc["cmd"] == "deliver_registration") != (doc["payload_bytes"] > 0):
            raise Invalid("payload_bytes > 0 exactly for deliver_registration")
    else:
        if len(json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode()) > 8192:
            raise Invalid("reply larger than 8192 bytes")
        _no_secret_keys(doc)


def sem_image_catalog(doc):
    gens = {}
    for g in doc["generations"]:
        if g["generation_id"] in gens:
            raise Invalid(f"duplicate generation {g['generation_id']}")
        gens[g["generation_id"]] = g
        if not g["generation_id"].startswith(g["profile"] + "/"):
            raise Invalid(f"{g['generation_id']}: id must start with its profile")
        for a in g["artifacts"]:
            if not a["path"].startswith(g["generation_id"] + "/"):
                raise Invalid(f"{g['generation_id']}: artifact {a['path']} is outside its generation folder; "
                              "artifacts stay in <base_root>/<generation_id>/ and never move")
        if doc["scope"] == "live" and g["state"] == "active" and g["live_activation"] is None:
            raise Invalid(f"{g['generation_id']}: active in a live catalog requires the owner's live activation record (gate D5)")
        if g["state"] in ("approved", "active", "retired"):
            if g["certification"]["certificate_ref"] is None or g["approved_by"] is None:
                raise Invalid(f"{g['generation_id']}: {g['state']} requires a certificate and an approver")
            if g["secret_scan"]["result"] != "clean":
                raise Invalid(f"{g['generation_id']}: {g['state']} requires a clean secret scan")
        if (g["state"] == "quarantined") != (g["quarantine_reason"] is not None):
            raise Invalid(f"{g['generation_id']}: quarantine_reason is set exactly when quarantined")
    for profile, ptr in doc["profiles"].items():
        actives = [g for g in gens.values() if g["profile"] == profile and g["state"] == "active"]
        if len(actives) > 1:
            raise Invalid(f"{profile}: more than one active generation")
        for key, want in (("active", "active"), ("rollback", "retired")):
            gid = ptr[key]
            if gid is None:
                continue
            g = gens.get(gid)
            if g is None or g["profile"] != profile or g["state"] != want:
                raise Invalid(f"{profile}.{key} must name a {want} generation of that profile")
        if actives and ptr["active"] != actives[0]["generation_id"]:
            raise Invalid(f"{profile}: active pointer does not name the active generation")


def sem_cache_qualification(doc):
    if "sccache" in json.dumps(doc).lower():
        raise Invalid("sccache is not a permitted mode, fallback or path")
    seen = set()
    for row in doc["rows"]:
        key = (row["compiler"], row["compiler_version"], row["invocation"])
        if key in seen:
            raise Invalid(f"duplicate row for {key}")
        seen.add(key)
        if row["mode"] == "qualified" and row["evidence_ref"] is None:
            raise Invalid(f"{row['compiler']}/{row['invocation']}: qualified requires evidence_ref")
        if row["compiler"] == "nvcc" and row["mode"] != "direct":
            raise Invalid("nvcc is unsupported at 1.15.6 and always direct")


def sem_settings_v3(doc):
    _counts(doc["runner_count"], doc["windows_runner_count"])
    _shares(doc["share_mode"], doc["host_reserve_percent"],
            [(doc["runner_count"], doc["linux_share_percent"]), (doc["windows_runner_count"], doc["windows_share_percent"])])


def sem_status_v5(doc):
    names = [p["profile"] for p in doc["profiles"]]
    if sorted(names) != ["linux", "windows"]:
        raise Invalid("profiles lists linux and windows exactly once")
    _counts(*(p["count"] for p in sorted(doc["profiles"], key=lambda p: p["profile"])))
    os_of = {"linux": "Linux", "windows": "Windows"}
    for p in doc["profiles"]:
        if p["os"] != os_of[p["profile"]]:
            raise Invalid(f"profile {p['profile']} reports os {p['os']}")
        if (p["image_generation"] is None) != (p["generation_state"] is None):
            raise Invalid(f"profile {p['profile']}: generation_state is null exactly when image_generation is null")
    slots = [s["slot"] for s in doc["slots"]]
    if len(slots) != len(set(slots)):
        raise Invalid("duplicate slot number")
    for s in doc["slots"]:
        if s["os"] != os_of[s["profile"]]:
            raise Invalid(f"slot {s['slot']}: os does not match profile")
    if 2 not in doc["settings_schemas"]:
        raise Invalid("settings_schemas must keep accepting schema 2")
    if doc["capacity"]["used_slots"] + doc["capacity"]["free_slots"] != doc["capacity"]["max_slots"]:
        raise Invalid("used_slots + free_slots must equal max_slots")
    _status_storage(doc["storage"], doc["profiles"])


def _status_storage(st, profiles):
    tiers, floor = st["tiers"], st["volume_floor_gib"]
    if st["state"] == "unconfigured":
        if tiers or floor is not None:
            raise Invalid("unconfigured storage reports no tiers and no floor")
    else:
        if sorted(t["tier"] for t in tiers) != ["base", "clone", "scratch", "staging"] or floor is None:
            raise Invalid("configured storage reports the floor and base, clone, scratch and staging once each")
        for t in tiers:
            free = t["volume_free_gib"]
            if (t["state"] == "missing") != (free is None) and t["state"] != "untrusted":
                raise Invalid(f"tier {t['tier']}: free space is null exactly when the tier is missing")
            if t["state"] == "ok" and free < floor:
                raise Invalid(f"tier {t['tier']} is below the floor but reported ok")
            if t["state"] == "low" and free >= floor:
                raise Invalid(f"tier {t['tier']} is above the floor but reported low")
        worst = next((s for s in ("missing", "untrusted", "low") if any(t["state"] == s for t in tiers)), "ok")
        if st["state"] != worst:
            raise Invalid(f"storage state must be {worst}, the worst tier state")
    if st["state"] != "ok":
        for p in profiles:
            if p["backend"] == "hyperv-vm" and p["available"]:
                raise Invalid(f"hyperv-vm profile {p['profile']} is available while storage is {st['state']}")


def sem_evidence_bundle(doc):
    _no_secret_keys(doc)
    o = doc["oracle"]
    if doc["result"] == "pass" and o["observed"] != o["expected"]:
        raise Invalid("result pass requires observed == expected")
    if doc["result"] == "fail" and o["observed"] == o["expected"]:
        raise Invalid("result fail with a matching oracle")
    if doc["result"] in ("skipped", "blocked", "timeout", "unknown") and o["observed"] != doc["result"]:
        raise Invalid("skipped, blocked, timeout and unknown are reported as observed, never as pass")
    if o["expected"] == "success" and o["observed"] == "success" and doc["exit_status"] != 0:
        raise Invalid("an observed success must have exit_status 0")
    waivers = [(w["kind"], w["definition_id"]) for w in doc.get("waivers", [])]
    if len(waivers) != len(set(waivers)):
        raise Invalid("duplicate waiver for one kind and definition")
    for _, definition in waivers:
        if doc["fixture_id"] != "workload/" + definition:
            raise Invalid(f"waiver for {definition} on fixture {doc['fixture_id']}: a record waives only its own workload")


def sem_cleanup_receipt(doc):
    _no_secret_keys(doc)
    actor = doc["implementer"] if "schema" in doc else doc["cleanup_actor"]
    if doc["verifier"] == actor:
        raise Invalid("verifier must be independent of the implementer")
    for d in doc["disposed"]:
        if d["observed_absent"] is not True:
            raise Invalid(f"disposed {d.get('id', d.get('resource'))}: absence not observed")


def _host_net_ranges(name):
    """A list of ranges read from its one copy, the shared check (host-network-module.md, Rules and weights): FixedDeny, the
    fixed deny ranges, or PrivateRanges, the fixed ranges a NAT routes unicast in."""
    path = HERE.parent.parent / "supervisor" / "network" / "AapHostNetworkCheck.psm1"
    m = re.search(r"^\$script:" + name + r" = @\(([^)]*)\)", path.read_text(encoding="utf-8"), re.M)
    if not m:
        raise Invalid(f"no $script:{name} list in {path.name}")
    return [ipaddress.ip_network(s) for s in re.findall(r"'([^']+)'", m.group(1))]


def _host_net_private(net):
    """IPv4 and inside a range a NAT routes unicast in (the shared check's Test-AapNetPrivate)."""
    return net.version == 4 and any(net.subnet_of(f) for f in _host_net_ranges("PrivateRanges"))


def _host_net_declaration(d):
    """host-network-module.md, Attach: the name's letter is the profile's; a private subnet holding the gateway and the
    VM's static address; the endpoints one private resolver outside the subnet (UDP and TCP 53, the schema's part) that is
    one of the resolvers; every other resolver public (outside every fixed range). The shared check's
    Get-AapHostNetworkDeclarationProblems applies the same rules."""
    if d["vm_name"][4] != d["profile"][0]:
        raise Invalid(f"vm_name {d['vm_name']} does not match profile {d['profile']}")
    fixed = _host_net_ranges("FixedDeny")
    try:
        net = ipaddress.ip_network(d["subnet"])
    except ValueError:
        raise Invalid(f"subnet {d['subnet']} is not a network address")
    if not _host_net_private(net):
        raise Invalid(f"subnet {d['subnet']} is not inside a private fixed range")
    def host(a):
        ip = ipaddress.ip_address(a)
        return ip in net and ip not in (net.network_address, net.broadcast_address)

    if not host(d["gateway"]):
        raise Invalid(f"gateway {d['gateway']} is not a host address of {d['subnet']}")
    if not host(d["address"]) or d["address"] == d["gateway"]:
        raise Invalid(f"address {d['address']} is not a host address of {d['subnet']} other than the gateway")
    on53 = set()
    for e in d["endpoints"]:
        ip = ipaddress.ip_network(e["address"])
        if not _host_net_private(ip) or ip.subnet_of(net):
            raise Invalid(f"endpoint {e['address']} is not one private IPv4 address outside {d['subnet']}")
        on53.add(e["address"])
    if len(on53) > 1:
        raise Invalid(f"endpoints name {len(on53)} addresses, not one resolver")
    for r in d["resolvers"]:
        if any(f.version == 4 and ipaddress.ip_network(r).subnet_of(f) for f in fixed) and r not in on53:
            raise Invalid(f"resolver {r} is neither public nor a declared endpoint on port 53")
    for a in sorted(on53 - set(d["resolvers"])):
        raise Invalid(f"endpoint {a} is not one of the resolvers")


def sem_host_network_module(doc):
    if isinstance(doc, list):
        return  # Verify's problem list: the schema is the whole rule
    if doc["kind"] == "host_network_attach":
        _host_net_declaration(doc)
    else:
        _host_net_declaration(doc["declaration"])
        if [c["kind"] for c in doc["created"]].count("adapter") != 1:
            raise Invalid("a record names exactly one adapter")
        for c in doc["created"]:
            if not c["name"].endswith("-" + doc["declaration"]["vm_id"]):
                raise Invalid(f"a record names {c['name']}, not one of VM {doc['declaration']['vm_id']}")
            if c["name"].startswith(("aap-guests-", "aap-build-")):
                raise Invalid(f"a record names {c['name']}, a switch P19 owns")


SEMANTIC = {
    "allocator": sem_allocator,
    "backend-lifecycle": sem_backend_lifecycle,
    "broker": sem_broker,
    "guest-transport": sem_guest_transport,
    "image-catalog": sem_image_catalog,
    "cache-qualification": sem_cache_qualification,
    "settings-v3": sem_settings_v3,
    "status-v5": sem_status_v5,
    "tray-windows-choice": None,
    "evidence-bundle": sem_evidence_bundle,
    "cleanup-receipt": sem_cleanup_receipt,
    "host-network-module": sem_host_network_module,
}


def validate(name, schema, instance):
    check(schema, instance, schema)
    _no_secret_values(instance)
    rule = SEMANTIC[name]
    if rule:
        try:
            rule(instance)
        except (KeyError, TypeError) as e:
            raise Invalid(f"semantic rule could not read {e}")


def load(path):
    with open(path, "rb") as f:
        raw = f.read(262145)  # one byte past the bound, never the whole file
    if len(raw) > 262144:
        raise Invalid(f"{path.name}: document over 256 KiB")
    return json.loads(raw.decode("utf-8-sig"))


def check_files(name, paths):
    """`validate.py <contract> <file>...`: validate real documents (e.g. evidence receipts)."""
    if name not in SEMANTIC:
        print(f"unknown contract {name}; one of {sorted(SEMANTIC)}")
        return 2
    schema = load(HERE / f"{name}.schema.json")
    bad = 0
    for p in paths:
        try:
            validate(name, schema, load(Path(p)))
            print(f"ok    {p}")
        except (Invalid, ValueError, OSError) as e:
            bad += 1
            print(f"FAIL  {p}: {e}")
    return 1 if bad else 0


def main():
    if len(sys.argv) > 1:
        return check_files(sys.argv[1], sys.argv[2:])
    failures = []
    totals = {"schemas": 0, "valid": 0, "invalid": 0}
    schemas = sorted(HERE.glob("*.schema.json"))
    names = {p.name[: -len(".schema.json")] for p in schemas}
    if names != set(SEMANTIC):
        failures.append(f"schema set {sorted(names)} differs from SEMANTIC {sorted(SEMANTIC)}")
    for bad, good in ((r"^a\\$", r"^a\$$"), (r"^[a$]+$", r"^[a\]]+$"), (r"^a|b$", r"^(a|b)$"),
                      (r"a$", r"^[|]a$"), (r"^a\$", r"^(a)$")):
        if not lint_schema({"pattern": bad}) or lint_schema({"pattern": good}):
            failures.append(f"lint_schema self-check failed on {bad!r} / {good!r}")
    for spath in schemas:
        name = spath.name[: -len(".schema.json")]
        if name not in SEMANTIC:
            continue
        totals["schemas"] += 1
        schema = load(spath)
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            failures.append(f"{name}: $schema must be draft 2020-12")
        if not isinstance(schema.get("x-contract-version"), int) or not schema.get("x-owner"):
            failures.append(f"{name}: needs integer x-contract-version and x-owner")
        failures += [f"{name}: {p}" for p in lint_schema(schema)]
        valid = sorted((HERE / "fixtures" / name / "valid").glob("*.json"))
        invalid = sorted((HERE / "fixtures" / name / "invalid").glob("*.json"))
        if len(valid) < 1 or len(invalid) < 3:
            failures.append(f"{name}: needs >=1 valid and >=3 invalid fixtures (has {len(valid)}/{len(invalid)})")
        for f in valid:
            totals["valid"] += 1
            try:
                validate(name, schema, load(f))
                print(f"ok    {name}/valid/{f.name}")
            except Invalid as e:
                failures.append(f"{name}/valid/{f.name} rejected: {e}")
        for f in invalid:
            totals["invalid"] += 1
            case = load(f)
            if set(case) != {"expect", "instance"} or not case["expect"]:
                failures.append(f"{name}/invalid/{f.name}: must be {{expect, instance}}")
                continue
            try:
                validate(name, schema, case["instance"])
                failures.append(f"{name}/invalid/{f.name} was ACCEPTED")
            except Invalid as e:
                if case["expect"] not in str(e):
                    failures.append(f"{name}/invalid/{f.name} rejected for the wrong reason: {e}")
                else:
                    print(f"ok    {name}/invalid/{f.name} -> {e}")
    print(f"\n{totals['schemas']} schemas, {totals['valid']} valid and {totals['invalid']} invalid fixtures")
    for f in failures:
        print(f"FAIL  {f}")
    print("PASS" if not failures else f"{len(failures)} FAILURE(S)")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
