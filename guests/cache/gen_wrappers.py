"""Generate guests/cache/wrappers.json from the P04 qualification matrices. Standard library only.

    python -B -I guests/cache/gen_wrappers.py           # rewrite wrappers.json
    python -B -I guests/cache/gen_wrappers.py --check   # exit 1 when wrappers.json is stale

wrappers.json is the one qualified-wrapper manifest both guest installers read. It lists, per
platform, the pinned archive and its two members, the P03 acquisition entry that must deliver the
archive, and ONLY the matrix rows whose mode is `qualified`. Every other compiler and invocation
builds directly (contract rule 3). Each matrix must first pass
`parity/contracts/validate.py cache-qualification`; that validator also rejects sccache (rule 2).
"""

import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "guests" / "cache" / "wrappers.json"
VALIDATE = REPO / "parity" / "contracts" / "validate.py"
ACQUIRE = REPO / "images" / "common" / "artifacts.manifest.json"
VERSION = "1.15.6"
COMMIT = "15ec9537af0d219e07b72ce2b3f97d5f68d72b5e"

# Archive members, from parity/cache/qualification/artifacts.md ("Archive members"). The zccache
# member must equal the matrix binary_sha256, so the two sources cannot drift apart silently.
PLATFORMS = {
    "linux-x86_64": {
        "acquisition_entry": "zccache-x86_64-unknown-linux-musl",
        "archive_bytes": 12389072,
        "members": [
            {"name": "zccache", "path": "zccache-v1.15.6-x86_64-unknown-linux-musl/zccache", "bytes": 27876808,
             "sha256": "f97ae874042ab5c80fc2e35342e406972437f1fd45ec81372be33c0f5cbb18cc"},
            {"name": "zccache-fp", "path": "zccache-v1.15.6-x86_64-unknown-linux-musl/zccache-fp", "bytes": 4881816,
             "sha256": "df637b927954093a6fd5c7cc34afc3dd9470a855ec3e03e0342ee9ea9e49f058"},
        ],
    },
    "windows-x86_64": {
        "acquisition_entry": "zccache-x86_64-pc-windows-msvc",
        "archive_bytes": 10545387,
        "members": [
            {"name": "zccache.exe", "path": "zccache-v1.15.6-x86_64-pc-windows-msvc/zccache.exe", "bytes": 24359040,
             "sha256": "41de068f3024a1bcbfea8ad488455c648ee07903e09e9fca4d663436789d0731"},
            {"name": "zccache-fp.exe", "path": "zccache-v1.15.6-x86_64-pc-windows-msvc/zccache-fp.exe", "bytes": 3931776,
             "sha256": "4c0892e47244fdc38a6542ed3b05d2d9f26d312bce505984e6a9f6766c66c987"},
        ],
    },
}


class Refused(Exception):
    pass


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def build(qual_dir=REPO / "parity" / "cache" / "qualification", acquire=ACQUIRE, validate=VALIDATE, repo=REPO):
    entries = {e["name"]: e for e in load(acquire)["entries"]}
    out = {"schema": 1, "generator": "guests/cache/gen_wrappers.py",
           "zccache": {"version": VERSION, "commit": COMMIT}, "platforms": {}}
    for platform, pins in PLATFORMS.items():
        path = Path(qual_dir) / (platform + ".json")
        r = subprocess.run([sys.executable, "-B", "-I", str(validate), "cache-qualification", str(path)],
                           capture_output=True, text=True)
        if r.returncode != 0:  # SAFETY:GEN-VALIDATE
            raise Refused(f"{path.name} fails validate.py: {(r.stdout + r.stderr).strip()[:400]}")
        m = load(path)
        z = m["zccache"]
        if m["platform"] != platform or z["version"] != VERSION or z["commit"] != COMMIT:
            raise Refused(f"{path.name}: platform, version or commit is not the {VERSION} pin")
        if z["binary_sha256"] != pins["members"][0]["sha256"]:  # SAFETY:GEN-BINARY-PIN
            raise Refused(f"{path.name}: binary_sha256 differs from the pinned {pins['members'][0]['name']} member")
        acq = entries.get(pins["acquisition_entry"])
        if (acq is None or acq["file_name"] != z["archive"] or acq["hash"]["value"] != z["archive_sha256"]
                or acq["version"] != VERSION or acq["size_bytes"] != pins["archive_bytes"]):  # SAFETY:GEN-ACQUIRE
            raise Refused(f"{path.name}: P03 entry {pins['acquisition_entry']} does not pin the same archive")
        qualified = []
        for row in m["rows"]:
            if row["mode"] != "qualified":
                continue
            ref = row.get("evidence_ref")
            if not ref or not (Path(repo) / ref).is_file():  # SAFETY:GEN-EVIDENCE
                raise Refused(f"{path.name}: qualified row {row['compiler']} {row['invocation']} has no committed evidence")
            qualified.append({k: row[k] for k in ("compiler", "compiler_version", "invocation", "evidence_ref")})
        qualified.sort(key=lambda q: (q["compiler"], q["compiler_version"], q["invocation"]))
        out["platforms"][platform] = {
            "matrix": f"parity/cache/qualification/{platform}.json",
            "matrix_revision": m["matrix_revision"],
            "acquisition_entry": pins["acquisition_entry"],
            "archive": z["archive"],
            "archive_sha256": z["archive_sha256"],
            "archive_bytes": pins["archive_bytes"],
            "members": pins["members"],
            "qualified": qualified,
        }
    return out


def render(doc):
    return json.dumps(doc, indent=2) + "\n"


def main(argv):
    try:
        doc = build()
    except Refused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 1
    if argv[1:] == ["--check"]:
        current = load(OUT) if OUT.is_file() else None
        if current != doc:
            print("wrappers.json is stale; run python -B -I guests/cache/gen_wrappers.py", file=sys.stderr)
            return 1
        return 0
    if argv[1:]:
        print(__doc__, file=sys.stderr)
        return 2
    OUT.write_text(render(doc), encoding="utf-8", newline="\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
