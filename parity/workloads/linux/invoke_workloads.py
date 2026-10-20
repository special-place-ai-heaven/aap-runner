"""Runs the P18 Linux, Actions and xwin parity workloads through tools/parity-certify; one JSON result per workload.

usage: invoke-workloads.sh [--name ID|PREFIX[,...]]... [--out DIR] [--profile ubuntu-24.04] [--list] [--keep-work]

Definitions: parity/workloads/{linux,actions/linux,xwin}/defs (P05 workload format). The selected definitions are
copied to <out>/defs and run by `certify.py run-workloads`, which writes <out>/results.json and <out>/logs (the
reference results a later `certify.py certify --reference-results` reads). This script then writes
<out>/workloads/<id>.json (definition oracle, observed facts, exit code, artifacts with hashes, duration, image
identity), keeps the hashed artifacts under <out>/artifacts/<id>/ and writes <out>/summary.json with the content
manifest of the workloads, oracle and harness (tree_manifest.py). Exit code 0 only when every selected workload passed.

--name takes ids or prefixes (linux/gcc selects linux/gcc and its negative controls), as several values or one
comma-separated string. Without --name every definition runs except those the profile oracle lists as unqualified
(their reason is recorded in summary.json); naming one runs it anyway, so it fails honestly. --out defaults to
$PARITY_OUT, then $RUNNER_TEMP/parity-out, and must be new or empty.
"""
import argparse
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]
DEF_DIRS = [HERE / "defs", REPO / "parity/workloads/actions/linux/defs", REPO / "parity/workloads/xwin/defs"]


def safe(wid):
    return wid.replace("/", "__")


def dump(obj, path):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, indent=1)
        f.write("\n")


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def select(all_defs, names, unqualified):
    if not names:
        return [d for d in all_defs if d[0] not in unqualified]
    pats = [p.strip() for n in names for p in n.split(",") if p.strip()]
    for p in pats:
        if not any(wid.startswith(p) for wid, _, _ in all_defs):
            sys.exit(f"error: no workload matches '{p}' (use --list)")
    return [d for d in all_defs if any(d[0].startswith(p) for p in pats)]


