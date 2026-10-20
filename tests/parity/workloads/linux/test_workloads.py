"""P18 workload definitions, oracle citations, tree manifest and the xwin hand-off rule.

usage: python -B -I tests/parity/workloads/linux/test_workloads.py   (stdlib unittest; no toolchain needed)
"""
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[4]
LINUX = REPO / "parity/workloads/linux"
BASE = REPO / "parity/baselines/ubuntu-24.04-x64"
sys.path.insert(0, str(LINUX))
sys.path.insert(0, str(REPO / "parity/workloads/xwin"))
import handoff  # noqa: E402
import tree_manifest  # noqa: E402

ORACLE = json.loads((LINUX / "oracle/ubuntu-24.04.json").read_text(encoding="utf-8"))
DEF_DIRS = [LINUX / "defs", REPO / "parity/workloads/actions/linux/defs", REPO / "parity/workloads/xwin/defs"]
DEFS = {d["id"]: d for p in DEF_DIRS for d in (json.loads(f.read_text(encoding="utf-8")) for f in sorted(p.glob("*.json")))}
DERIVED = {"unqualified/xwin/sdk-cross", "unqualified/xwin/sdk-cross.neg-no-sysroot", "docker_socket"} | {
    f"shell_semantics/{k}" for k in ("bash.ok", "bash.errexit", "bash.pipefail", "bash.exit", "default.errexit",
                                     "default.pipefail", "sh.errexit", "sh.pipefail", "sh.exit", "python.exit")}


def leaves(o, path=""):
    for k, v in o.items():
        if isinstance(v, dict) and "src" in v:
            yield path + k, v["v"], v["src"]
        elif isinstance(v, dict):
            yield from leaves(v, path + k + "/")


def capture_lines():
    # each line is 'capture<TAB>step<TAB><timestamp> <text>'; keep the text
    out = []
    for ln in (BASE / "sources/hosted-capture-39305649952.log").read_text(encoding="utf-8-sig").splitlines():
        text = ln.split("\t", 2)[-1]
        out.append(re.sub(r"^﻿?\d{4}-\d\d-\d\dT[\d:.]+Z ?", "", text))
    return out


