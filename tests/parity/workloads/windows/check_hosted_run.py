"""Checks that the P17 workloads are the ones a stored hosted run validated.

usage: python -B -I check_hosted_run.py <repo>
The run is the oracle's hosted_validation.run; its summary.json and results.json are under oracle/hosted-runs/<run>/.
Compares every definition (hash, report hashes, first error) and the content manifest of the workloads, oracle and
harness (parity/workloads/windows/tree_manifest.py) with what that run recorded.
"""
import json
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(repo / "tools" / "parity-certify"))
sys.path.insert(0, str(repo / "parity" / "workloads" / "windows"))
import certify  # noqa: E402
import tree_manifest  # noqa: E402

win = repo / "parity" / "workloads" / "windows"
run = json.loads((win / "oracle" / "windows-2025-vs2026.json").read_text(encoding="utf-8"))["hosted_validation"]["run"]
summary = json.loads((win / "oracle" / "hosted-runs" / run / "summary.json").read_text(encoding="utf-8"))
results = {r["id"]: r for r in json.loads((win / "oracle" / "hosted-runs" / run / "results.json").read_text(encoding="utf-8"))["results"]}
defs = certify.load_defs(str(win / "defs")) + certify.load_defs(str(repo / "parity" / "workloads" / "actions" / "windows" / "defs"))
bad = []
if summary["source"]["GITHUB_RUN_ID"] != run or summary["pass"] != summary["total"] or summary["total"] != len(defs):
    bad.append(f"summary.json: run {summary['source']['GITHUB_RUN_ID']} pass {summary['pass']}/{summary['total']}, {len(defs)} definitions")
tree = summary.get("tree")
if not tree:
    bad.append(f"summary.json of run {run} records no tree manifest")
else:
    now = tree_manifest.manifest(repo)["files"]
    for path in sorted(set(now) | set(tree["files"])):
        if path not in tree["files"]:
            bad.append(f"added since run {run}: {path}")
        elif path not in now:
            bad.append(f"removed since run {run}: {path}")
        elif now[path] != tree["files"][path]:
            bad.append(f"changed since run {run}: {path}")
if {d["id"] for d in defs} != set(results):
    bad.append(f"definition ids differ from the run: {sorted({d['id'] for d in defs} ^ set(results))}")
for d in defs:
    r = results.get(d["id"])
    if r is None:
        continue
    if r["status"] != "pass" or r["exit_code"] not in d["expected_exit_codes"]:
        bad.append(f"{d['id']}: {r['status']} exit {r['exit_code']}")
    if r["def_sha256"] != certify.def_sha256(d):
        bad.append(f"{d['id']}: definition changed since run {run}")
    if {a["name"]: a["sha256"] for a in r["artifacts"]} != d.get("expected_hashes", {}):
        bad.append(f"{d['id']}: expected_hashes differ from the run's artifacts")
    want = d.get("expected_first_error", {}).get("contains")
    if want and want not in ((r["first_error"] or {}).get("message") or ""):
        bad.append(f"{d['id']}: first error {r['first_error']!r} lacks {want!r}")
print("\n".join(bad) or f"{len(defs)} definitions match hosted run {run}")
sys.exit(1 if bad else 0)
