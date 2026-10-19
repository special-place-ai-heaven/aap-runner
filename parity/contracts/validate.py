"""Validate the P02 shared-contract fixtures. Standard library only; run with `python -I`.

    python -I parity/contracts/validate.py                      # every fixture
    python -I parity/contracts/validate.py <contract> <file>...  # real documents

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
Exit 0 when everything holds, 1 otherwise.
"""
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
        if "pattern" in schema and not re.search(schema["pattern"], value):
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
    pool = (doc_host["cpu_cores"] * (100 - reserve) // 100, doc_host["mem_gib"] * (100 - reserve) // 100)
    total = sum(p["count"] for p in profiles.values())
    caps = {}
    for name, p in profiles.items():
        n = p["count"]
        if mode == "even":
            each = (pool[0] // total, pool[1] // total) if total else (0, 0)
            caps[name] = {"each": each, "cap": (each[0] * n, each[1] * n)}
        else:
            cap = (doc_host["cpu_cores"] * p["share_percent"] // 100, doc_host["mem_gib"] * p["share_percent"] // 100)
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
        mine = [r for r in live if r["profile"] == name]
        admitted = [r for r in mine if r["state"] not in ("draining", "deleting", "quarantined", "collecting")]
        if len(admitted) > profiles[name]["count"]:
            raise Invalid(f"{name}: more admitted reservations than the profile count")
        each = caps[name]["each"]
        for r in mine:
            if r["cpus"] > each[0] or r["mem_gib"] > each[1]:
                raise Invalid(f"{r['reservation_id']}: exceeds the per-runner share of {name}")
        if sum(r["cpus"] for r in mine) > caps[name]["cap"][0] or sum(r["mem_gib"] for r in mine) > caps[name]["cap"][1]:
            raise Invalid(f"{name}: reservations exceed the profile cap")
    if sum(r["cpus"] for r in live) > pool[0] or sum(r["mem_gib"] for r in live) > pool[1]:
        raise Invalid("reservations exceed the pool; the host reserve is never given away")
    for r in doc["reservations"]:
        if r["backend"] == "wsl-legacy":
            if r["profile"] != "linux" or r["vm_id"] is not None or not r["image_generation"].startswith("legacy-"):
                raise Invalid(f"{r['reservation_id']}: legacy reservations are linux, vm_id null, generation legacy-*")
        elif r["state"] not in ("creating", "reconciled") and r["vm_id"] is None:
            raise Invalid(f"{r['reservation_id']}: a VM reservation past creating names its vm_id")
        if (r["state"] == "quarantined") != (r["quarantine_reason"] is not None):
            raise Invalid(f"{r['reservation_id']}: quarantine_reason is set exactly when quarantined")
        if r["state"] == "reconciled" and r["teardown_proof"] is None:
            raise Invalid(f"{r['reservation_id']}: reconciled without teardown_proof")
        if r["idempotency_key"] != f"{r['reservation_id']}/{r['lease_generation']}":
            raise Invalid(f"{r['reservation_id']}: idempotency_key must be <reservation_id>/<lease_generation>")


def sem_backend_lifecycle(doc):
    if doc["kind"] == "budget":
        return
    if doc["idempotency_key"] != f"{doc['reservation_id']}/{doc['lease_generation']}/{doc['op']}":
        raise Invalid("idempotency_key must be <reservation_id>/<lease_generation>/<op>")
    if (doc["phase"] == "intent") != (doc["result"] is None):
        raise Invalid("an intent record has no result; done/failed records have one")
    if doc["phase"] == "done" and doc["result"]["code"] not in ("ok", "absent"):
        raise Invalid("phase done requires result ok or absent")
    if doc["backend"] == "hyperv-vm" and doc["op"] != "create" and doc["vm"]["vm_id"] is None:
        raise Invalid("every op after create names the vm_id")


def sem_broker(doc):
    kind = doc["kind"]
    if kind in ("lease_request", "release_request"):
        if len(json.dumps(doc, separators=(",", ":")).encode()) > 4096:
            raise Invalid("request larger than 4096 bytes")
    if kind == "lease_response":
        issued = doc["result"] == "issued"
        fields = (doc["jit_config"], doc["runner_id"], doc["runner_name"], doc["expires_at"])
        if issued and (doc["reason"] != "ok" or any(f is None for f in fields)):
            raise Invalid("an issued lease carries reason ok, jit_config, runner_id, runner_name and expires_at")
        if not issued and (doc["reason"] == "ok" or any(f is not None for f in fields)):
            raise Invalid("a refused lease carries a refusal reason and no registration material")
    if kind == "audit":
        _no_secret_keys(doc)


def sem_guest_transport(doc):
    if doc["kind"] == "host_cmd":
        if (doc["cmd"] == "deliver_registration") != (doc["payload_bytes"] > 0):
            raise Invalid("payload_bytes > 0 exactly for deliver_registration")
    else:
        _no_secret_keys(doc)


def sem_image_catalog(doc):
    gens = {}
    for g in doc["generations"]:
        if g["generation_id"] in gens:
            raise Invalid(f"duplicate generation {g['generation_id']}")
        gens[g["generation_id"]] = g
        if not g["generation_id"].startswith(g["profile"] + "/"):
            raise Invalid(f"{g['generation_id']}: id must start with its profile")
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
    for row in doc["rows"]:
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


def sem_evidence_bundle(doc):
    _no_secret_keys(doc)
    o = doc["oracle"]
    if doc["result"] == "pass" and o["observed"] != o["expected"]:
        raise Invalid("result pass requires observed == expected")
    if doc["result"] == "fail" and o["observed"] == o["expected"]:
        raise Invalid("result fail with a matching oracle")
    if doc["result"] in ("skipped", "blocked", "timeout", "unknown") and o["observed"] != doc["result"]:
        raise Invalid("skipped, blocked, timeout and unknown are reported as observed, never as pass")


def sem_cleanup_receipt(doc):
    _no_secret_keys(doc)
    actor = doc["implementer"] if "schema" in doc else doc["cleanup_actor"]
    if doc["verifier"] == actor:
        raise Invalid("verifier must be independent of the implementer")
    for d in doc["disposed"]:
        if d["observed_absent"] is not True:
            raise Invalid(f"disposed {d.get('id', d.get('resource'))}: absence not observed")


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
}


def validate(name, schema, instance):
    check(schema, instance, schema)
    rule = SEMANTIC[name]
    if rule:
        try:
            rule(instance)
        except (KeyError, TypeError) as e:
            raise Invalid(f"semantic rule could not read {e}")


def load(path):
    with open(path, "rb") as f:
        raw = f.read()
    if len(raw) > 65536:
        raise Invalid(f"{path.name}: fixture over 64 KiB")
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
        except (Invalid, ValueError) as e:
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
