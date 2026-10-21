"""P04 static qualification checks. Standard library only.

Run: python -I -B -m unittest discover -s tests/parity/cache/qualification -p "test_*.py"
"""

import copy
import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
QUAL = REPO / "parity" / "cache" / "qualification"
VALIDATE = REPO / "parity" / "contracts" / "validate.py"
PLATFORMS = ("linux-x86_64", "windows-x86_64")
PENDING = "unqualified - pending lab (P13/P22)"
MSVC = "partial per upstream matrix - direct-only until proven"
RUST_BIN = "direct per upstream binary-crate pass-through (README 400-403)"

# Contract template (parity/contracts/cache-qualification.md, "Matrix template").
CC = {"compile-object", "compile-pch", "response-file", "depfile", "path-with-spaces"}
GCC = {"compile-object", "compile-pch", "response-file", "depfile"}
# On Linux debug-pdb means -g DWARF output, for every compiler version (contract revision 2, P04.1).
TEMPLATE = {
    "linux-x86_64": {"rustc": {"rustc-wrapper", "link", "path-with-spaces"},
                     "clang": CC | {"debug-pdb"}, "clang++": CC | {"debug-pdb"},
                     "gcc": GCC | {"debug-pdb"}, "g++": GCC | {"debug-pdb"}},
    "windows-x86_64": {"rustc": {"rustc-wrapper", "link", "path-with-spaces", "debug-pdb"},
                       "clang": CC, "clang++": CC,
                       "clang-cl": {"compile-object", "response-file", "debug-pdb", "path-with-spaces"},
                       "cl": {"compile-object", "compile-pch", "response-file", "debug-pdb"},
                       "link": {"link"}, "lld-link": {"link"}},
}

LAB_GATES = {"concurrency", "daemon_restart", "unsupported_invocations"}
IDENTITY = ("compiler", "compiler_version", "invocation", "evidence_ref")
# The checks record.jq emits for every pair; test_expected_checks_match_record_jq ties the two.
BASE_CHECKS = {"ok_exit_zero", "ok_runs_produce_primary", "exit_codes_equal", "artifacts_equal",
               "cold_has_no_hits", "warm_has_hits", "errors_stay_errors", "poisoned_artifact_rejected",
               "poisoned_same_size_rejected", "poisoned_marker_rejected", "zccache_env_clean",
               "daemons_pinned", "no_crash_dumps", "tool_versions_recorded"}


def expected_checks(compiler, invocation):
    """record.jq's check names for one pair: cl and link skip the banner check, debug-pdb adds the
    relocated build."""
    checks = set(BASE_CHECKS)
    if compiler not in ("cl", "link"):
        checks.add("compiler_version_observed")
    if invocation == "debug-pdb":
        checks.add("relocated_matches_direct")
    return checks


def load(name):
    return json.loads((QUAL / f"{name}.json").read_text(encoding="utf-8"))


def validate(*paths):
    return subprocess.run([sys.executable, "-I", "-B", str(VALIDATE), "cache-qualification", *map(str, paths)],
                          capture_output=True, text=True)


def raw_versions(inventory, prefix):
    """Versions from a P01 inventory line such as 'Clang: 16.0.6, 17.0.6, 18.1.3'."""
    text = (REPO / "parity" / "baselines" / inventory / "inventory.json").read_text(encoding="utf-8")
    line = re.search(r'"raw": "' + re.escape(prefix) + r'([^"]*)"', text)
    return set(re.findall(r"\d+\.\d+\.\d+(?:\.\d+)?", line.group(1)))


def qualified_row_problems(doc, row, record):
    """Why a `qualified` matrix row is not backed by its harness record; empty means backed.

    The harness always writes mode "direct" (it covers method steps 1-6 only), so the record's row
    must match the matrix row on identity, not on mode or reason. Steps 7-9 are the lab gates.
    """
    problems = []
    if record.get("platform") != doc["platform"]:
        problems.append("platform")
    if any((record.get("row") or {}).get(k) != row[k] for k in IDENTITY):
        problems.append("row identity")
    if (record.get("tool_versions") or {}).get("zccache_sha256") != doc["zccache"]["binary_sha256"]:
        problems.append("zccache binary")
    if record.get("harness_pass") is not True:
        problems.append("harness_pass")
    checks = record.get("checks") or {}
    if set(checks) != expected_checks(row["compiler"], row["invocation"]) or not all(v is True for v in checks.values()):
        problems.append("checks")
    gates = record.get("lab_gates") or {}
    if set(gates) != LAB_GATES or not all(v is True for v in gates.values()):
        problems.append("lab gates 7-9")
    return problems