class Oracle(unittest.TestCase):
    inv = json.loads((BASE / "inventory.json").read_text(encoding="utf-8"))
    log = capture_lines()
    readme = (BASE / "README.md").read_text(encoding="utf-8")
    items = list(leaves({k: v for k, v in ORACLE.items() if k not in ("schema", "profile", "note", "hosted_validation")}))

    def texts(self, cat, name):
        out = []
        for e in self.inv["categories"].get(cat, []):
            if name in (None, e["name"]):
                out += [e["name"]] + e.get("versions", []) + list(e.get("attrs", {}).values())
        return out

    def test_every_value_cites_a_known_source(self):
        self.assertGreater(len(self.items), 150)
        for key, _, src in self.items:
            self.assertRegex(src, r"^(inventory|capture|capture-list|hosted|readme|docs|derived|provisional):", key)

    def test_inventory_citations(self):
        for key, v, src in self.items:
            if not src.startswith("inventory:"):
                continue
            cat, name = src[10:].split("|")
            if cat == "identity":
                self.assertEqual(self.inv["identity"][name]["value"], v, key)
                continue
            texts = self.texts(cat, name)
            self.assertTrue(texts, src)
            for x in v if isinstance(v, list) else [v]:
                self.assertIn(x, texts, f"{key}={x} must appear under {src}")

    def test_capture_citations(self):
        body = "\n".join(self.log)
        for key, v, src in self.items:
            if src.startswith("capture:"):
                text = src[8:]
                self.assertIn(text, body, key)
                self.assertNotRegex(text, r"\x1b|\$\{?[A-Za-z_]", f"{key} must cite an output line, not the script")
                if v is None:
                    self.assertTrue(text.endswith("=<unset>"), key)
                else:
                    self.assertIn(str(v), text, key)
            elif src.startswith("capture-list:"):
                for x in v:
                    hit = [ln for ln in self.log if ln == x or ln.startswith(x + " ") or ln.endswith((" " + x, "\t" + x))]
                    self.assertTrue(hit, f"{key}: {x} is not a line of the capture")
        order = [ln.split("\t", 1) for ln in self.log[self.log.index("--- process PATH") + 1:][:len(ORACLE["path_order"]["v"])]]
        self.assertEqual([p for _, p in order], ORACLE["path_order"]["v"])
        self.assertEqual([int(n) for n, _ in order], list(range(len(order))))

    def test_readme_and_hosted_citations(self):
        for key, v, src in self.items:
            if src.startswith("readme:"):
                self.assertIn(src[7:], self.readme, key)
                for x in v if isinstance(v, list) else [v]:
                    self.assertIn(str(x), src, key)
            elif src.startswith("hosted:"):
                m = re.match(r"^hosted:(\d+)/([A-Za-z0-9._-]+):(.+)$", src)
                self.assertTrue(m, src)
                f = LINUX / "oracle/hosted-runs" / m[1] / m[2]
                self.assertTrue(f.is_file(), src)
                self.assertIn(m[3], f.read_text(encoding="utf-8"), src)
                for x in v if isinstance(v, list) else [v]:
                    self.assertIn(str(x), m[3], key)

    def test_cited_evidence_is_tracked(self):
        cited = sorted({f"parity/workloads/linux/oracle/hosted-runs/{m[1]}/{m[2]}" for _, _, s in self.items
                        for m in [re.match(r"^hosted:(\d+)/([A-Za-z0-9._-]+):", s)] if m})
        run = ORACLE.get("hosted_validation", {}).get("run")
        if run:
            cited += [f"parity/workloads/linux/oracle/hosted-runs/{run}/{f}" for f in ("summary.json", "results.json")]
        self.assertTrue(cited)
        r = subprocess.run(["git", "-C", str(REPO), "ls-files", "--error-unmatch", *cited], capture_output=True, text=True)
        if r.returncode != 0 and "not a git repository" in r.stderr:
            self.skipTest("not a git checkout")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_derived_and_provisional_values(self):
        self.assertEqual({k for k, _, s in self.items if s.startswith("derived:")}, DERIVED)
        if "hosted_validation" in ORACLE:
            self.assertEqual([k for k, _, s in self.items if s.startswith("provisional:")], [])

    def test_xwin_sdk_is_unqualified_because_the_inventory_has_no_sdk(self):
        names = " ".join(e.get("raw", "") for c in self.inv["categories"].values() for e in c).lower()
        for word in ("xwin", "windows sdk", "msvc"):
            self.assertNotIn(word, names)
        self.assertEqual(set(ORACLE["unqualified"]), {"xwin/sdk-cross", "xwin/sdk-cross.neg-no-sysroot"})
        self.assertTrue(set(ORACLE["unqualified"]) <= set(DEFS))


class Definitions(unittest.TestCase):
    def test_shape(self):
        self.assertEqual(len(DEFS), 46)
        for wid, d in DEFS.items():
            self.assertLessEqual(d["timeout_s"], 300, wid)
            cmd = d["commands"][0]
            self.assertEqual(cmd[0], "bash", wid)
            script = REPO / cmd[1].replace("{fixtures}/../../../../", "")
            self.assertTrue(script.is_file(), wid)
            self.assertEqual(cmd[cmd.index("--id") + 1], wid)
            self.assertEqual(d["claim_success_regex"], r"^workload \S+: all oracle checks met$")
            if ".neg-" in wid:
                base, name = wid.split(".neg-")
                self.assertIn(base, DEFS, f"{wid} has no positive twin")
                self.assertEqual(d["expected_exit_codes"], [1])
                self.assertEqual(cmd[cmd.index("--sabotage") + 1], name)
                self.assertTrue(d["expected_first_error"]["contains"].strip(), wid)
                self.assertNotIn("artifact_globs", d, wid)
                self.assertIn(name, script.read_text(encoding="utf-8"), f"{wid}: {script} does not handle sabotage {name}")
            else:
                self.assertEqual(d["expected_exit_codes"], [0])
                self.assertNotIn("--sabotage", cmd, wid)

    def test_negative_runs_its_twin_command(self):
        def without(c, *flags):
            return [x for i, x in enumerate(c) if x not in flags and (i == 0 or c[i - 1] not in flags)]
        for wid, d in DEFS.items():
            if ".neg-" in wid:
                twin = DEFS[wid.split(".neg-")[0]]["commands"][0]
                self.assertEqual(without(d["commands"][0], "--id", "--sabotage"), without(twin, "--id"), wid)