def image_identity():
    img = {k: os.environ.get(k) for k in ("ImageOS", "ImageVersion", "RUNNER_ENVIRONMENT")}
    rel = {}
    if os.path.isfile("/etc/os-release"):
        for ln in open("/etc/os-release", encoding="utf-8"):
            k, _, v = ln.strip().partition("=")
            rel[k] = v.strip('"')
    img["os"] = f"{rel.get('PRETTY_NAME')} kernel {platform.release()}"
    data = "/imagegeneration/imagedata.json"
    img["imagedata"] = load(data) if os.path.isfile(data) else None
    return img


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--name", action="append", default=[])
    ap.add_argument("--out", default="")
    ap.add_argument("--profile", default="ubuntu-24.04")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--keep-work", action="store_true")
    a = ap.parse_args(argv)

    oracle_path = HERE / "oracle" / f"{a.profile}.json"
    if not oracle_path.is_file():
        sys.exit(f"error: no oracle for profile {a.profile}")
    unqualified = {k: v["v"] for k, v in load(oracle_path).get("unqualified", {}).items()}
    all_defs = []
    for d in DEF_DIRS:
        for f in sorted(d.glob("*.json")):
            wd = load(f)
            all_defs.append((wd["id"], f, wd))
    if a.list:
        for wid, _, _ in all_defs:
            print(wid + ("  (unqualified: " + unqualified[wid] + ")" if wid in unqualified else ""))
        return 0
    sel = select(all_defs, a.name, unqualified)
    if not sel:
        sys.exit("error: no workload selected (use --list)")

    out = a.out or os.environ.get("PARITY_OUT") or os.path.join(os.environ.get("RUNNER_TEMP") or "/tmp", "parity-out")
    out = pathlib.Path(out)
    if out.exists() and any(out.iterdir()):
        sys.exit(f"error: output folder {out} is not empty; give a new or empty --out")
    out.mkdir(parents=True, exist_ok=True)
    out = out.resolve()
    for sub in ("defs", "work", "observed", "workloads"):
        (out / sub).mkdir()
    for wid, f, _ in sel:
        shutil.copyfile(f, out / "defs" / (safe(wid) + ".json"))

    sys.path.insert(0, str(HERE))
    import tree_manifest  # noqa: E402  (beside this file)
    tree = tree_manifest.manifest(REPO)
    env = dict(os.environ, PARITY_PROFILE=a.profile, PARITY_OBS_DIR=str(out / "observed"))
    results = out / "results.json"
    print(f"running {len(sel)} workload(s) into {out}", flush=True)
    code = subprocess.call([sys.executable, "-B", "-I", str(REPO / "tools/parity-certify/certify.py"), "run-workloads",
                            "--defs", str(out / "defs"), "--out", str(results), "--work", str(out / "work")], env=env)
    if not results.is_file():
        print(f"certify.py run-workloads wrote no results (exit {code})")
        return 2

    image = image_identity()
    head = subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True, text=True)
    source = {"repo_head": head.stdout.strip() or None if head.returncode == 0 else None,
              "GITHUB_SHA": os.environ.get("GITHUB_SHA"), "GITHUB_RUN_ID": os.environ.get("GITHUB_RUN_ID"),
              "GITHUB_RUN_ATTEMPT": os.environ.get("GITHUB_RUN_ATTEMPT")}
    defs = {wid: wd for wid, _, wd in sel}
    rows = []
    for r in load(results)["results"]:
        wd = defs[r["id"]]
        obs_file = out / "observed" / (safe(r["id"]) + ".observed.json")
        obs = load(obs_file) if obs_file.is_file() else None
        oracle = {"expected_exit_codes": wd["expected_exit_codes"], "profile_oracle": f"parity/workloads/linux/oracle/{a.profile}.json"}
        oracle.update({k: wd[k] for k in ("expected_first_error", "artifact_globs", "expected_hashes") if k in wd})
        dump({"schema": 1, "kind": "p18-workload-result", "id": r["id"], "status": r["status"], "reasons": r["reasons"],
              "oracle": oracle, "observed": obs, "exit_code": r["exit_code"], "first_error": r["first_error"],
              "artifacts": r["artifacts"], "log": "logs/" + safe(r["id"]) + ".log", "log_sha256": r["log_sha256"],
              "def_sha256": r["def_sha256"], "started_at": r["started_at"], "ended_at": r["ended_at"],
              "duration_s": r["duration_s"], "image": image, "source": source},
             out / "workloads" / (safe(r["id"]) + ".json"))
        # keep the hashed artifacts (report.txt) next to the record; the build tree itself is not evidence
        if obs and r["artifacts"]:
            dst = out / "artifacts" / safe(r["id"])
            dst.mkdir(parents=True, exist_ok=True)
            for art in r["artifacts"]:
                shutil.copyfile(pathlib.Path(obs["work"]) / art["name"], dst / pathlib.Path(art["name"]).name)
        rows.append({"id": r["id"], "status": r["status"], "exit_code": r["exit_code"], "duration_s": r["duration_s"]})
    if not a.keep_work:
        shutil.rmtree(out / "work", ignore_errors=True)  # created by this run in an empty --out
    passed = sum(1 for x in rows if x["status"] == "pass")
    not_run = {wid: why for wid, why in unqualified.items() if wid not in defs and any(wid == d[0] for d in all_defs)}
    dump({"schema": 1, "kind": "p18-workload-summary", "profile": a.profile, "image": image, "source": source,
          "tree": tree, "pass": passed, "total": len(rows), "workloads": rows, "unqualified_not_run": not_run},
         out / "summary.json")
    for x in rows:
        print(f"{x['status']:<13} {x['exit_code']!s:>4} {x['duration_s']:>8} {x['id']}")
    for wid, why in not_run.items():
        print(f"{'not run':<13} {'':>4} {'':>8} {wid} (unqualified: {why})")
    print(f"{passed}/{len(rows)} workloads pass; results in {out}")
    return 0 if code == 0 and passed == len(rows) == len(sel) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