class MatrixTests(unittest.TestCase):
    def test_both_matrices_validate(self):
        r = validate(*(QUAL / f"{p}.json" for p in PLATFORMS))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_broken_fixture_fails_validation(self):
        r = validate(Path(__file__).parent / "fixtures" / "broken-matrix.json")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("qualified requires evidence_ref", r.stdout)

    def test_evidence_refs_are_unique_per_row(self):
        refs = []
        for p in PLATFORMS:
            for row in load(p)["rows"]:
                self.assertTrue(row["evidence_ref"].startswith(f"parity/cache/qualification/evidence/{p}/"), row)
                refs.append(row["evidence_ref"])
        self.assertEqual(len(refs), len(set(refs)), sorted(r for r in refs if refs.count(r) > 1))

    def test_every_row_is_direct_with_its_reason(self):
        for p in PLATFORMS:
            for row in load(p)["rows"]:
                self.assertEqual(row["mode"], "direct", row)
                if row["compiler"] in ("cl", "link"):
                    want = MSVC
                elif row["compiler"] == "rustc" and row["invocation"] in ("link", "debug-pdb"):
                    want = RUST_BIN
                else:
                    want = PENDING
                self.assertTrue(row["reason"].startswith(want), row)

    def test_template_covered_for_every_baseline_version(self):
        for p in PLATFORMS:
            rows = load(p)["rows"]
            versions = {}
            for row in rows:
                versions.setdefault(row["compiler"], set()).add(row["compiler_version"])
            have = {(r["compiler"], r["compiler_version"], r["invocation"]) for r in rows}
            want = {(c, v, i) for c, invs in TEMPLATE[p].items() for v in versions.get(c, {"MISSING"}) for i in invs}
            self.assertEqual(have, want, p)

    def test_versions_come_from_the_p01_baselines(self):
        linux = load("linux-x86_64")["rows"]
        windows = load("windows-x86_64")["rows"]

        def vers(rows, comp):
            return {r["compiler_version"] for r in rows if r["compiler"] == comp}

        ubuntu = "ubuntu-24.04-x64"
        self.assertEqual(vers(linux, "clang"), raw_versions(ubuntu, "Clang: "))
        self.assertEqual(vers(linux, "clang++"), raw_versions(ubuntu, "Clang: "))
        self.assertEqual(vers(linux, "gcc"), raw_versions(ubuntu, "GNU C++: "))
        self.assertEqual(vers(linux, "g++"), raw_versions(ubuntu, "GNU C++: "))
        self.assertEqual(vers(linux, "rustc"), raw_versions(ubuntu, "Rust "))
        win = "windows-2025-vs2026-x64"
        self.assertEqual(vers(windows, "rustc"), raw_versions(win, "Rust "))
        for comp in ("clang", "clang++", "clang-cl", "lld-link"):
            self.assertEqual(vers(windows, comp), raw_versions(win, "LLVM "), comp)
        vs = raw_versions(win, "| Visual Studio Enterprise 2026 | ")
        tools = raw_versions(win, "| Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ")
        for comp in ("cl", "link"):
            (v,) = vers(windows, comp)
            self.assertTrue(vs and all(x in v for x in vs | tools), (comp, v))

    def test_feature_matrix_citations_resolve_in_zccache_md(self):
        text = (REPO / "parity" / "baselines" / "zccache.md").read_text(encoding="utf-8")
        section = text.split("## Pinned compiler and tool statements", 1)[1].split("\n## ", 1)[0]
        lines = set()
        for row in section.splitlines():
            if row.startswith("|") and not row.startswith("|---") and "Line in Z7" not in row:
                last = row.strip().strip("|").split("|")[-1]
                for a, b in re.findall(r"(\d+)(?:-(\d+))?", last.split("README")[0]):
                    lines.update(range(int(a), int(b or a) + 1))
        cited = 0
        for p in PLATFORMS:
            for row in load(p)["rows"]:
                for n in re.findall(r"FEATURE-MATRIX L(\d+)", row["reason"]):
                    cited += 1
                    self.assertIn(int(n), lines, row)
        self.assertGreater(cited, 0)

    def test_qualified_rows_are_backed_by_their_records(self):
        for p in PLATFORMS:
            doc = load(p)
            for row in doc["rows"]:
                if row["mode"] == "qualified":
                    path = REPO / row["evidence_ref"]
                    self.assertTrue(path.is_file(), row)
                    record = json.loads(path.read_text(encoding="utf-8"))
                    self.assertEqual(qualified_row_problems(doc, row, record), [], row)

    def test_backing_check_rejects_weak_records(self):
        doc = load("windows-x86_64")
        row = dict(doc["rows"][0], mode="qualified", reason="harness and lab steps 7-9 pass")
        good = {
            "platform": "windows-x86_64",
            "tool_versions": {"zccache_sha256": doc["zccache"]["binary_sha256"]},
            "harness_pass": True,
            "checks": {c: True for c in expected_checks(row["compiler"], row["invocation"])},
            "lab_gates": {g: True for g in LAB_GATES},
            "row": {k: row[k] for k in IDENTITY} | {"mode": "direct", "reason": "harness checks pass; lab steps 7-9 pending"},
        }
        self.assertEqual(qualified_row_problems(doc, row, good), [])
        cases = {
            "platform": lambda r: r.update(platform="linux-x86_64"),
            "row identity": lambda r: r["row"].update(compiler_version="0.0.0"),
            "zccache binary": lambda r: r["tool_versions"].update(zccache_sha256="0" * 64),
            "harness_pass": lambda r: r.update(harness_pass=False),
            "checks": lambda r: r["checks"].update(warm_has_hits=False),
            "lab gates 7-9": lambda r: r["lab_gates"].update(daemon_restart=None),
        }
        for want, mutate in cases.items():
            bad = copy.deepcopy(good)
            mutate(bad)
            self.assertIn(want, qualified_row_problems(doc, row, bad), want)
        # An all-true set is not enough: it must be exactly record.jq's set for this pair.
        for checks in ({}, {"ok_exit_zero": True}, dict(good["checks"], extra_check=True),
                       {c: True for c in expected_checks(row["compiler"], row["invocation"]) - {"poisoned_artifact_rejected"}}):
            bad = dict(copy.deepcopy(good), checks=checks)
            self.assertIn("checks", qualified_row_problems(doc, row, bad), sorted(checks))

    def test_expected_checks_match_record_jq(self):
        """Every check name record.jq can emit, read from its checks object, equals expected_checks."""
        text = (QUAL / "harness" / "record.jq").read_text(encoding="utf-8")
        block = text.split("| ({", 1)[1].split(") as $c", 1)[0]
        names = set(re.findall(r"^\s+([a-z_]+): ", block, re.M))
        self.assertEqual(names, expected_checks("clang", "debug-pdb"))
        self.assertEqual(expected_checks("cl", "compile-object") | {"compiler_version_observed", "relocated_matches_direct"}, names)
        self.assertIn('IN("cl", "link")', block)
        self.assertIn('$m.invocation == "debug-pdb"', block)

    def test_pins_agree_with_artifacts_md_and_harnesses(self):
        artifacts = (QUAL / "artifacts.md").read_text(encoding="utf-8")
        zc = (REPO / "parity" / "baselines" / "zccache.md").read_text(encoding="utf-8")
        for p in PLATFORMS:
            z = load(p)["zccache"]
            self.assertIn(z["archive"], artifacts)
            self.assertIn(z["archive_sha256"], artifacts)
            self.assertIn(z["archive_sha256"], zc)
            self.assertIn(z["binary_sha256"], artifacts)

        def member(name):
            return re.search(r"`" + re.escape(name) + r"`[^\n]*?`([0-9a-f]{64})`", artifacts).group(1)

        sh = (QUAL / "harness" / "qualify.sh").read_text(encoding="utf-8")
        ps = (QUAL / "harness" / "qualify.ps1").read_text(encoding="utf-8")
        self.assertIn("ZQ_BINARY_SHA256=" + load("linux-x86_64")["zccache"]["binary_sha256"], sh)
        self.assertIn("ZQ_FP_SHA256=" + member("zccache-v1.15.6-x86_64-unknown-linux-musl/zccache-fp"), sh)
        self.assertIn("$ZqBinarySha256 = '" + load("windows-x86_64")["zccache"]["binary_sha256"] + "'", ps)
        self.assertIn("$ZqFpSha256 = '" + member("zccache-v1.15.6-x86_64-pc-windows-msvc/zccache-fp.exe") + "'", ps)


if __name__ == "__main__":
    unittest.main()