class TreeManifest(unittest.TestCase):
    def test_paths(self):
        m = tree_manifest.manifest(REPO)
        files = set(m["files"])
        self.assertIn("parity/workloads/linux/lib.sh", files)
        self.assertIn("parity/workloads/actions/linux/file-commands/action.yml", files)
        self.assertIn("parity/workloads/xwin/handoff.py", files)
        self.assertIn("tools/parity-certify/certify.py", files)
        self.assertFalse([f for f in files if f.endswith("README.md") or "/hosted-runs/" in f or "__pycache__" in f])
        self.assertEqual(m, tree_manifest.manifest(REPO))

    def test_hosted_validation_key_does_not_change_the_oracle_hash(self):
        p = LINUX / "oracle/ubuntu-24.04.json"
        rel = "parity/workloads/linux/oracle/ubuntu-24.04.json"
        with tempfile.TemporaryDirectory() as t:
            q = pathlib.Path(t) / "o.json"
            q.write_text(json.dumps({**json.loads(p.read_text(encoding="utf-8")), "hosted_validation": {"run": "1"}}), encoding="utf-8")
            self.assertEqual(tree_manifest.file_sha256(q, rel), tree_manifest.file_sha256(p, rel))


class Handoff(unittest.TestCase):
    sha = "e713b3b44aa4d73ce5586feb6755f2f9f4ed6310f12740702ebb03106e41b6c7"
    built = {"kind": "xwin-built", "artifact": "a.exe", "sha256": sha, "expected_exit": 42, "expected_stdout": "hi",
             "windows_execution": "not-claimed"}
    ran = {"kind": "xwin-executed", "artifact": "a.exe", "runner_os": "Windows", "sha256": sha, "exit_code": 42,
           "stdout": "hi\r\n"}

    def test_only_a_matching_windows_run_is_execution_evidence(self):
        self.assertEqual(handoff.verdict(self.built, self.ran), "executed-on-windows")
        # output is compared after CRLF -> LF and stripping surrounding whitespace
        self.assertEqual(handoff.verdict(self.built, {**self.ran, "stdout": "  hi\n\n"}), "executed-on-windows")
        self.assertTrue(handoff.verdict(self.built, None).startswith("built-only: "))
        for change, why in (({"runner_os": "Linux"}, "not from Windows"), ({"sha256": "cd"}, "differs"),
                            ({"artifact": "b.exe"}, "is not the built one"), ({"exit_code": 1}, "exit code"),
                            ({"exit_code": 42.0}, "exit code"), ({"exit_code": True}, "exit code"),
                            ({"stdout": "other"}, "output"), ({"stdout": None}, "output")):
            self.assertIn(why, handoff.verdict(self.built, {**self.ran, **change}), change)
        self.assertIn("not a plain", handoff.verdict({**self.built, "windows_execution": "claimed"}, self.ran))

    def test_verdict_fails_closed_on_missing_or_malformed_fields(self):
        no_sha_b = {k: v for k, v in self.built.items() if k != "sha256"}
        no_sha_e = {k: v for k, v in self.ran.items() if k != "sha256"}
        self.assertIn("no sha256", handoff.verdict(no_sha_b, no_sha_e))
        self.assertIn("no sha256", handoff.verdict({**self.built, "sha256": "x" * 64}, {**self.ran, "sha256": "x" * 64}))
        self.assertIn("names no artifact", handoff.verdict({**self.built, "artifact": ""}, {**self.ran, "artifact": ""}))
        self.assertIn("malformed", handoff.verdict({**self.built, "expected_exit": True}, {**self.ran, "exit_code": True}))
        self.assertIn("exit code True", handoff.verdict({**self.built, "expected_exit": 1}, {**self.ran, "exit_code": True}))
        self.assertIn("malformed", handoff.verdict({**self.built, "expected_stdout": None}, {**self.ran, "stdout": None}))
        self.assertTrue(handoff.verdict({}, {}).startswith("built-only: "))

    def test_built_record_never_claims_execution(self):
        with tempfile.TemporaryDirectory() as t:
            exe = pathlib.Path(t) / "a.exe"
            exe.write_bytes(b"MZ")
            out = pathlib.Path(t) / "a.handoff.json"
            self.assertEqual(handoff.main(["built", str(exe), "42", "hi", str(out)]), 0)
            rec = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(rec["windows_execution"], "not-claimed")
            self.assertEqual(handoff.main(["verdict", str(out)]), 1)


class HostedRun(unittest.TestCase):
    @unittest.skipUnless("hosted_validation" in ORACLE, "no hosted run recorded yet")
    def test_tree_matches_the_recorded_hosted_run(self):
        r = subprocess.run([sys.executable, "-B", "-I", str(pathlib.Path(__file__).with_name("check_hosted_run.py")), str(REPO)],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
