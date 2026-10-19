"""P04 static qualification checks. Standard library only.

Run: python -I -m unittest discover -s tests/parity/cache/qualification -p "test_*.py"
"""

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

# Contract template (parity/contracts/cache-qualification.md, "Matrix template").
TEMPLATE = {
    "linux-x86_64": {
        "rustc": {"rustc-wrapper", "link", "path-with-spaces"},
        "clang": {"compile-object", "compile-pch", "response-file", "depfile", "path-with-spaces"},
        "clang++": {"compile-object", "compile-pch", "response-file", "depfile", "path-with-spaces"},
        "gcc": {"compile-object", "compile-pch", "response-file", "depfile"},
        "g++": {"compile-object", "compile-pch", "response-file", "depfile"},
    },
    "windows-x86_64": {
        "rustc": {"rustc-wrapper", "link", "path-with-spaces", "debug-pdb"},
        "clang": {"compile-object", "compile-pch", "response-file", "depfile", "path-with-spaces"},
        "clang++": {"compile-object", "compile-pch", "response-file", "depfile", "path-with-spaces"},
        "clang-cl": {"compile-object", "response-file", "debug-pdb", "path-with-spaces"},
        "cl": {"compile-object", "compile-pch", "response-file", "debug-pdb"},
        "link": {"link"},
        "lld-link": {"link"},
    },
}


def load(name):
    return json.loads((QUAL / f"{name}.json").read_text(encoding="utf-8"))


def validate(*paths):
    return subprocess.run([sys.executable, "-I", str(VALIDATE), "cache-qualification", *map(str, paths)],
                          capture_output=True, text=True)


def raw_versions(inventory, prefix):
    """Versions from a P01 inventory line such as 'Clang: 16.0.6, 17.0.6, 18.1.3'."""
    text = (REPO / "parity" / "baselines" / inventory / "inventory.json").read_text(encoding="utf-8")
    line = re.search(r'"raw": "' + re.escape(prefix) + r'([^"]*)"', text)
    return set(re.findall(r"\d+\.\d+\.\d+(?:\.\d+)?", line.group(1)))


class MatrixTests(unittest.TestCase):
    def test_both_matrices_validate(self):
        r = validate(*(QUAL / f"{p}.json" for p in PLATFORMS))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_broken_fixture_fails_validation(self):
        r = validate(Path(__file__).parent / "fixtures" / "broken-matrix.json")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("qualified requires evidence_ref", r.stdout)

    def test_every_row_is_direct_and_pending_lab(self):
        for p in PLATFORMS:
            for row in load(p)["rows"]:
                self.assertEqual(row["mode"], "direct", row)
                want = MSVC if row["compiler"] in ("cl", "link") else PENDING
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

    def test_qualified_rows_have_committed_evidence(self):
        for p in PLATFORMS:
            for row in load(p)["rows"]:
                if row["mode"] == "qualified":
                    self.assertTrue((REPO / row["evidence_ref"]).is_file(), row)

    def test_pins_agree_with_artifacts_md_and_harnesses(self):
        artifacts = (QUAL / "artifacts.md").read_text(encoding="utf-8")
        zc = (REPO / "parity" / "baselines" / "zccache.md").read_text(encoding="utf-8")
        for p in PLATFORMS:
            z = load(p)["zccache"]
            self.assertIn(z["archive"], artifacts)
            self.assertIn(z["archive_sha256"], artifacts)
            self.assertIn(z["archive_sha256"], zc)
            self.assertIn(z["binary_sha256"], artifacts)
        sh = (QUAL / "harness" / "qualify.sh").read_text(encoding="utf-8")
        ps = (QUAL / "harness" / "qualify.ps1").read_text(encoding="utf-8")
        self.assertIn("ZQ_BINARY_SHA256=" + load("linux-x86_64")["zccache"]["binary_sha256"], sh)
        self.assertIn("$ZqBinarySha256 = '" + load("windows-x86_64")["zccache"]["binary_sha256"] + "'", ps)


if __name__ == "__main__":
    unittest.main()
