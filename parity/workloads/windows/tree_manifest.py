"""Content manifest of everything that decides a P17 workload result, so hosted evidence pins more than definitions.

usage: python -B -I tree_manifest.py <repo>   prints {"sha256": <tree sha256>, "files": {<path>: <sha256>}}

Files: parity/workloads/windows/** and parity/workloads/actions/windows/** (without oracle/hosted-runs/** and README.md)
plus tools/parity-certify/certify.py. A file's sha256 is of its bytes with CRLF as LF; an oracle JSON is hashed as
canonical JSON without its hosted_validation key (that key names the evidence, it does not change a result). The tree
sha256 is of the text '<sha256>  <path>\n' per file, sorted by path.
"""
import hashlib
import json
import pathlib
import sys

ROOTS = ("parity/workloads/windows", "parity/workloads/actions/windows")
EXTRA = ("tools/parity-certify/certify.py",)
ORACLE_DIR = "parity/workloads/windows/oracle/"
EVIDENCE_DIR = ORACLE_DIR + "hosted-runs/"


def file_sha256(path, rel):
    data = path.read_bytes()
    if rel.startswith(ORACLE_DIR) and rel.endswith(".json"):
        obj = json.loads(data.decode("utf-8"))
        obj.pop("hosted_validation", None)
        data = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(data.replace(b"\r\n", b"\n")).hexdigest()


def manifest(repo):
    repo = pathlib.Path(repo)
    rels = [p.relative_to(repo).as_posix() for root in ROOTS for p in (repo / root).rglob("*") if p.is_file()]
    rels = [r for r in rels if not r.startswith(EVIDENCE_DIR) and r.rsplit("/", 1)[-1] != "README.md"] + list(EXTRA)
    files = {r: file_sha256(repo / r, r) for r in sorted(rels)}
    text = "".join(f"{sha}  {rel}\n" for rel, sha in files.items())
    return {"sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(), "files": files}


if __name__ == "__main__":
    print(json.dumps(manifest(sys.argv[1]), indent=1))
